import Foundation
import WinSDK
import NetworkAudioEngine

/// Bonjour on Windows: Windows 10 and 11 carry their own mDNS responder, reached
/// through `DnsServiceBrowse` and `DnsServiceResolve` in dnsapi — so no Apple Bonjour install, no
/// dependency and no licence. What NWBrowser and NetService are on the Mac.
///
/// A browse sends mDNS queries, as the Mac's does, so it runs only while RAVENNA or Dante is
/// switched on in Settings → Discovery.
final class MDNSBrowse {
    /// Each instance name as it is reported, e.g. `Stagebox._netaudio-arc._udp.local`.
    private let found: (String) -> Void
    /// An instance that said goodbye (a record with a TTL of 0). Windows reports changes only, with
    /// no current set as NWBrowser gives on the Mac, so this is how a departure shows.
    private let lost: ((String) -> Void)?
    private let type: String
    private var cancel = DNS_SERVICE_CANCEL()
    private var running = false
    private var context: Unmanaged<MDNSBrowse>?

    init(type: String, found: @escaping (String) -> Void, lost: ((String) -> Void)? = nil) {
        self.type = type
        self.found = found
        self.lost = lost
    }

    /// Starts browsing; an error in words, or nil.
    func start() -> String? {
        guard !running else { return nil }
        let query = Array("\(type).local".utf16) + [0]
        let me = Unmanaged.passRetained(self)
        context = me
        let status: DNS_STATUS = query.withUnsafeBufferPointer { name in
            var request = DNS_SERVICE_BROWSE_REQUEST()
            request.Version = UInt32(DNS_QUERY_REQUEST_VERSION1)
            request.InterfaceIndex = 0
            request.QueryName = name.baseAddress
            request.pBrowseCallback = { status, context, records in
                guard let context else { return }
                let browse = Unmanaged<MDNSBrowse>.fromOpaque(context).takeUnretainedValue()
                browse.deliver(status: status, records: records)
            }
            request.pQueryContext = me.toOpaque()
            return DnsServiceBrowse(&request, &cancel)
        }
        guard status == DNS_STATUS(DNS_REQUEST_PENDING) else {
            me.release()
            context = nil
            return "Bonjour browse (\(type)) failed: error \(status)"
        }
        running = true
        return nil
    }

    func stop() {
        guard running else { return }
        running = false
        _ = DnsServiceBrowseCancel(&cancel)
        // The callback can still be in flight on the thread pool for a moment after the cancel;
        // the context is let go after that moment rather than at once.
        if let context {
            self.context = nil
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { context.release() }
        }
    }

    private func deliver(status: DWORD, records: PDNS_RECORD?) {
        // `DnsRecordListFree` is a macro over this.
        defer { if let records { DnsFree(records, DnsFreeRecordList) } }
        guard status == 0 else { return }
        var record = records
        while let r = record {
            if r.pointee.wType == WORD(DNS_TYPE_PTR), let host = r.pointee.Data.PTR.pNameHost {
                // Always wide from DnsServiceBrowse, whichever way the header's UNICODE switch
                // typed the field for Swift.
                let name = String(decodingCString: UnsafeRawPointer(host).assumingMemoryBound(to: UInt16.self), as: UTF16.self)
                if r.pointee.dwTtl == 0 { lost?(name) } else { found(name) }
            }
            record = r.pointee.pNext
        }
    }
}

/// One `DnsServiceResolve`: an instance name to its IPv4 address, port and TXT record (as keys and
/// values), or a nil address.
enum MDNSResolve {
    private final class Box {
        let completion: (String?, Int, [String: String]) -> Void
        var cancel = DNS_SERVICE_CANCEL()
        init(_ completion: @escaping (String?, Int, [String: String]) -> Void) { self.completion = completion }
    }

    static func resolve(_ instance: String, completion: @escaping (String?, Int, [String: String]) -> Void) {
        let box = Box(completion)
        let me = Unmanaged.passRetained(box)
        var name = Array(instance.utf16) + [0]
        let status: DNS_STATUS = name.withUnsafeMutableBufferPointer { buffer in
            var request = DNS_SERVICE_RESOLVE_REQUEST()
            request.Version = UInt32(DNS_QUERY_REQUEST_VERSION1)
            request.InterfaceIndex = 0
            request.QueryName = buffer.baseAddress
            request.pResolveCompletionCallback = { status, context, instance in
                guard let context else { return }
                let box = Unmanaged<Box>.fromOpaque(context).takeRetainedValue()
                var address: String?
                var port = 0
                var txt: [String: String] = [:]
                if status == 0, let instance {
                    // The TXT record, as Windows splits it: `dwPropertyCount` keys and values.
                    let count = Int(instance.pointee.dwPropertyCount)
                    if count > 0, let keys = instance.pointee.keys, let values = instance.pointee.values {
                        for i in 0..<count {
                            guard let k = keys[i] else { continue }
                            let key = String(decodingCString: UnsafeRawPointer(k).assumingMemoryBound(to: UInt16.self), as: UTF16.self)
                            let value = values[i].map { String(decodingCString: UnsafeRawPointer($0).assumingMemoryBound(to: UInt16.self), as: UTF16.self) } ?? ""
                            txt[key] = value
                        }
                    }
                    if let ip = instance.pointee.ip4Address {
                        // Network order in a DWORD: the first octet is the low byte.
                        let v = ip.pointee
                        address = "\(v & 0xFF).\((v >> 8) & 0xFF).\((v >> 16) & 0xFF).\((v >> 24) & 0xFF)"
                    }
                    port = Int(instance.pointee.wPort)
                }
                if let instance { DnsServiceFreeInstance(instance) }
                box.completion(address, port, txt)
            }
            request.pQueryContext = me.toOpaque()
            return DnsServiceResolve(&request, &box.cancel)
        }
        if status != DNS_STATUS(DNS_REQUEST_PENDING) {
            me.release()
            completion(nil, 0, [:])
        }
    }
}

/// The instance part of a full service name: `Stagebox` from `Stagebox._netaudio-arc._udp.local`.
/// mDNS escapes dots and spaces inside an instance name (`\.`, `\032`), so those are undone.
func mdnsInstanceName(_ full: String, type: String) -> String {
    var name = full
    if let range = name.range(of: ".\(type)") { name = String(name[..<range.lowerBound]) }
    var out = ""
    var i = name.startIndex
    while i < name.endIndex {
        let c = name[i]
        if c == "\\" {
            let next = name.index(after: i)
            let digits = name[next...].prefix(3)
            if digits.count == 3, digits.allSatisfy(\.isNumber), let code = UInt8(digits) {
                out.append(Character(UnicodeScalar(code)))
                i = name.index(next, offsetBy: 3)
                continue
            }
            if next < name.endIndex { out.append(name[next]); i = name.index(after: next); continue }
        }
        out.append(c)
        i = name.index(after: i)
    }
    return out
}

/// Finds Dante devices, to label their AES67 streams as Dante — the Mac's `DanteBrowser` on
/// Windows' mDNS. It carries no audio: a Dante device's AES67 flows arrive over SAP, and this says
/// which senders are Dante, and when Dante gear is present but publishing no AES67 flow.
final class WindowsDanteBrowser: DeviceBrowser {
    var onDevicesChanged: (([DanteDevice]) -> Void)?
    var onError: ((String) -> Void)?

    private static let deviceServices = ["_netaudio-arc._udp", "_netaudio-cmc._udp"]
    private static let channelService = "_netaudio-chan._udp"

    private let queue = DispatchQueue(label: "dante.browser")
    private var browses: [MDNSBrowse] = []
    private var devices: [String: DanteDevice] = [:]
    private var resolving = Set<String>()
    /// Each device's TXT records, by service type (the first step towards
    /// recognising RedNet and other makers' units — what they publish, before any key is relied on).
    private var txt: [String: [String: [String: String]]] = [:]

    /// A copy of the TXT records gathered so far: device → service type → key → value.
    func txtRecords() -> [String: [String: [String: String]]] { queue.sync { txt } }

    /// Which device each browsed service type lists now (channel records by their device half), as
    /// the Mac's `pruneDevices` keeps it: a device in none of them has left the network.
    private var present: [String: Set<String>] = [:]

    func start() {
        stop()
        for type in Self.deviceServices {
            let browse = MDNSBrowse(type: type, found: { [weak self] full in
                self?.addDevice(mdnsInstanceName(full, type: type), full: full, type: type)
            }, lost: { [weak self] full in
                self?.lose(mdnsInstanceName(full, type: type), type: type)
            })
            if let error = browse.start() { onError?(error) } else { browses.append(browse) }
        }
        let channels = MDNSBrowse(type: Self.channelService, found: { [weak self] full in
            self?.addChannel(mdnsInstanceName(full, type: Self.channelService))
        }, lost: { [weak self] full in
            let parts = mdnsInstanceName(full, type: Self.channelService).split(separator: "@", maxSplits: 1)
            if parts.count == 2 { self?.lose(String(parts[1]), type: Self.channelService, channel: String(parts[0])) }
        })
        if let error = channels.start() { onError?(error) } else { browses.append(channels) }
    }

    func stop() {
        browses.forEach { $0.stop() }
        browses.removeAll()
        queue.async {
            self.devices.removeAll()
            self.resolving.removeAll()
            self.txt.removeAll()
            self.present.removeAll()
        }
        onDevicesChanged?([])
    }

    /// One service of a device said goodbye. Once no service lists the device, it is dropped.
    private func lose(_ name: String, type: String, channel: String? = nil) {
        queue.async {
            if let channel {
                self.devices[name]?.channelNames.removeAll { $0 == channel }
                if self.devices[name]?.channelNames.isEmpty != false { self.present[type]?.remove(name) }
            } else {
                self.present[type]?.remove(name)
                self.txt[name]?[type] = nil
            }
            let listed = self.present.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            if !listed.contains(name) {
                self.devices[name] = nil
                self.txt[name] = nil
            }
            self.publish()
        }
    }

    private func publish() {
        onDevicesChanged?(devices.values.sorted { $0.name < $1.name })
    }

    private func addDevice(_ name: String, full: String, type: String) {
        queue.async {
            self.present[type, default: []].insert(name)
            if self.devices[name] == nil {
                self.devices[name] = DanteDevice(name: name)
                self.publish()
            }
            // Each service once, for its TXT record, even once the address is known.
            let key = "\(name)|\(type)"
            guard self.txt[name]?[type] == nil, !self.resolving.contains(key) else { return }
            self.resolving.insert(key)
            MDNSResolve.resolve(full) { [weak self] address, _, record in
                guard let self else { return }
                self.queue.async {
                    self.resolving.remove(key)
                    self.txt[name, default: [:]][type] = record
                    guard let address, var entry = self.devices[name], entry.address != address else { return }
                    entry.address = address
                    self.devices[name] = entry
                    self.publish()
                }
            }
        }
    }

    /// Channel records are named `01@DEVICE-NAME`; the device half is what is keyed on.
    private func addChannel(_ instance: String) {
        let parts = instance.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return }
        let channel = String(parts[0]), device = String(parts[1])
        queue.async {
            self.present[Self.channelService, default: []].insert(device)
            var entry = self.devices[device] ?? DanteDevice(name: device)
            guard !entry.channelNames.contains(channel) else { return }
            entry.channelNames.append(channel)
            entry.channelNames.sort()
            self.devices[device] = entry
            self.publish()
        }
    }
}

/// Finds RAVENNA sessions as ANEMAN and Merging devices publish them — an `_rtsp._tcp` service
/// with the `_ravenna_session` subtype — and asks each for its SDP with an RTSP DESCRIBE. The
/// Mac's `RavennaBrowser`, on Windows' mDNS and a plain WinSock connection. The base type is
/// browsed, as on the Mac; an RTSP server that is not RAVENNA fails the DESCRIBE and is ignored.
///
/// Bonjour reports changes only: each session found is
/// asked again every `refreshEvery` seconds, so a quiet one stays listed and a changed SDP is picked
/// up, and one that says goodbye is reported with its last SDP (`onGone`).
final class WindowsRavennaBrowser: LeavingStreamBrowser {
    var onSDP: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onGone: ((String) -> Void)?

    private static let type = "_rtsp._tcp"
    private static let refreshEvery: TimeInterval = 60
    private let queue = DispatchQueue(label: "ravenna.browser")
    private var browse: MDNSBrowse?
    private var inFlight = Set<String>()
    /// The sessions found and not yet gone, and the SDP each last gave. Queue only.
    private var services = Set<String>()
    private var described: [String: String] = [:]
    private var refresh: DispatchSourceTimer?

    func start() {
        stop()
        let browse = MDNSBrowse(type: Self.type, found: { [weak self] full in self?.found(full) },
                                lost: { [weak self] full in self?.lost(full) })
        if let error = browse.start() { onError?(error) } else { self.browse = browse }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.refreshEvery, repeating: Self.refreshEvery, leeway: .seconds(5))
        // Sessions that answered are asked every minute; other RTSP servers (a camera, say) only
        // every fifth time, as on the Mac.
        var round = 0
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            round += 1
            for full in self.services where self.described[full] != nil || round % 5 == 0 { self.describe(full) }
        }
        timer.resume()
        refresh = timer
    }

    func stop() {
        browse?.stop()
        browse = nil
        refresh?.cancel()
        refresh = nil
        queue.async { self.inFlight.removeAll(); self.services.removeAll(); self.described.removeAll() }
    }

    private func found(_ full: String) {
        queue.async {
            self.services.insert(full)
            self.describe(full)
        }
    }

    private func lost(_ full: String) {
        queue.async {
            self.services.remove(full)
            if let sdp = self.described.removeValue(forKey: full) { self.onGone?(sdp) }
        }
    }

    /// Resolves the session and asks it for its SDP. On the queue.
    private func describe(_ full: String) {
        guard !inFlight.contains(full) else { return }
        inFlight.insert(full)
        let name = mdnsInstanceName(full, type: Self.type)
        MDNSResolve.resolve(full) { [weak self] address, port, _ in
            guard let self else { return }
            guard let address, port > 0 else { self.retire(full); return }
            DispatchQueue.global(qos: .utility).async {
                if let sdp = Self.describe(host: address, port: port, name: name) {
                    self.queue.async {
                        // Not after a goodbye that arrived while it was being asked.
                        guard self.services.contains(full) else { return }
                        self.described[full] = sdp
                        self.onSDP?(sdp)
                    }
                }
                self.retire(full)
            }
        }
    }

    /// Let go of a name after a while, so a session that changes is asked again, as on the Mac.
    private func retire(_ full: String) {
        queue.asyncAfter(deadline: .now() + 30) { self.inFlight.remove(full) }
    }

    /// One RTSP DESCRIBE over a blocking socket with five-second timeouts; the SDP body, or nil.
    static func describe(host: String, port: Int, name: String) -> String? {
        let s = socket(AF_INET, Int32(SOCK_STREAM), Int32(IPPROTO_TCP.rawValue))
        guard s != INVALID_SOCKET else { return nil }
        defer { closesocket(s) }
        var timeout = DWORD(5000)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, withUnsafeBytes(of: &timeout) { $0.baseAddress!.assumingMemoryBound(to: CChar.self) }, Int32(MemoryLayout<DWORD>.size))
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, withUnsafeBytes(of: &timeout) { $0.baseAddress!.assumingMemoryBound(to: CChar.self) }, Int32(MemoryLayout<DWORD>.size))

        var addr = sockaddr_in()
        addr.sin_family = ADDRESS_FAMILY(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(s, $0, Int32(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        let path = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let request = "DESCRIBE rtsp://\(host):\(port)/by-name/\(path) RTSP/1.0\r\n"
            + "CSeq: 1\r\nAccept: application/sdp\r\nUser-Agent: NetworkAudioGrabber\r\n\r\n"
        let bytes = Array(request.utf8)
        let sent = bytes.withUnsafeBufferPointer { b in
            b.baseAddress!.withMemoryRebound(to: CChar.self, capacity: b.count) { send(s, $0, Int32(b.count), 0) }
        }
        guard sent == Int32(bytes.count) else { return nil }

        var reply: [UInt8] = []
        var buffer = [CChar](repeating: 0, count: 16 * 1024)
        while reply.count < 256 * 1024 {
            let n = recv(s, &buffer, Int32(buffer.count), 0)
            if n <= 0 { break }
            reply += buffer[0..<Int(n)].map { UInt8(bitPattern: $0) }
            if let body = completeBody(reply) { return body }
        }
        return completeBody(reply, final: true)
    }

    /// The body once the reply holds all of it (by Content-Length, or at the end of the stream),
    /// and only for a 200.
    private static func completeBody(_ reply: [UInt8], final: Bool = false) -> String? {
        guard let text = String(bytes: reply, encoding: .utf8),
              let split = text.range(of: "\r\n\r\n") ?? text.range(of: "\n\n") else { return nil }
        let head = String(text[..<split.lowerBound])
        let body = String(text[split.upperBound...])
        guard head.split(whereSeparator: \.isNewline).first?.contains(" 200 ") == true else {
            return nil
        }
        var declared: Int?
        for line in head.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                declared = Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        if let declared { return body.utf8.count >= declared ? body : (final ? nil : nil) }
        return final ? body : nil
    }
}
