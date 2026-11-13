import Foundation
#if canImport(WinSDK)
import WinSDK          // the Windows port: WinSock, and WindowsCompat.swift beside it
#endif

/// The Grabber's name for each VBAN sample format. The wire format itself is `VBAN`, in
/// `NetworkAudioShared`, which the Sender writes with.
public extension VBAN.DataType {
    public var encoding: SampleEncoding {
        switch self {
        case .int16:   return .PCM16
        case .int24:   return .PCM24
        case .int32:   return .PCM32
        case .float32: return .F32
        case .float64: return .F64
        }
    }
}

/// The one UDP socket every VBAN stream arrives on. It keeps the table of streams heard
/// recently, which is what discovery *is* for VBAN — a stream exists when its packets do — and
/// hands packets for joined streams to their `VBANReceiver`.
///
/// **Built to be flooded.** Anyone on the network can send to this port, so: a packet is
/// header-checked and nothing more unless its stream is joined; the table holds at most
/// `maxStreams`, at most `maxStreamsPerSender` of them from any one address, and admits at most
/// `newStreamsPerSecond` it has not seen before; and nothing here touches the UI. `AppState`
/// samples `snapshot()` on its own 4 Hz tick and only publishes what actually changed.
public final class VBANListener {
    public init() {}

    public static let maxStreams = 32
    /// Without it, one machine inventing names fills the whole table and locks every real
    /// sender out — which the flood test did on the first try. Voicemeeter sends at most eight.
    public static let maxStreamsPerSender = 8
    public static let newStreamsPerSecond = 4
    /// Silent this long and a stream leaves the table.
    public static let forgetAfter: CFAbsoluteTime = 15

    public struct Entry {
        public var description: StreamDescription
        public var lastSeen: CFAbsoluteTime
        /// The frame counter the next packet should carry. What makes a rename recognisable.
        public var nextCounter: UInt32 = 0
        public var sourcePort: UInt16 = 0
        /// Set when a Network Audio Sender's beacon offers this stream: the port to ask it on.
        public var offerPort: Int?
        /// When audio last arrived for it, as distinct from a beacon keeping it listed.
        public var lastAudio: CFAbsoluteTime = 0
    }

    /// Asking a Sender for its stream (`VBANOffer`
    /// on the Sender's side). One per Sender, keyed by its address and control port.
    public struct Subscription {
        public var ip: String
        public var port: Int
        public var nonce = VBANControl.randomNonce()
        public var cookie: [UInt8]?
        public var established = false
        public var nextAttempt: CFAbsoluteTime = 0
        public var backoff: CFAbsoluteTime = 1
        public var lastKeepalive: CFAbsoluteTime = 0
        public var establishedAt: CFAbsoluteTime = 0
        /// Added by address in Settings: kept subscribed while it is listed, not only while
        /// joined, since no beacon will say it is there.
        public var manual = false
        public var streamName: String?
        /// The stream this was asked for from the list, so its row can say how it is going.
        public var streamID: String?
        /// The Sender has asked its user (PENDING), or its user said no (DECLINED).
        public var awaitingApproval = false
        public var declined = false
        /// When the current cookie came, so it is reused only while the Sender still accepts it.
        public var cookieAt: CFAbsoluteTime = 0
        /// When asking began without an answer, and whether that has been logged as a timeout.
        public var unansweredSince: CFAbsoluteTime = 0
        public var timeoutLogged = false
    }
    /// While a Sender's user decides, ask this often: each CONFIRM keeps the request fresh, and
    /// under the Sender's limit of four SUBSCRIBEs per address in ten seconds.
    public static let askAgainWhilePending: CFAbsoluteTime = 3
    /// How often a denied Grabber asks again (the Sender answers without asking its user).
    public static let askAgainWhileDeclined: CFAbsoluteTime = 20
    public static let keepaliveEvery: CFAbsoluteTime = 5
    /// No audio this long from a Sender we are subscribed to, and we ask again: it restarted,
    /// or dropped us.
    public static let resubscribeAfter: CFAbsoluteTime = 4

    /// What this Grabber calls itself to a Sender. Set from the main thread.
    public var receiverName = ""
    /// Leave this app's own Send out of the list (the app; not a Grabber plugin, whose host
    /// may hold a Sender plugin meant to be heard). Set once, before starting.
    public var ignoresOwnSend = true
    /// This Grabber's identity, in each CONFIRM, so a Sender that allowed it on one of this
    /// Mac's addresses lets it in on the others too. Set once, before starting.
    public var receiverInstance: [UInt8]?
    #if os(Windows)
    /// Audio to leave out, as "ip:port": this PC's own Send broadcasting on a network this Grabber
    /// listens on. Its beacons are already left out by instance;
    /// broadcast audio carries none, so it is matched by address and the Send's port instead.
    /// Set from the main thread.
    public var ignoredSources: Set<String> {
        get { lock.lock(); defer { lock.unlock() }; return ignored }
        set {
            lock.lock()
            ignored = newValue
            // One already listed — its first packets came before this was set — goes too.
            table = table.filter { !newValue.contains("\($0.value.description.originAddress):\(UInt16(bigEndian: $0.value.sourcePort))") }
            lock.unlock()
        }
    }
    private var ignored: Set<String> = []
    #endif
    /// Handshake events worth a log line. Called on the main queue.
    public var onLog: ((ActivityLog.Kind, String) -> Void)?

    /// A stream that changed its name, `from` one ID `to` another. See `renamed(_:)`.
    public struct Rename {
        public let from: String
        public let to: String
        /// The same Sender, reached at another of its addresses — not a new name.
        public var moved = false
    }

    public var onError: ((String) -> Void)?

    /// Its own object per start, so a receive thread still draining an old socket can never
    /// read from a new one that happens to get the same descriptor number.
    private final class Socket { var fd: Int32 = -1 }
    private var socket: Socket?
    /// Sharing: when another copy — the app, or a Grabber plugin
    /// in a DAW — already holds UDP 6980, this one listens on a spare port for its own
    /// handshakes and audio, plus one "ear" per network bound to that network's **broadcast
    /// address** on 6980. Broadcasts (the Senders' beacons) reach both copies; unicast to 6980
    /// still goes only to the copy that holds it, so nothing is taken from it (checked on macOS:
    /// a socket bound to the broadcast address beside a wildcard one gets broadcasts only).
    private var ears: [Socket] = []
    /// Set while sharing: what the log says, once, and the port listened on instead.
    public private(set) var sharingPort: Int?
    /// The spare port last used, taken again on a restart: a Remote link's code names it, and a
    /// new port each time discovery restarted broke the link silently.
    private var lastSparePort = 0

    private let lock = NSLock()
    private var table: [String: Entry] = [:]
    /// Survive a restart, so joined streams keep playing when discovery is refreshed.
    private var sinks: [String: VBANReceiver] = [:]
    private var admittedThisSecond = 0
    private var admissionWindow: CFAbsoluteTime = 0
    private var refused: UInt64 = 0
    private var renames: [Rename] = []
    /// Names recently renamed away, and when. One of them coming back means it was never a
    /// rename — two streams from one port sharing a counter — and it is not read as one again.
    private var retired: [String: CFAbsoluteTime] = [:]
    private var subscriptions: [String: Subscription] = [:]
    /// Streams the user has pressed play on, whether or not a Sender has offered them yet. A
    /// stream can be playing before its Sender's beacon is heard — it was reached by a plain
    /// "Send to", or rejoined at launch — and the beacon then starts the handshake for it.
    /// Without this the Sender never heard a request and waited at "press play" until the
    /// stream was stopped and played again.
    private var wanted: Set<String> = []
    /// For each wanted stream, the port its audio last came from (host order). A Sender's audio and
    /// its beacons leave one socket, so this is what ties a stream heard only as audio — a
    /// broadcast, which carries no identity — to the Sender's later beacons.
    private var audioPorts: [String: UInt16] = [:]
    private var lastAudioFrom: [String: CFAbsoluteTime] = [:]

    /// Opens the port. Returns an error message on failure.
    public func start(port: Int = VBAN.port) -> String? {
        stop()
        let s = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        #if os(Windows)
        // WinSock reports through `WSAGetLastError()`, which `strerror` knows nothing about.
        guard s >= 0 else { return "VBAN: socket() failed: \(socketErrorText())" }
        #else
        guard s >= 0 else { return "VBAN: socket() failed: \(String(cString: strerror(errno)))" }
        #endif
        // No SO_REUSEPORT: sharing the port with another VBAN receiver would silently split the
        // unicast traffic between us, which is worse than failing to open it and saying so.
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var rcvbuf = Int32(4 * 1024 * 1024)
        setsockopt(s, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))
        #if os(Windows)
        // WinSock takes the receive timeout as a DWORD of milliseconds, not a `timeval`.
        var timeout = DWORD(500)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<DWORD>.size))
        #else
        var tv = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        #endif
        TestBinding.apply(s)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 {
            #if os(Windows)
            // Read WinSock's error before `closesocket`, which may put its own there.
            let code = lastSocketError
            let inUse = code == WSAEADDRINUSE
            let text = socketErrorText(code)
            #else
            let inUse = errno == EADDRINUSE
            #endif
            Darwin.close(s)
            #if os(Windows)
            guard inUse else { return "VBAN: could not open UDP \(port): \(text)." }
            #else
            guard inUse else { return "VBAN: could not open UDP \(port): \(String(cString: strerror(errno)))." }
            #endif
            return startSharing(port: port)
        }

        let box = Socket()
        box.fd = s
        socket = box
        let t = Thread { [weak self] in self?.receiveLoop(box) }
        t.name = "VBAN :\(port)"
        t.qualityOfService = .userInteractive
        t.start()
        return nil
    }

    /// Port `port` is taken: a spare port for this copy's own traffic, and ears for beacons.
    private func startSharing(port: Int) -> String? {
        let s = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        #if os(Windows)
        guard s >= 0 else { return "VBAN: socket() failed: \(socketErrorText())" }
        #else
        guard s >= 0 else { return "VBAN: socket() failed: \(String(cString: strerror(errno)))" }
        #endif
        var rcvbuf = Int32(4 * 1024 * 1024)
        setsockopt(s, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))
        #if os(Windows)
        // WinSock takes the receive timeout as a DWORD of milliseconds, not a `timeval`. The ears
        // opened further down take the same one.
        var timeout = DWORD(500)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<DWORD>.size))
        #else
        var tv = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        #endif
        guard let spare = (lastSparePort > 0 ? Self.bind(s, address: INADDR_ANY, port: lastSparePort) : nil)
                ?? Self.bind(s, address: INADDR_ANY, port: 0) else {
            Darwin.close(s)
            return "VBAN: UDP \(port) is in use by another app, and no spare port could be opened, so VBAN is not listening."
        }
        let box = Socket()
        box.fd = s
        socket = box
        sharingPort = spare
        lastSparePort = spare
        let t = Thread { [weak self] in self?.receiveLoop(box) }
        t.name = "VBAN :\(spare)"
        t.qualityOfService = .userInteractive
        t.start()
        for network in LocalNetworks.list() {
            guard let broadcast = network.broadcast else { continue }
            var a = in_addr()
            guard inet_pton(AF_INET, broadcast, &a) == 1 else { continue }
            let e = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard e >= 0 else { continue }
            var yes: Int32 = 1
            setsockopt(e, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            // And REUSEPORT: a third copy binds the same broadcast address as the second, which
            // REUSEADDR alone refuses (for example, REAPER with two Receivers, then the app).
            // An ear only ever gets broadcasts, so sharing it takes nothing.
            setsockopt(e, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
            #if os(Windows)
            setsockopt(e, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<DWORD>.size))
            #else
            setsockopt(e, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            #endif
            guard Self.bind(e, address: a.s_addr, port: port) != nil else { Darwin.close(e); continue }
            let ear = Socket()
            ear.fd = e
            ears.append(ear)
            let et = Thread { [weak self] in self?.receiveLoop(ear) }
            et.name = "VBAN beacons :\(port)"
            et.qualityOfService = .utility
            et.start()
        }
        return nil
    }

    /// Binds and returns the port bound, or nil.
    private static func bind(_ fd: Int32, address: in_addr_t, port: Int) -> Int? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = address
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard ok else { return nil }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &length) }
        }
        return Int(UInt16(bigEndian: bound.sin_port))
    }

    public func stop() {
        for ear in ears {
            let fd = ear.fd
            ear.fd = -1
            Darwin.close(fd)
        }
        ears.removeAll()
        sharingPort = nil
        guard let box = socket else { return }
        let fd = box.fd
        box.fd = -1
        Darwin.close(fd)
        socket = nil
        lock.lock()
        table.removeAll()
        lock.unlock()
    }

    // MARK: - Joined streams

    public func attach(_ receiver: VBANReceiver) {
        lock.lock()
        sinks[receiver.stream.id] = receiver
        lock.unlock()
    }

    public func detach(_ receiver: VBANReceiver) {
        lock.lock()
        if sinks[receiver.stream.id] === receiver { sinks[receiver.stream.id] = nil }
        lock.unlock()
    }

    /// What has been heard recently, with anything silent for `forgetAfter` dropped, and how
    /// many new streams have been turned away since the start. Called from the main thread.
    public func snapshot() -> (entries: [Entry], refused: UInt64, renames: [Rename]) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        defer { lock.unlock() }
        table = table.filter { now - $0.value.lastSeen < Self.forgetAfter }
        let done = renames
        renames.removeAll()
        return (Array(table.values), refused, done)
    }

    // MARK: - Network thread

    private func receiveLoop(_ box: Socket) {
        var buf = [UInt8](repeating: 0, count: 2048)
        var from = sockaddr_in()
        var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        while box.fd >= 0 {
            fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(box.fd, &buf, buf.count, 0, $0, &fromLength)
                }
            }
            if n <= 0 { continue }
            buf.withUnsafeBufferPointer { p in
                if let base = p.baseAddress { handle(base, n, from) }
            }
        }
    }

    // MARK: - Remote link

    /// The outside-address question in flight on this socket, and who wants the answer.
    private var stunPending: (transaction: [UInt8], done: (RemoteCode?) -> Void)?

    /// Asks the STUN server, **from this socket**, what this network's outside address and port
    /// are for it, and makes the receiving end's code from them. The answer (or nil after 3 s)
    /// comes back on the main thread. Only when the user asks.
    public func makeRemoteCode(_ done: @escaping (RemoteCode?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, let server = OutsideAddress.serverAddress() else {
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

    /// Keeps this socket's mapping on the router alive while a code waits to be used: a
    /// question every 15 s is traffic enough (the reply is ignored).
    public func refreshRemoteMapping() {
        lock.lock(); let server = stunServer; lock.unlock()
        guard let server else { return }
        sendRaw(OutsideAddress.request().bytes, to: server)
    }
    private var stunServer: sockaddr_in?

    private func handleStun(_ p: UnsafePointer<UInt8>, _ length: Int) {
        lock.lock()
        guard let pending = stunPending,
              let (ip, port) = OutsideAddress.parseEndpoint(Array(UnsafeBufferPointer(start: p, count: length)),
                                                            transaction: pending.transaction)
        else { lock.unlock(); return }
        stunPending = nil
        lock.unlock()
        pending.done(RemoteCode(role: .receiving, address: ip, port: port))   // the engine adds its secret
    }

    private func sendRaw(_ bytes: [UInt8], to address: sockaddr_in) {
        guard let fd = socket?.fd, fd >= 0 else { return }
        var addr = address
        _ = bytes.withUnsafeBufferPointer { b in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, b.baseAddress, b.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// Remote links' encryption, by the linked Sender's "address:port": what is
    /// sent there is sealed, and from there only sealed packets are taken.
    private var linkCrypto: [String: LinkCrypto] = [:]

    private func handle(_ p: UnsafePointer<UInt8>, _ length: Int, _ from: sockaddr_in) {
        // From a linked Sender: sealed, or nothing — a plain packet from there (a forgery, or its
        // knock) is dropped, so nobody can slip audio into the link.
        lock.lock(); let anyLinks = !linkCrypto.isEmpty; lock.unlock()
        if anyLinks, let ip = Self.text(from.sin_addr) {
            let key = "\(ip):\(UInt16(bigEndian: from.sin_port))"
            lock.lock(); let crypto = linkCrypto[key]; lock.unlock()
            if let crypto {
                guard let inner = crypto.opener.open(p, length) else { return }
                inner.withUnsafeBufferPointer { b in
                    if let base = b.baseAddress { handlePlain(base, inner.count, from) }
                }
                return
            }
        }
        handlePlain(p, length, from)
    }

    private func handlePlain(_ p: UnsafePointer<UInt8>, _ length: Int, _ from: sockaddr_in) {
        // A Remote link's traffic: the address server's answer, and the other end's knocks —
        // neither is audio or VBAN's own service traffic.
        if OutsideAddress.isReply(p, length) { handleStun(p, length); return }
        if RemoteKnock.isKnock(p, length) { return }
        guard let header = VBAN.audioHeader(p, length) else {
            if let message = VBANControl.decode(p, length), let ip = Self.text(from.sin_addr) {
                handleControl(message, ip: ip, port: Int(UInt16(bigEndian: from.sin_port)))
            }
            return
        }
        guard let ip = Self.text(from.sin_addr) else { return }
        let id = "vban:\(ip)/\(header.name)"
        let now = CFAbsoluteTimeGetCurrent()

        let port = from.sin_port
        lock.lock()
        #if os(Windows)
        if !ignored.isEmpty, ignored.contains("\(ip):\(UInt16(bigEndian: port))") { lock.unlock(); return }
        #endif
        lastAudioFrom[ip] = now
        if wanted.contains(id) { audioPorts[id] = UInt16(bigEndian: port) }
        if var entry = table[id] {
            entry.lastSeen = now
            entry.lastAudio = now
            entry.nextCounter = header.counter &+ 1
            let d = entry.description
            if d.sampleRate != header.sampleRate || d.channels != header.channels
                || d.encoding != header.dataType.encoding {
                entry.description = describe(header, ip: ip, port: from.sin_port)
            }
            table[id] = entry
        } else if let old = renamed(header, id: id, ip: ip, port: port, now: now) {
            // Not a new stream: the same one under a new name. It takes the old one's place
            // rather than a new slot, so a rename is never refused by the flood limits.
            table[old] = nil
            table[id] = Entry(description: describe(header, ip: ip, port: port), lastSeen: now,
                              nextCounter: header.counter &+ 1, sourcePort: port, lastAudio: now)
            renames.append(Rename(from: old, to: id))
            retired[old] = now
        } else if admit(ip, now) {
            table[id] = Entry(description: describe(header, ip: ip, port: port), lastSeen: now,
                              nextCounter: header.counter &+ 1, sourcePort: port, lastAudio: now)
        }
        let sink = sinks[id]
        lock.unlock()

        sink?.handle(p + VBAN.headerBytes, header)
    }

    /// The stream this packet's stream used to be, if it has just been renamed. Lock held.
    ///
    /// **A workaround, made for Network Audio Sender.** VBAN has no stream identity beyond the
    /// name, so a rename looks like a new stream beginning as the old one ends — and the
    /// listener used to list each name it saw, leaving the favourite and the joined stream
    /// behind on the old one. The Sender renames in a way that can be recognised: the same
    /// address **and source port**, the same format, the old name heard within the last second,
    /// and the **frame counter carrying straight on** where the old name's stopped, because it
    /// keeps one counter for the life of its stream.
    ///
    /// Other VBAN senders may rename the same way and be followed too, but nothing in the
    /// protocol promises it and none has been checked — for them this is best effort, and a
    /// sender that restarts its counter on a rename is simply listed under the new name, as
    /// before. Two different streams from one sender run counters of their own, so they are
    /// not mistaken for each other.
    private func renamed(_ header: VBAN.Header, id: String, ip: String, port: UInt16,
                         now: CFAbsoluteTime) -> String? {
        retired = retired.filter { now - $0.value < 2 }
        guard retired[id] == nil else { return nil }
        return table.first { _, entry in
            let d = entry.description
            let step = header.counter &- entry.nextCounter      // wrap-safe
            return d.originAddress == ip && entry.sourcePort == port
                && now - entry.lastSeen < 1
                && step < 8
                // Running a moment, not just begun: two streams starting together from one
                // sender both have counters near zero.
                && entry.nextCounter > 64
                && d.sampleRate == header.sampleRate && d.channels == header.channels
                && d.encoding == header.dataType.encoding
        }?.key
    }

    /// Which wanted streams a Sender's beacon (`beacon`, from `ip`:`port`) is the renamed form of:
    /// those from the same address whose audio came from the same port, that no other live Sender
    /// is beaconing (`owned`), and whose audio has stopped (`flowing` holds the ones it hasn't,
    /// and any already renamed). Pure, for the engine check.
    public static func renamedByPort(beacon id: String, ip: String, port: UInt16, wanted: Set<String>,
                                     audioPorts: [String: UInt16], owned: Set<String>,
                                     flowing: Set<String>) -> [String] {
        wanted.filter { old in
            old != id && old.hasPrefix("vban:\(ip)/") && audioPorts[old] == port
                && !owned.contains(old) && !flowing.contains(old)
        }.sorted()
    }

    /// Whether a stream never heard before may join the table. Lock held. The per-sender check
    /// comes first, so a sender already at its limit does not use up the admissions a second
    /// that everyone else needs.
    private func admit(_ ip: String, _ now: CFAbsoluteTime) -> Bool {
        if now - admissionWindow >= 1 {
            admissionWindow = now
            admittedThisSecond = 0
        }
        guard table.count < Self.maxStreams,
              table.values.lazy.filter({ $0.description.originAddress == ip }).count
                  < Self.maxStreamsPerSender,
              admittedThisSecond < Self.newStreamsPerSecond else {
            refused += 1
            return false
        }
        admittedThisSecond += 1
        return true
    }

    // MARK: - Handshake, network thread

    /// Hands a playing stream to its Sender's other address, once. Lock held.
    private func move(from old: String, to new: String) {
        guard !renames.contains(where: { $0.from == old }) else { return }
        renames.append(Rename(from: old, to: new, moved: true))
    }

    /// Sender identity → the address its listing is kept under. Network thread, under `lock`.
    private var beaconOwners: [[UInt8]: (ip: String, seen: CFAbsoluteTime, name: String)] = [:]
    /// This Grabber's address on its chosen network, set by the app, for choosing which of a
    /// Sender's addresses to list it under.
    public var preferredAddress: String? {
        get { lock.lock(); defer { lock.unlock() }; return _preferredAddress }
        set { lock.lock(); _preferredAddress = newValue; lock.unlock() }
    }
    private var _preferredAddress: String?

    /// This Mac's own address, or one on the same /24 as it. Lock held.
    private func preferred(_ ip: String) -> Bool {
        guard let mine = _preferredAddress else { return false }
        if ip == mine { return true }
        let a = ip.split(separator: "."), b = mine.split(separator: ".")
        return a.count == 4 && b.count == 4 && a[0..<3] == b[0..<3]
    }

    private func handleControl(_ m: VBANControl.Message, ip: String, port: Int) {
        let now = CFAbsoluteTimeGetCurrent()
        let key = "\(ip):\(port)"
        lock.lock()
        switch m.kind {
        case .beacon:
            // A Sender offering its stream: listed like any VBAN stream, under the same ID its
            // audio will have, so pressing play on it is joining that stream.
            guard let name = m.name, let format = m.format, let control = m.port else { break }
            // This Grabber's own Send, offering itself: not a stream to receive here.
            if ignoresOwnSend, m.instance == VBANOffer.processInstance { break }
            let id = "vban:\(ip)/\(name)"
            // One Sender, one listing: its beacons from its other addresses are dropped. The address
            // kept is the first heard, unless a better one — this Mac's own, or on this Grabber's
            // network — comes along, or the kept one falls silent. Without that, one Sender with three addresses was listed three times.
            // A stream already playing follows its Sender to the address it is kept under, so a
            // Grabber that changes network, or hears the Sender on two, plays it once — two paths
            // meant the Sender sent everything twice.
            // But a listing whose audio is arriving is left alone: it is already playing once, and
            // may be a broadcast the Sender makes on that network, which no move would stop — moving
            // it had it stop and start again every second.
            if let instance = m.instance {
                if let owner = beaconOwners[instance], owner.ip != ip {
                    let takeOver = now - owner.seen > 5 || (preferred(ip) && !preferred(owner.ip))
                    let oldID = "vban:\(owner.ip)/\(name)"
                    let flowing = { (id: String) in self.table[id].map { now - $0.lastAudio < 2 } ?? false }
                    if takeOver {
                        if !flowing(oldID) {
                            if wanted.contains(oldID) { move(from: oldID, to: id) }
                            table[oldID] = nil
                        }
                    } else {
                        if !flowing(id) {
                            if wanted.contains(id) { move(from: id, to: oldID) }
                            table[id] = nil
                        }
                        break
                    }
                }
                // The same Sender, from the same address, under a new name: a rename. Followed by
                // its identity, so it holds whatever the audio's frame counter does — a sender that
                // restarts it on a rename (the Windows Sender) left a trail of old names.
                if let owner = beaconOwners[instance], owner.ip == ip, owner.name != name {
                    let oldID = "vban:\(ip)/\(owner.name)"
                    if table[oldID] != nil || wanted.contains(oldID),
                       !renames.contains(where: { $0.from == oldID }) {
                        renames.append(Rename(from: oldID, to: id))
                        table[oldID] = nil
                    }
                }
                // A Sender renamed while its old name played here from its audio alone (a broadcast,
                // whose packets carry no identity, so the rule above cannot see it. Its beacons come from the socket that audio came from, so the
                // same address and port make it the same Sender. Only once the old name's audio has
                // stopped, and never for a name another live Sender is beaconing.
                let owned = Set(beaconOwners.filter { $0.key != instance && now - $0.value.seen < 5 }
                                    .map { "vban:\($0.value.ip)/\($0.value.name)" })
                let flowing = Set(wanted.filter { w in table[w].map { now - $0.lastAudio < 2 } ?? false })
                let already = Set(renames.map(\.from))
                for oldID in Self.renamedByPort(beacon: id, ip: ip, port: UInt16(truncatingIfNeeded: control),
                                                wanted: wanted, audioPorts: audioPorts,
                                                owned: owned, flowing: flowing.union(already)) {
                    renames.append(Rename(from: oldID, to: id))
                    table[oldID] = nil
                    audioPorts[oldID] = nil
                }
                beaconOwners[instance] = (ip, now, name)
            }
            if wanted.contains(id), subscriptions["\(ip):\(control)"] == nil {
                // Serviced by the next tick, within a quarter of a second.
                subscriptions["\(ip):\(control)"] = Subscription(ip: ip, port: control, streamID: id)
            }
            if var entry = table[id] {
                entry.lastSeen = now
                entry.offerPort = control
                if now - entry.lastAudio > 2 {          // while audio flows, it is the authority
                    entry.description = describe(offer: name, format, ip: ip, port: control)
                }
                table[id] = entry
            } else if admit(ip, now) {
                table[id] = Entry(description: describe(offer: name, format, ip: ip, port: control),
                                  lastSeen: now, offerPort: control)
            }

        case .challenge:
            // Only for a request we made, from where we made it.
            guard var sub = subscriptions[key], let nonce = m.nonce, let cookie = m.cookie,
                  VBANCookie.equalBytes(nonce, sub.nonce) else { break }
            sub.cookie = cookie
            sub.cookieAt = now
            sub.unansweredSince = 0
            sub.timeoutLogged = false
            subscriptions[key] = sub
            let confirm = VBANControl.encode(.init(kind: .confirm, nonce: nonce, cookie: cookie,
                                                   name: receiverName, instance: receiverInstance),
                                             headerName: receiverName)
            lock.unlock()
            send(confirm, to: ip, port: port)
            return

        case .offer:
            guard var sub = subscriptions[key], sub.cookie != nil else { break }
            let first = !sub.established
            sub.established = true
            sub.establishedAt = now
            sub.lastKeepalive = now
            sub.backoff = 1
            sub.streamName = m.name
            sub.awaitingApproval = false
            sub.declined = false
            subscriptions[key] = sub
            lock.unlock()
            if first { log(.done, "The Sender at \(ip) accepted: “\(m.name ?? "its stream")” now comes to this computer only.") }
            return

        case .pending:
            guard var sub = subscriptions[key], sub.cookie != nil else { break }
            let first = !sub.awaitingApproval
            sub.awaitingApproval = true
            sub.declined = false
            sub.backoff = Self.askAgainWhilePending
            sub.nextAttempt = now + Self.askAgainWhilePending
            subscriptions[key] = sub
            lock.unlock()
            if first { log(.request, "Waiting for the Sender at \(ip) to allow this Grabber — its user has been asked.") }
            return

        case .declined:
            guard var sub = subscriptions[key], !sub.declined else { break }
            sub.declined = true
            sub.awaitingApproval = false
            // Asked again now and then, quietly — the Sender answers a denied Grabber without
            // asking its user — so an Allow given later in its settings lets this in.
            sub.nextAttempt = now + Self.askAgainWhileDeclined
            sub.backoff = Self.askAgainWhileDeclined
            subscriptions[key] = sub
            lock.unlock()
            log(.failed, "Refused: the Sender's user at \(ip) declined this Grabber.")
            return

        case .subscribe, .confirm, .keepalive, .unsubscribe:
            break                                       // meant for a Sender, not us
        }
        lock.unlock()
    }

    // MARK: - Handshake, main thread

    /// Ask the Sender offering this stream to send it here. Nothing for a stream no Sender
    /// offered — plain VBAN arrives whether asked for or not.
    public func subscribe(streamID id: String) {
        lock.lock()
        wanted.insert(id)
        guard let entry = table[id], let control = entry.offerPort else { lock.unlock(); return }
        let ip = entry.description.originAddress
        let key = "\(ip):\(control)"
        if subscriptions[key] == nil { subscriptions[key] = Subscription(ip: ip, port: control, streamID: id) }
        lock.unlock()
        service()
    }

    /// Stop asking, and tell the Sender. A Sender added by address stays subscribed: it leaves
    /// with `removeManual`.
    public func unsubscribe(streamID id: String) {
        lock.lock()
        wanted.remove(id)
        audioPorts[id] = nil
        // By its listing, or, once a rename or move has taken that away, by the stream it was
        // asked for: otherwise the link was never closed and kept asking for the old name for
        // good.
        let listed = table[id].flatMap { e in e.offerPort.map { "\(e.description.originAddress):\($0)" } }
        guard let key = listed ?? subscriptions.first(where: { $0.value.streamID == id })?.key,
              let sub = subscriptions[key], !sub.manual else { lock.unlock(); return }
        subscriptions[key] = nil
        lock.unlock()
        sayGoodbye(sub)
    }

    /// A playing stream renamed by its Sender: the link to the Sender stays as it is, now for the
    /// new name, so the audio carries on without asking again.
    public func follow(from old: String, to new: String) {
        lock.lock()
        if wanted.remove(old) != nil { wanted.insert(new) }
        if let port = audioPorts.removeValue(forKey: old) { audioPorts[new] = port }
        for (key, var sub) in subscriptions where sub.streamID == old {
            sub.streamID = new
            sub.streamName = new.split(separator: "/", maxSplits: 1).last.map(String.init)
            subscriptions[key] = sub
        }
        lock.unlock()
    }

    /// A Sender reached by address, for a VPN or anywhere its beacon cannot arrive.
    /// `crypto`: a Remote link's, so everything to and from it is sealed.
    public func addManual(ip: String, port: Int, crypto: LinkCrypto? = nil) {
        lock.lock()
        let key = "\(ip):\(port)"
        if let crypto { linkCrypto[key] = crypto }
        var sub = subscriptions[key] ?? Subscription(ip: ip, port: port)
        sub.manual = true
        subscriptions[key] = sub
        lock.unlock()
        service()
    }

    public func removeManual(ip: String, port: Int) {
        lock.lock()
        let sub = subscriptions.removeValue(forKey: "\(ip):\(port)")
        lock.unlock()
        if let sub { sayGoodbye(sub) }          // sealed, if it was a link
        lock.lock(); linkCrypto["\(ip):\(port)"] = nil; lock.unlock()
    }

    /// Leave every Sender, when VBAN is switched off or the app quits.
    public func unsubscribeAll() {
        lock.lock()
        let all = Array(subscriptions.values)
        subscriptions.removeAll()
        wanted.removeAll()
        audioPorts.removeAll()
        lock.unlock()
        all.forEach(sayGoodbye)
    }

    public enum Approval: Equatable { case waiting, declined }

    /// Subscribed Senders and whether each is sending, for Settings.
    public func subscriptionStates() -> [(ip: String, port: Int, manual: Bool, established: Bool, name: String?)] {
        lock.lock()
        defer { lock.unlock() }
        return subscriptions.values.map { ($0.ip, $0.port, $0.manual, $0.established, $0.streamName) }
            .sorted { "\($0.ip):\($0.port)" < "\($1.ip):\($1.port)" }
    }

    /// Streams whose Sender has not said yes yet, by stream ID, for their rows.
    public func approvals() -> [String: Approval] {
        lock.lock()
        defer { lock.unlock() }
        var out: [String: Approval] = [:]
        let now = CFAbsoluteTimeGetCurrent()
        for sub in subscriptions.values {
            guard let id = sub.streamID, !sub.established else { continue }
            // Its audio is arriving anyway — a broadcast under the same name: nothing to wait for.
            if let entry = table[id], now - entry.lastAudio < 2 { continue }
            if sub.declined { out[id] = .declined } else if sub.awaitingApproval { out[id] = .waiting }
        }
        return out
    }

    /// Called a few times a second: asks again with backoff until a Sender answers, keeps each
    /// subscription alive, and asks again when a Sender's audio stops.
    public func service() {
        let now = CFAbsoluteTimeGetCurrent()
        var out: [([UInt8], String, Int)] = []
        lock.lock()
        for (key, var sub) in subscriptions {
            if sub.established {
                let quiet = now - (lastAudioFrom[sub.ip] ?? 0)
                if quiet > Self.resubscribeAfter, now - sub.establishedAt > Self.resubscribeAfter {
                    sub.established = false
                    sub.cookie = nil
                    sub.nextAttempt = now
                    log(.warning, "Interrupted: no audio from “\(sub.streamName ?? sub.ip)” for \(Int(Self.resubscribeAfter)) s (the Sender quit, restarted or dropped us). Asking again.")
                } else if now - sub.lastKeepalive >= Self.keepaliveEvery, let cookie = sub.cookie {
                    sub.lastKeepalive = now
                    out.append((VBANControl.encode(.init(kind: .keepalive, cookie: cookie, name: receiverName),
                                                   headerName: receiverName), sub.ip, sub.port))
                }
            }
            if !sub.established, !sub.declined, sub.awaitingApproval, now >= sub.nextAttempt,
               let cookie = sub.cookie, now - sub.cookieAt < VBANCookie.bucketSeconds - 5 {
                // Waiting on the Sender's user: confirm again on the same cookie, so the moment
                // they allow it, the OFFER finds a subscription ready for it.
                sub.nextAttempt = now + Self.askAgainWhilePending
                out.append((VBANControl.encode(.init(kind: .confirm, nonce: sub.nonce, cookie: cookie, name: receiverName,
                                                     instance: receiverInstance),
                                               headerName: receiverName), sub.ip, sub.port))
            } else if !sub.established, now >= sub.nextAttempt {
                if sub.unansweredSince == 0 { sub.unansweredSince = now }
                if !sub.declined, !sub.timeoutLogged, now - sub.unansweredSince > 15 {
                    sub.timeoutLogged = true
                    log(.failed, "Timed out: no answer from the Sender at \(sub.ip):\(sub.port) after 15 s. "
                        + "Is it running and offering? Still asking, less often.")
                }
                sub.nonce = VBANControl.randomNonce()
                sub.cookie = nil
                sub.nextAttempt = now + sub.backoff
                sub.backoff = sub.declined ? Self.askAgainWhileDeclined
                    : sub.awaitingApproval ? Self.askAgainWhilePending : min(30, sub.backoff * 2)
                out.append((VBANControl.encode(.init(kind: .subscribe, nonce: sub.nonce, name: receiverName),
                                               headerName: receiverName), sub.ip, sub.port))
            }
            subscriptions[key] = sub
        }
        lock.unlock()
        for (bytes, ip, port) in out { send(bytes, to: ip, port: port) }
    }

    private func sayGoodbye(_ sub: Subscription) {
        guard let cookie = sub.cookie else { return }
        send(VBANControl.encode(.init(kind: .unsubscribe, cookie: cookie), headerName: receiverName),
             to: sub.ip, port: sub.port)
    }

    private func send(_ plain: [UInt8], to ip: String, port: Int) {
        guard let fd = socket?.fd, fd >= 0 else { return }
        lock.lock(); let crypto = linkCrypto["\(ip):\(port)"]; lock.unlock()
        let bytes = crypto?.sealer.seal(plain) ?? plain
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(clamping: port).bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return }
        _ = bytes.withUnsafeBufferPointer { b in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, b.baseAddress, b.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func log(_ kind: ActivityLog.Kind, _ text: String) {
        DispatchQueue.main.async { [weak self] in self?.onLog?(kind, text) }
    }

    /// Whether a Network Audio Sender offered this stream (it has a control port to ask on).
    public func isOffered(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return table[id]?.offerPort != nil
    }

    private static func text(_ a: in_addr) -> String? {
        var a = a
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN)).map { _ in String(cString: buf) }
    }

    private func describe(offer name: String, _ f: VBANControl.Format, ip: String, port: Int) -> StreamDescription {
        let frames = VBAN.framesPerPacket(channels: f.channels, dataType: f.dataType)
        return StreamDescription(name: name, originAddress: ip, groupAddress: ip, port: port, payloadType: 0,
                                 encoding: f.dataType.encoding, sampleRate: f.sampleRate, channels: f.channels,
                                 ptimeMs: Double(frames) * 1000 / Double(f.sampleRate),
                                 ptpRef: nil, source: .vban, rawSDP: "")
    }

    private func describe(_ h: VBAN.Header, ip: String, port: in_port_t) -> StreamDescription {
        StreamDescription(name: h.name, originAddress: ip, groupAddress: ip,
                          port: Int(UInt16(bigEndian: port)), payloadType: 0,
                          encoding: h.dataType.encoding, sampleRate: h.sampleRate, channels: h.channels,
                          ptimeMs: Double(h.frames) * 1000 / Double(h.sampleRate),
                          ptpRef: nil, source: .vban, rawSDP: "")
    }
}
