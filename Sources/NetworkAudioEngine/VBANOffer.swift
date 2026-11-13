import Foundation

/// Offers this Mac's stream to Grabbers on the network, and keeps the list of those listening.
///
/// While offering, a **BEACON** goes to each local network's broadcast address once a second.
/// A Grabber that wants the stream sends **SUBSCRIBE**; this replies **CHALLENGE** with a cookie
/// bound to the Grabber's address, keeping no state; the Grabber proves it received it with
/// **CONFIRM**, and only then is it added and sent the stream, unicast. It must send a
/// **KEEPALIVE** every 5 s or be dropped after 15; **UNSUBSCRIBE** leaves at once.
///
/// **Opt-in, and off by default.** An offer means anyone on the network can ask for whatever
/// this Mac is playing, so it is a choice the user makes, it follows the same "nothing at
/// launch unless Resume is on" rule as sending, and every listener is shown.
///
/// **Ask first** (on by default): a Grabber this Mac has not been told to allow is held as a
/// *request* after its CONFIRM, and told PENDING, until the user allows or declines it. Allowed
/// Grabbers are remembered by address, which the cookie proves; the name a Grabber reports is
/// shown to help decide, but proves nothing. Declined ones are refused until the next launch.
///
/// Limits: at most `maxSubscribers`; SUBSCRIBE rate-limited per address and overall; a
/// SUBSCRIBE shorter than any reply is ignored, so nothing here can be used to amplify.
public final class VBANOffer {
    /// This Sender's identity, in every beacon, so a Grabber hearing it on several addresses lists
    /// it once. Kept in the Sender's settings, so it is the same after a relaunch —
    /// a Grabber still running then keeps the same listing, and a joined stream rejoins by name.
    /// Each offer has its own (a DAW can hold several Sender plugins, each its own stream);
    /// `processInstance` is the app's, for the Grabber to leave its own Send out.
    private let instance: [UInt8]
    nonisolated(unsafe) public static var processInstance: [UInt8] = random()

    public static func random() -> [UInt8] { (0..<VBANControl.instanceBytes).map { _ in UInt8.random(in: 0...255) } }

    /// The stored identity, made and saved on first use.
    public static func stored(in defaults: UserDefaults) -> [UInt8] {
        if let data = defaults.data(forKey: "offerInstance"), data.count == VBANControl.instanceBytes {
            return [UInt8](data)
        }
        let made = random()
        defaults.set(Data(made), forKey: "offerInstance")
        return made
    }

    public struct Subscriber: Equatable, Identifiable {
        public var ip: String
        public var port: Int
        /// What the Grabber calls itself, if it said. Untrusted: shown, never acted on.
        public var name: String?
        public var cookie: [UInt8]
        public var lastSeen: CFAbsoluteTime
        /// The identity the Grabber gave, as hex; the same on each of its Mac's addresses.
        public var instance: String?
        public var id: String { "\(ip):\(port)" }

        public init(ip: String, port: Int, name: String?, cookie: [UInt8], lastSeen: CFAbsoluteTime,
                    instance: String? = nil) {
            self.ip = ip; self.port = port; self.name = name; self.cookie = cookie
            self.lastSeen = lastSeen; self.instance = instance
        }

        public static func == (a: Subscriber, b: Subscriber) -> Bool {
            a.ip == b.ip && a.port == b.port && a.name == b.name
        }
    }

    public static let maxSubscribers = 8
    public static let dropAfter: CFAbsoluteTime = 15
    public static let subscribesPerAddress = 4          // in any 10 s
    public static let subscribesPerSecond = 20          // from everyone

    /// Called on the main queue whenever the listeners or the requests waiting for an answer
    /// change.
    public var onChange: (([Subscriber], [Subscriber]) -> Void)?
    public var onLog: ((LogKind, String) -> Void)?

    /// The transmitter's socket, fetched when the offer first starts (so an unused Send holds no
    /// port).
    private var udp: UDPSocket?
    private var controlPort = 0
    private let socket: () -> UDPSocket?
    private let cookies = VBANCookie()
    private let lock = NSLock()
    private var offering = false
    private var streamName = "Mac Audio"
    private var format = VBANControl.Format(sampleRate: 48000, channels: 2, dataType: .int16)
    private var subscribers: [String: Subscriber] = [:]
    private var requests: [String: Subscriber] = [:]
    private var askFirst = true
    /// Addresses, and `Self.identityKey`s, allowed to listen without asking — and refused until
    /// the Sender reopens or its user allows them after all.
    private var allowed: Set<String> = []
    private var declined: Set<String> = []

    /// How a Grabber's identity is kept among the allowed and declined addresses.
    public static func identityKey(_ hex: String) -> String { "id:" + hex }
    public static func hex(_ bytes: [UInt8]?) -> String? {
        guard let bytes, bytes.count == VBANControl.instanceBytes else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    /// Whether this set names this Grabber: by address, or by its identity — the latter only on a
    /// local network, where its address is one of a Mac's several (a Remote link is by exact
    /// address and port, never by identity). Lock held.
    private func names(_ set: Set<String>, ip: String, instance: String?) -> Bool {
        if set.contains(ip) { return true }
        guard let instance, !RemoteAddresses.isRemote(ip) else { return false }
        return set.contains(Self.identityKey(instance))
    }
    public static let forgetRequestAfter: CFAbsoluteTime = 10
    private var recentSubscribes: [String: [CFAbsoluteTime]] = [:]
    private var secondStart: CFAbsoluteTime = 0
    private var subscribesThisSecond = 0
    private var timer: DispatchSourceTimer?
    private var published: ([Subscriber], [Subscriber]) = ([], [])

    public init(socket: @escaping () -> UDPSocket?, instance: [UInt8]) {
        self.socket = socket
        self.instance = instance
    }

    /// Set to end the receive thread (`stop`); read by that thread between receives.
    private var stopping = false
    /// The receive thread is still running (it notices `stopping` only between receives, so a
    /// quick stop-then-start must not start a second one).
    private var looping = false

    /// Stops the listener thread and the one-second timer, for a Sender that is not in use — the
    /// Grabber's Send, which costs nothing while nothing is sent.
    /// `start` again resumes.
    public func stop() {
        guard let t = timer else { return }
        t.cancel()
        timer = nil
        lock.lock(); stopping = true; lock.unlock()
    }

    public func start() {
        if udp == nil, let made = socket() { udp = made; controlPort = made.boundPort }
        guard let udp, timer == nil else { return }
        lock.lock()
        stopping = false
        let running = looping
        looping = true
        lock.unlock()
        if !running {
            udp.setReceiveTimeout(0.5)
            let thread = Thread { [weak self] in self?.receiveLoop() }
            thread.name = "VBAN offer :\(controlPort)"
            thread.qualityOfService = .utility
            thread.start()
        }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "VBAN offer", qos: .utility))
        t.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.everySecond() }
        t.resume()
        timer = t
    }

    /// From the main thread. Turning the offer off drops every listener and request at once.
    /// The interfaces beacons go out on; empty for every local network.
    private var interfaces: Set<String> = []
    /// Broadcast addresses this Sender is broadcasting the stream to: no beacon goes there.
    private var skipping: Set<String> = []

    public func configure(offering: Bool, askFirst: Bool, allowed: Set<String>, name: String,
                   format: VBANControl.Format, interfaces: Set<String> = [], skipping: Set<String> = []) {
        lock.lock()
        self.interfaces = interfaces
        self.skipping = skipping
        let stopped = self.offering && !offering
        self.offering = offering
        self.askFirst = askFirst
        self.allowed = allowed
        streamName = name
        self.format = format
        // Findable off drops everyone it let in — but not a Remote link's ends, which never
        // needed it.
        if stopped { subscribers = subscribers.filter { remoteAllowed.contains($0.key) }; requests.removeAll() }
        lock.unlock()
        if stopped { publish() }
    }

    /// Let the Grabber that asked from `id` ("ip:port") listen, now and from then on. Returns
    /// its address, for the caller to remember. It starts at once, on the cookie it proved.
    @discardableResult
    public func allow(_ id: String) -> String? {
        lock.lock()
        guard var r = requests.removeValue(forKey: id), subscribers.count < Self.maxSubscribers else {
            lock.unlock(); return nil
        }
        allowed.insert(r.ip)
        if let i = r.instance { allowed.insert(Self.identityKey(i)) }
        r.lastSeen = CFAbsoluteTimeGetCurrent()
        subscribers[id] = r
        let offer = VBANControl.encode(.init(kind: .offer, name: streamName, format: format), headerName: streamName)
        lock.unlock()
        send(offer, to: r.ip, port: r.port)
        log(.done, "\(r.name ?? "A Grabber") at \(r.ip) is listening (VBAN, unicast).")
        publish()
        return r.ip
    }

    /// Stop sending to listeners not on any of these networks — a network was unticked in the
    /// offer menu. They stay allowed, so rejoining does not ask
    /// again. Returns how many stopped.
    @discardableResult
    public func stopListeners(outside networks: [LocalNetwork]) -> Int {
        lock.lock()
        let before = subscribers.count
        subscribers = subscribers.filter { sub in networks.contains { $0.contains(sub.value.ip) } }
        let stopped = before - subscribers.count
        lock.unlock()
        if stopped > 0 { publish() }
        return stopped
    }

    /// Stop sending to every listener at this address, when it is no longer allowed. If it asks
    /// again it is a new request.
    public func drop(ip: String, instance: String? = nil) {
        lock.lock()
        subscribers = subscribers.filter { $0.value.ip != ip && (instance == nil || $0.value.instance != instance) }
        allowed.remove(ip)
        if let instance { allowed.remove(Self.identityKey(instance)) }
        lock.unlock()
        publish()
    }

    /// Refuse the Grabber that asked from `id`, and anything else from its address, until the
    /// Sender next launches.
    public func decline(_ id: String) {
        lock.lock()
        guard let r = requests.removeValue(forKey: id) else { lock.unlock(); return }
        declined.insert(r.ip)
        if let i = r.instance { declined.insert(Self.identityKey(i)) }
        let no = VBANControl.encode(.init(kind: .declined), headerName: streamName)
        lock.unlock()
        send(no, to: r.ip, port: r.port)
        publish()
    }

    /// No longer refused: the user allowed a Grabber they had denied. It is let in when it next
    /// asks — a denied Grabber asks again every 20 seconds.
    public func undecline(ip: String, instance: String?) {
        lock.lock()
        declined.remove(ip)
        if let instance { declined.remove(Self.identityKey(instance)) }
        lock.unlock()
    }

    // MARK: - Every second

    private func everySecond() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let offering = self.offering
        let beacon = VBANControl.encode(.init(kind: .beacon, name: streamName, format: format,
                                              port: controlPort, instance: instance),
                                        headerName: streamName)
        let before = subscribers.count
        subscribers = subscribers.filter { now - $0.value.lastSeen < Self.dropAfter }
        let dropped = before - subscribers.count
        let lapsed = requests.values.filter { now - $0.lastSeen >= Self.forgetRequestAfter }
        requests = requests.filter { now - $0.value.lastSeen < Self.forgetRequestAfter }
        let requestsGone = !lapsed.isEmpty
        recentSubscribes = recentSubscribes.compactMapValues { times in
            let kept = times.filter { now - $0 < 10 }
            return kept.isEmpty ? nil : kept
        }
        lock.unlock()
        if dropped > 0 { log(.warning, "Timed out: a Grabber stopped checking in for \(Int(Self.dropAfter)) s and was dropped.") }
        // Not a denial: nobody said no. The Grabber stopped asking — it was stopped, or went away.
        for r in lapsed {
            log(.note, "\(r.name ?? "A Grabber") at \(r.ip) stopped asking before an answer was given (it was stopped or went away). Not denied.")
        }
        if dropped > 0 || requestsGone { publish() }
        // Knock on each Remote link's receiving end: every second for a minute, then every 15 s —
        // whether or not the offer is on (a link does not need it).
        lock.lock()
        let due = knocks.filter { now - $0.since < 60 || Int(now) % 15 == 0 }
        lock.unlock()
        // Plain: a knock only has to leave this router, and carries nothing.
        for k in due { sendPlain(RemoteKnock.bytes, to: k.ip, port: k.port) }
        guard offering else { return }
        // Every local network's broadcast address — or only those chosen in the header, any
        // number of them. A Grabber on this same Mac hears these too, from this Mac's own
        // address on that network. Chosen interfaces that are not up announce nowhere, rather
        // than the offer spreading to networks nobody chose.
        lock.lock()
        let only = interfaces, skip = skipping
        lock.unlock()
        let all = LocalNetworks.list()
        let networks = all.filter { only.isEmpty || only.contains($0.name) }.compactMap(\.broadcast)
        for address in Set(networks.isEmpty && only.isEmpty ? ["127.0.0.1"] : networks) where !skip.contains(address) {
            send(beacon, to: address, port: VBAN.port)
        }
    }

    // MARK: - Receiving

    private func receiveLoop() {
        guard let udp else { lock.lock(); looping = false; lock.unlock(); return }
        var buf = [UInt8](repeating: 0, count: VBANControl.maxPacket + 1)
        while true {
            guard let (n0, from) = buf.withUnsafeMutableBytes({ udp.receive(into: $0.baseAddress!, capacity: $0.count) }) else {
                lock.lock(); let done = stopping; if done { looping = false }; lock.unlock()
                if done { return }
                continue
            }
            var n = n0
            // From a Remote link's end: sealed, or dropped — nobody else can speak
            // for it, and what it says can't be read on the way.
            lock.lock(); let crypto = linkCrypto[from.description]; lock.unlock()
            if let crypto {
                guard let inner = buf.withUnsafeBufferPointer({ crypto.opener.open($0.baseAddress!, n) }) else { continue }
                n = inner.count
                buf.replaceSubrange(0..<n, with: inner)
            }
            // A Remote link's traffic: the address server's answer, and the other end's knocks.
            if buf.withUnsafeBufferPointer({ OutsideAddress.isReply($0.baseAddress!, n) }) {
                handleStun(Array(buf[0..<n])); continue
            }
            if buf.withUnsafeBufferPointer({ RemoteKnock.isKnock($0.baseAddress!, n) }) { continue }
            guard let message = buf.withUnsafeBufferPointer({ VBANControl.decode($0.baseAddress!, n) }) else { continue }
            handle(message, ip: from.ip, port: from.port)
        }
    }

    // MARK: - Remote link

    private var stunPending: (transaction: [UInt8], done: (RemoteCode?) -> Void)?
    private var stunServer: UDPEndpoint?
    /// Receiving ends reached by a Remote link: knocked on so this router lets their requests in —
    /// every second for the first minute after linking, then every 15 s to keep it open.
    private var knocks: [(ip: String, port: Int, since: CFAbsoluteTime)] = []

    /// Asks the STUN server, from the socket audio leaves from, what this network's outside
    /// address and port are for it: the sending end's code. On the main thread; nil after 3 s.
    public func makeRemoteCode(_ done: @escaping (RemoteCode?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, let server = UDPEndpoint.resolve(host: OutsideAddress.server.0, port: OutsideAddress.server.1) else {
                DispatchQueue.main.async { done(nil) }
                return
            }
            let (bytes, transaction) = OutsideAddress.request()
            self.lock.lock()
            self.stunServer = server
            self.stunPending = (transaction, { code in DispatchQueue.main.async { done(code) } })
            self.lock.unlock()
            self.sendRaw(bytes, to: server)
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let stale = self.stunPending?.transaction == transaction ? self.stunPending : nil
                if stale != nil { self.stunPending = nil }
                self.lock.unlock()
                stale?.done(nil)
            }
        }
    }

    /// Keeps the mapping alive while a code waits to be used.
    public func refreshRemoteMapping() {
        lock.lock(); let server = stunServer; lock.unlock()
        if let server { sendRaw(OutsideAddress.request().bytes, to: server) }
    }

    /// "address:port" of each receiving end a Remote link lets in, without asking.
    private var remoteAllowed: Set<String> = []

    /// The receiving ends to knock on (from the Remote links), and to let in; knocking starts at once.
    /// Each end's encryption, by "address:port".
    private var linkCrypto: [String: LinkCrypto] = [:]

    /// The sealer for audio to this end, if it is a Remote link's (the transmitter asks).
    public func sealer(for key: String) -> RemoteSealer? {
        lock.lock(); defer { lock.unlock() }
        return linkCrypto[key]?.sealer
    }

    public func setKnocks(_ list: [(ip: String, port: Int, crypto: LinkCrypto)]) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        remoteAllowed = Set(list.map { "\($0.ip):\($0.port)" })
        linkCrypto = Dictionary(list.map { ("\($0.ip):\($0.port)", $0.crypto) }, uniquingKeysWith: { a, _ in a })
        knocks = list.map { item in
            (item.ip, item.port, knocks.first { $0.ip == item.ip && $0.port == item.port }?.since ?? now)
        }
        lock.unlock()
        for k in list { sendPlain(RemoteKnock.bytes, to: k.ip, port: k.port) }
    }

    private func handleStun(_ buf: [UInt8]) {
        lock.lock()
        guard let pending = stunPending, let (ip, port) = OutsideAddress.parseEndpoint(buf, transaction: pending.transaction)
        else { lock.unlock(); return }
        stunPending = nil
        lock.unlock()
        pending.done(RemoteCode(role: .sending, address: ip, port: port))
    }

    private func sendRaw(_ bytes: [UInt8], to endpoint: UDPEndpoint) {
        udp?.send(bytes, to: endpoint)
    }

    private func handle(_ m: VBANControl.Message, ip: String, port: Int) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        guard offering || !remoteAllowed.isEmpty else { lock.unlock(); return }
        let key = "\(ip):\(port)"
        // With the offer off, only a Remote link's ends are answered at all.
        if !offering, !remoteAllowed.contains(key), subscribers[key] == nil { lock.unlock(); return }
        switch m.kind {
        case .subscribe:
            // A Remote link's exact end is not held to the per-address limit: several Grabbers
            // behind one router share an address, and would starve each other.
            guard let nonce = m.nonce,
                  allowSubscribe(from: ip, now: now, linked: remoteAllowed.contains(key)) else { break }
            let cookie = cookies.make(ip: ip, port: port)
            let name = streamName
            lock.unlock()
            send(VBANControl.encode(.init(kind: .challenge, nonce: nonce, cookie: cookie),
                                    headerName: name), to: ip, port: port)
            return

        case .confirm:
            guard let cookie = m.cookie, cookies.verify(cookie, ip: ip, port: port) else { break }
            let known = subscribers[key] != nil
            let instance = Self.hex(m.instance)
            if !known, names(declined, ip: ip, instance: instance) {
                let no = VBANControl.encode(.init(kind: .declined), headerName: streamName)
                lock.unlock()
                send(no, to: ip, port: port)
                return
            }
            // A Remote link lets in exactly the address **and port** its code gave — not every
            // device behind that router.
            if !known, askFirst, !names(allowed, ip: ip, instance: instance), !remoteAllowed.contains("\(ip):\(port)") {
                // Proven to receive at this address; now the user decides. Each CONFIRM keeps
                // the request fresh with its latest cookie, so Allow can start it at once.
                let new = requests[key] == nil
                requests[key] = Subscriber(ip: ip, port: port, name: m.name ?? requests[key]?.name,
                                           cookie: cookie, lastSeen: now, instance: instance)
                let wait = VBANControl.encode(.init(kind: .pending), headerName: streamName)
                lock.unlock()
                send(wait, to: ip, port: port)
                if new { log(.request, "\(m.name ?? "A Grabber") at \(ip):\(port) asks to listen. Waiting for Allow or Deny."); publish() }
                return
            }
            guard known || subscribers.count < Self.maxSubscribers else {
                lock.unlock()
                log(.failed, "Refused the Grabber at \(ip): \(Self.maxSubscribers) are already listening, the most allowed.")
                return
            }
            subscribers[key] = Subscriber(ip: ip, port: port, name: m.name ?? subscribers[key]?.name,
                                          cookie: cookie, lastSeen: now,
                                          instance: instance ?? subscribers[key]?.instance)
            let offer = VBANControl.encode(.init(kind: .offer, name: streamName, format: format),
                                           headerName: streamName)
            lock.unlock()
            send(offer, to: ip, port: port)
            if !known { log(.done, "\(m.name ?? "A Grabber") at \(ip) is listening (VBAN, unicast).") }
            publish()
            return

        case .keepalive:
            guard var s = subscribers[key], let cookie = m.cookie,
                  VBANCookie.equalBytes(cookie, s.cookie) else { break }
            s.lastSeen = now
            let renamed = m.name != nil && m.name != s.name
            if renamed { s.name = m.name }
            subscribers[key] = s
            lock.unlock()
            if renamed { publish() }
            return

        case .unsubscribe:
            // A Grabber that gives up while its user was still being asked: gone at once, and
            // logged as what it is — not a denial.
            if let r = requests[key], let cookie = m.cookie, VBANCookie.equalBytes(cookie, r.cookie) {
                requests[key] = nil
                lock.unlock()
                log(.note, "\(r.name ?? "A Grabber") at \(ip) stopped asking before an answer was given (it was stopped). Not denied.")
                publish()
                return
            }
            guard let s = subscribers[key], let cookie = m.cookie,
                  VBANCookie.equalBytes(cookie, s.cookie) else { break }
            subscribers[key] = nil
            lock.unlock()
            log(.stopped, "\(s.name ?? "A Grabber") at \(ip) stopped listening — it left.")
            publish()
            return

        case .beacon, .challenge, .offer, .pending, .declined:
            break                                           // meant for a Grabber, not us
        }
        lock.unlock()
    }

    /// Lock held.
    private func allowSubscribe(from ip: String, now: CFAbsoluteTime, linked: Bool = false) -> Bool {
        if now - secondStart >= 1 { secondStart = now; subscribesThisSecond = 0 }
        let recent = recentSubscribes[ip, default: []].filter { now - $0 < 10 }
        guard subscribesThisSecond < Self.subscribesPerSecond,
              linked || recent.count < Self.subscribesPerAddress else { return false }
        subscribesThisSecond += 1
        if !linked { recentSubscribes[ip] = recent + [now] }
        return true
    }

    // MARK: - Out

    private func publish() {
        lock.lock()
        let list = subscribers.values.sorted { $0.id < $1.id }
        let asking = requests.values.sorted { $0.id < $1.id }
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self, list != self.published.0 || asking != self.published.1 else { return }
            self.published = (list, asking)
            self.onChange?(list, asking)
        }
    }

    private func log(_ kind: LogKind, _ text: String) {
        DispatchQueue.main.async { [weak self] in self?.onLog?(kind, text) }
    }

    /// To a Remote link's end, sealed; to anyone else, as it is.
    private func send(_ bytes: [UInt8], to ip: String, port: Int) {
        lock.lock(); let crypto = linkCrypto["\(ip):\(port)"]; lock.unlock()
        sendPlain(crypto?.sealer.seal(bytes) ?? bytes, to: ip, port: port)
    }

    private func sendPlain(_ bytes: [UInt8], to ip: String, port: Int) {
        guard let endpoint = UDPEndpoint(ip: ip, port: port) else { return }
        udp?.send(bytes, to: endpoint)
    }
}
