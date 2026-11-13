import Foundation

/// Cuts captured audio into VBAN packets and sends each one to every active destination.
///
/// **One stream, many destinations.** The Mac sends one named stream; every destination gets
/// the same packets with the same frame counter, which is what VBAN receivers expect of a
/// stream. A muted destination gets packets of silence rather than none, so it keeps its place
/// in the receiver's list instead of disappearing after its 15 seconds of quiet.
///
/// Runs on the capture queue — not a real-time thread, so an ordinary UDP send is fine there.
/// The destination list is swapped in from the main thread under a lock.
///
/// **Silence when macOS sends nothing.** macOS runs the
/// system-audio tap only while something plays, so on a quiet Mac no buffers arrive and nothing
/// would be sent — muted or not — and a Grabber showed "No packets", and dropped a stream it was
/// not playing after 15 s. While there are destinations, a 20 ms keep-alive sends silence at
/// the last rate and channel count once capture has been quiet for 60 ms, until audio returns.
/// `pushLock` keeps it and the capture queue from interleaving in the packet buffer.
public final class VBANTransmitter {
    public struct Destination: Equatable {
        public var address: String
        public var port: Int
        public var muted: Bool
        /// A Remote link's end: every packet sealed.
        public var sealer: RemoteSealer?
        public init(address: String, port: Int, muted: Bool, sealer: RemoteSealer? = nil) {
            self.address = address; self.port = port; self.muted = muted; self.sealer = sealer
        }
        public static func == (a: Destination, b: Destination) -> Bool {
            a.address == b.address && a.port == b.port && a.muted == b.muted && a.sealer === b.sealer
        }
    }

    private let lock = NSLock()
    private var destinations: [(UDPEndpoint, Bool, RemoteSealer?)] = []
    /// Some destination is sealed: packets are cut smaller, so a sealed one still fits one datagram.
    private var anySealed = false
    /// The stream name as a packet carries it, made when the name changes rather than for
    /// every packet on the capture thread.
    private var nameBytes = VBAN.wireNameBytes("Mac Audio")
    private var dataType: VBAN.DataType = .int16

    private var socket: UDPSocket?
    private var counter: UInt32 = 0

    // Frames waiting to fill a packet, interleaved.
    private var pending: UnsafeMutablePointer<Float>
    private let pendingCapacity = 16384 * 2
    private var pendingFrames = 0
    private var pendingChannels = 2
    private var silence: UnsafeMutablePointer<Float>
    private var packet: UnsafeMutablePointer<UInt8>

    // For the status line. Written on the capture queue, read on the main thread.
    public private(set) var packetsSent: UInt64 = 0
    public private(set) var bytesSent: UInt64 = 0
    public private(set) var sendErrors: UInt64 = 0
    public private(set) var unsupportedRate: Int?

    /// Destinations this Mac cannot reach — the network says the host is down or unreachable —
    /// and since when, by address and port (for auto-stop and the "Unreachable"
    /// status). UDP says nothing about a reachable address nobody is listening on; this is the
    /// only "no connection" there is to know. Touched only when a destination changes state.
    private let reachLock = NSLock()
    private var failing: [UDPEndpoint: CFAbsoluteTime] = [:]
    private var anyFailing = false

    /// "address:port" of each destination failing now, and since when. Main thread.
    public func unreachable() -> [String: CFAbsoluteTime] {
        reachLock.lock(); defer { reachLock.unlock() }
        var out: [String: CFAbsoluteTime] = [:]
        for (endpoint, since) in failing { out[endpoint.description] = since }
        return out
    }

    private let pushLock = NSLock()
    private var lastPush: CFAbsoluteTime = 0
    private var lastRate = 48000
    private var lastChannels = 2
    private var filling = false
    private var filledUpTo: CFAbsoluteTime = 0
    private var keepAlive: DispatchSourceTimer?
    private let keepAliveQueue = DispatchQueue(label: "VBAN keep-alive", qos: .userInitiated)
    /// Silence sent while capture delivered nothing, in frames: for the self-test.
    public private(set) var framesFilled: UInt64 = 0

    /// `openNow: false` (the Grabber's Send) holds no port until there is somewhere to send,
    /// or the offer starts: `openIfNeeded`.
    public init(openNow: Bool = true) {
        pending = .allocate(capacity: pendingCapacity)
        silence = .allocate(capacity: VBAN.maxFrames * 256)
        silence.initialize(repeating: 0, count: VBAN.maxFrames * 256)
        packet = .allocate(capacity: VBAN.headerBytes + VBAN.maxPayloadBytes)
        if openNow { openSocket() }
    }

    /// Opens the socket if it is not open yet. Main thread.
    public func openIfNeeded() {
        lock.lock()
        if socket == nil { openSocket() }
        lock.unlock()
    }

    deinit {
        keepAlive?.cancel()
        pending.deallocate()
        silence.deallocate()
        packet.deallocate()
    }

    /// The port audio is sent from and handshake requests arrive on: `VBANControl.controlPort`
    /// (6981), or whatever the system gave if another Sender on this Mac already has that. The
    /// beacon says which, so a Grabber always knows where to ask.
    public var boundPort: Int { socket?.boundPort ?? 0 }
    /// The socket, for `VBANOffer` to receive on and reply from. Sending audio and receiving
    /// requests on one UDP socket from two threads is safe.
    public var udpSocket: UDPSocket? { socket }

    /// One socket that may send to broadcast addresses, bound to the control port so the
    /// handshake (`docs/PROTOCOL.md`) and the audio share it — or any port, if another Sender
    /// on this machine has that one. Marked as live audio (`UDPSocket.markAsAudio`).
    private func openSocket() {
        socket = UDPSocket.open(ports: [VBANControl.controlPort, 0], broadcast: true, sendBuffer: 1 << 20,
                                audio: true)
    }

    // MARK: - Main thread

    public func configure(name: String, dataType: VBAN.DataType, destinations list: [Destination]) {
        let resolved: [(UDPEndpoint, Bool, RemoteSealer?)] = list.compactMap { d in
            UDPEndpoint(ip: d.address, port: d.port).map { ($0, d.muted, d.sealer) }
        }
        // Forget destinations no longer sent to, so one that comes back starts afresh.
        reachLock.lock()
        let keep = Set(resolved.map(\.0))
        failing = failing.filter { keep.contains($0.key) }
        anyFailing = !failing.isEmpty
        reachLock.unlock()
        lock.lock()
        if socket == nil, !resolved.isEmpty { openSocket() }
        nameBytes = VBAN.wireNameBytes(name)
        self.dataType = dataType
        destinations = resolved
        anySealed = resolved.contains { $0.2 != nil }
        lock.unlock()
        if resolved.isEmpty {
            keepAlive?.cancel(); keepAlive = nil
        } else if keepAlive == nil {
            let t = DispatchSource.makeTimerSource(queue: keepAliveQueue)
            t.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.fillSilence() }
            t.resume()
            keepAlive = t
        }
    }

    /// The keep-alive: silence for the time capture has been quiet, once it has been for 60 ms.
    private func fillSilence() {
        pushLock.lock(); defer { pushLock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        if !filling {
            guard now - lastPush > 0.06 else { return }
            filling = true
            filledUpTo = max(lastPush, now - 0.06)
        }
        let rate = lastRate, channels = min(64, max(1, lastChannels))
        var frames = min(Int(Double(rate) * (now - filledUpTo)), rate / 5)
        guard frames > 0 else { return }
        filledUpTo += Double(frames) / Double(rate)
        if now - filledUpTo > 0.2 { filledUpTo = now }       // never try to catch up a long stall
        framesFilled &+= UInt64(frames)
        while frames > 0 {
            let chunk = min(frames, VBAN.maxFrames)
            pushLocked(silence, frames: chunk, channels: channels, sampleRate: rate)
            frames -= chunk
        }
    }

    // MARK: - Capture queue

    /// Takes a buffer from the capture and sends every whole packet it completes.
    public func push(_ samples: UnsafePointer<Float>, frames: Int, channels: Int, sampleRate: Int) {
        pushLock.lock(); defer { pushLock.unlock() }
        lastPush = CFAbsoluteTimeGetCurrent()
        filling = false
        lastRate = sampleRate
        lastChannels = channels
        pushLocked(samples, frames: frames, channels: channels, sampleRate: sampleRate)
    }

    private func pushLocked(_ samples: UnsafePointer<Float>, frames: Int, channels: Int, sampleRate: Int) {
        lock.lock()
        let targets = destinations
        let nameBytes = self.nameBytes
        let dataType = self.dataType
        let sealedNow = anySealed
        lock.unlock()
        guard !targets.isEmpty, socket != nil else { pendingFrames = 0; return }
        guard VBAN.sampleRates.contains(sampleRate) else { unsupportedRate = sampleRate; return }
        unsupportedRate = nil

        if channels != pendingChannels { pendingFrames = 0; pendingChannels = channels }
        // A sealed packet carries `RemoteSeal.overhead` more; cut to fit one 1 500-byte datagram.
        let perPacket = VBAN.framesPerPacket(channels: channels, dataType: dataType,
                                             maxPayload: sealedNow ? VBAN.maxPayloadBytes - RemoteSeal.overhead
                                                                   : VBAN.maxPayloadBytes)
        // The size changed under a part-filled packet (a sealed end came or went): start afresh.
        if pendingFrames >= perPacket { pendingFrames = 0 }
        var offset = 0
        while offset < frames {
            let take = min(frames - offset, perPacket - pendingFrames,
                           pendingCapacity / channels - pendingFrames)
            (pending + pendingFrames * channels).update(from: samples + offset * channels,
                                                        count: take * channels)
            pendingFrames += take
            offset += take
            if pendingFrames == perPacket {
                send(frames: perPacket, channels: channels, rate: sampleRate, dataType: dataType,
                     nameBytes: nameBytes, to: targets)
                pendingFrames = 0
            }
        }
    }

    private func send(frames: Int, channels: Int, rate: Int, dataType: VBAN.DataType,
                      nameBytes: [UInt8], to targets: [(UDPEndpoint, Bool, RemoteSealer?)]) {
        var audible = 0
        var silent = 0
        if targets.contains(where: { !$0.1 }) {
            audible = VBAN.writeAudioPacket(into: packet, samples: pending, frames: frames,
                                            channels: channels, sampleRate: rate,
                                            dataType: dataType, nameBytes: nameBytes, counter: counter) ?? 0
            for (addr, muted, sealer) in targets where !muted { transmit(audible, to: addr, sealer: sealer) }
        }
        if targets.contains(where: { $0.1 }) {
            silent = VBAN.writeAudioPacket(into: packet, samples: silence, frames: frames,
                                           channels: channels, sampleRate: rate,
                                           dataType: dataType, nameBytes: nameBytes, counter: counter) ?? 0
            for (addr, muted, sealer) in targets where muted { transmit(silent, to: addr, sealer: sealer) }
        }
        counter &+= 1
    }

    private func transmit(_ length: Int, to endpoint: UDPEndpoint, sealer: RemoteSealer?) {
        guard length > 0, let socket else { return }
        let result: UDPSocket.SendResult
        if let sealer {
            let sealed = sealer.seal(UnsafeRawBufferPointer(start: packet, count: length))
            result = sealed.withUnsafeBytes { socket.send($0.baseAddress!, $0.count, to: endpoint) }
        } else {
            result = socket.send(packet, length, to: endpoint)
        }
        switch result {
        case .sent:
            packetsSent &+= 1
            bytesSent &+= UInt64(length)
            if anyFailing {
                reachLock.lock()
                failing[endpoint] = nil
                anyFailing = !failing.isEmpty
                reachLock.unlock()
            }
        case .unreachable:
            sendErrors &+= 1
            reachLock.lock()
            if failing[endpoint] == nil { failing[endpoint] = CFAbsoluteTimeGetCurrent() }
            anyFailing = true
            reachLock.unlock()
        case .failed:
            sendErrors &+= 1
        }
    }
}
