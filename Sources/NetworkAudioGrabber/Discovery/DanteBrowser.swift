import Foundation
import Network

/// Finds Dante devices via Audinate's Bonjour services.
///
/// Dante's *native* audio transport is proprietary and needs Audinate's licensed SDK, so it
/// cannot be received here. What can be received is **Dante in AES67 mode**: a Dante device
/// with AES67 enabled transmits standard L24/48 kHz multicast RTP and announces it over SAP,
/// which `SAPListener` already picks up.
///
/// So this browser does not carry audio. It identifies which senders are Dante — so their
/// streams can be labelled as such — and, just as usefully, tells the user when Dante gear is
/// present but has published no AES67 flows, which means someone needs to enable AES67 mode
/// and tick "AES67 flow" when creating a multicast flow in Dante Controller.
final class DanteBrowser: DeviceBrowser {
    var onDevicesChanged: (([DanteDevice]) -> Void)?
    var onError: ((String) -> Void)?

    /// `_netaudio-arc` is Audinate's remote-control service and `_netaudio-cmc` its control and
    /// monitoring service; every Dante device publishes both. `_netaudio-chan` publishes one
    /// record per transmit channel, named `<index>@<device>`.
    private static let deviceServices = ["_netaudio-arc._udp", "_netaudio-cmc._udp"]
    private static let channelService = "_netaudio-chan._udp"

    private var browsers: [NWBrowser] = []
    private let queue = DispatchQueue(label: "dante.browser")
    private var devices: [String: DanteDevice] = [:]
    private var resolving = Set<String>()
    private var resolvers: [String: AnyObject] = [:]
    /// Which devices each browsed service type lists now (channel records by their device half).
    /// Bonjour reports the whole current set on each change, so a device in none of them has left
    /// the network.
    private var present: [String: Set<String>] = [:]

    func start() {
        stopBrowsers()
        // Enqueued before the browsers are started, and browse callbacks are delivered on this
        // same serial queue, so the reset is guaranteed to happen first. Clearing from stop()
        // instead raced with the first batch of results: the wipe landed after them and, because
        // NWBrowser only reports *changes*, those devices were never announced again.
        queue.async {
            self.devices.removeAll()
            self.resolving.removeAll()
            self.resolvers.removeAll()
            self.present.removeAll()
        }
        for type in Self.deviceServices {
            browse(type) { [weak self] name in self?.addDevice(name) }
        }
        browse(Self.channelService) { [weak self] name in self?.addChannel(name) }
    }

    func stop() {
        stopBrowsers()
        queue.async {
            self.devices.removeAll()
            self.resolving.removeAll()
            self.resolvers.removeAll()
        }
        onDevicesChanged?([])
    }

    private func stopBrowsers() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
    }

    private func browse(_ type: String, found: @escaping (String) -> Void) {
        let params = NWParameters.udp
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var names = Set<String>()
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint else { continue }
                names.insert(type == Self.channelService
                             ? String(name.split(separator: "@", maxSplits: 1).last ?? Substring(name)) : name)
                found(name)
            }
            self?.present[type] = names
            self?.pruneDevices()
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state {
                self?.onError?("Dante browse (\(type)) failed: \(error.localizedDescription)")
            }
        }
        browser.start(queue: queue)
        browsers.append(browser)
    }

    /// Drops the devices no browsed service lists any more. On the queue.
    private func pruneDevices() {
        let listed = present.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        let gone = devices.keys.filter { !listed.contains($0) }
        guard !gone.isEmpty else { return }
        for name in gone { devices[name] = nil }
        onDevicesChanged?(devices.values.sorted { $0.name < $1.name })
    }

    private func addDevice(_ name: String) {
        
        queue.async {
            if self.devices[name] == nil {
                self.devices[name] = DanteDevice(name: name)
                self.onDevicesChanged?(self.devices.values.sorted { $0.name < $1.name })
            }
            self.resolveAddress(of: name)
        }
    }

    /// Channel records are named `01@DEVICE-NAME`; the device half is what we key on.
    private func addChannel(_ instance: String) {
        let parts = instance.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return }
        let channel = String(parts[0])
        let device = String(parts[1])
        queue.async {
            var entry = self.devices[device] ?? DanteDevice(name: device)
            guard !entry.channelNames.contains(channel) else { return }
            entry.channelNames.append(channel)
            entry.channelNames.sort()
            self.devices[device] = entry
            self.onDevicesChanged?(self.devices.values.sorted { $0.name < $1.name })
        }
    }

    /// Resolves a device's address.
    ///
    /// `NWConnection` to a UDP Bonjour endpoint proved unreliable here — it often never
    /// reaches `.ready` without traffic being sent, and sending unsolicited datagrams to a
    /// Dante control port is not on. `NetService` resolves the address without sending
    /// anything. It is soft-deprecated but still the only API that does this.
    private func resolveAddress(of name: String) {
        guard devices[name]?.address == nil, !resolving.contains(name) else { return }
        resolving.insert(name)

        ResolverLoop.shared.perform { [weak self] in
            guard let self else { return }
            let resolver = ServiceResolver(name: name) { [weak self] address in
                guard let self else { return }
                self.queue.async {
                    self.resolving.remove(name)
                    self.resolvers[name] = nil
                    guard let address, var entry = self.devices[name],
                          entry.address != address else { return }
                    entry.address = address
                    self.devices[name] = entry
                    self.onDevicesChanged?(self.devices.values.sorted { $0.name < $1.name })
                }
            }
            self.queue.async { self.resolvers[name] = resolver }
            resolver.start()
        }
    }
}

/// A dedicated thread with a live run loop, because `NetService` needs one and the only
/// run loop otherwise guaranteed to be turning is the app's — the headless probe drives its
/// own loop and never drains the main dispatch queue.
private final class ResolverLoop {
    static let shared = ResolverLoop()
    private var loop: RunLoop?
    private let ready = DispatchSemaphore(value: 0)

    private init() {
        let thread = Thread { [self] in
            loop = RunLoop.current
            // A port with no traffic, purely so the run loop has a source and does not exit.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            ready.signal()
            RunLoop.current.run()
        }
        thread.name = "bonjour.resolver"
        thread.qualityOfService = .utility
        thread.start()
        ready.wait()
    }

    var runLoop: RunLoop { loop ?? .main }

    func perform(_ block: @escaping () -> Void) {
        guard let loop else { return }
        loop.perform(block)
        CFRunLoopWakeUp(loop.getCFRunLoop())
    }
}

/// One-shot Bonjour address lookup, scheduled on `ResolverLoop`.
private final class ServiceResolver: NSObject, NetServiceDelegate {
    private let service: NetService
    private let completion: (String?) -> Void
    private var finished = false

    init(name: String, completion: @escaping (String?) -> Void) {
        self.service = NetService(domain: "local.", type: "_netaudio-arc._udp.", name: name)
        self.completion = completion
        super.init()
        service.delegate = self
    }

    func start() {
        service.schedule(in: ResolverLoop.shared.runLoop, forMode: .default)
        service.resolve(withTimeout: 5)
    }

    private func finish(_ address: String?) {
        guard !finished else { return }
        finished = true
        service.stop()
        completion(address)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        finish(sender.addresses?.compactMap(Self.ipv4).first)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        finish(nil)
    }

    /// Pulls a dotted-quad out of a packed `sockaddr`, skipping IPv6 entries.
    private static func ipv4(from data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard raw.count >= MemoryLayout<sockaddr_in>.size else { return nil }
            let sa = raw.bindMemory(to: sockaddr_in.self).baseAddress!
            guard sa.pointee.sin_family == sa_family_t(AF_INET) else { return nil }
            var addr = sa.pointee.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            return String(cString: buffer)
        }
    }
}
