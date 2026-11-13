import Foundation
#if canImport(WinSDK)
import WinSDK          // the Windows port: WinSock, and WindowsCompat.swift beside it
#endif

/// Scream: a virtual sound card for Windows that sends the PC's audio over the network as raw PCM
/// (github.com/duncanthrax/scream). Implemented here from the protocol description in its
/// README, not from its code — the repository's MS-PL covers the code, which is not used
/// (PROTO-1).
///
/// The whole protocol: UDP to 239.255.77.77:4010 (or unicast, if the sender is set up that way),
/// each datagram a 5-byte header and up to 1152 bytes of little-endian PCM:
///
///     byte 0   sample rate: bit 7 picks the base (0 = 48 kHz, 1 = 44.1 kHz), bits 0–6 multiply it
///     byte 1   bits per sample
///     byte 2   channels
///     byte 3–4 channel mask (the low half of WAVEFORMATEXTENSIBLE's dwChannelMask)
///
/// There is no stream name, no sequence number and no timestamp. So one sender is one stream,
/// loss cannot be counted, and the receiver follows the sender's pace — the `.lan` latency
/// class, as VBAN.
public enum Scream {
    public static let group = "239.255.77.77"
    public static let port = 4010
    public static let headerBytes = 5

    public struct Header: Equatable {
        public let sampleRate: Int
        public let encoding: SampleEncoding
        public let channels: Int
        public let channelMask: UInt16
        public let frames: Int
    }

    /// Reads and validates one datagram. Nil for anything that is not a Scream packet this app
    /// can play — every check made before a sample is touched, since all of it is untrusted.
    public static func header(_ p: UnsafePointer<UInt8>, _ length: Int) -> Header? {
        var r = ByteReader(p, count: length)
        guard let rateByte = r.u8(), let bits = r.u8(), let channelByte = r.u8(),
              let mask = r.u16le() else { return nil }
        let base = rateByte & 0x80 != 0 ? 44_100 : 48_000
        let multiplier = Int(rateByte & 0x7F)
        guard (1...8).contains(multiplier) else { return nil }          // up to 384 / 352.8 kHz
        let encoding: SampleEncoding
        switch bits {
        case 16: encoding = .PCM16
        case 24: encoding = .PCM24
        case 32: encoding = .PCM32
        default: return nil
        }
        let channels = Int(channelByte)
        guard (1...64).contains(channels) else { return nil }
        let frameBytes = channels * encoding.bytesPerSample
        let payload = r.remaining
        guard payload > 0, payload <= 1152, payload % frameBytes == 0 else { return nil }
        return Header(sampleRate: base * multiplier, encoding: encoding, channels: channels,
                      channelMask: mask, frames: payload / frameBytes)
    }
}

/// Listens for Scream on UDP 4010 — the multicast group and unicast alike — and lists one stream
/// per sender. Joined streams get their packets from here, as VBAN's do from `VBANListener`.
public final class ScreamListener {
    public init() {}

    public struct Entry {
        public var description: StreamDescription
        public var lastSeen: CFAbsoluteTime
    }

    /// Flood limits, as VBAN's: anything on the network can send to this port.
    public static let maxStreams = 16
    public static let newStreamsPerSecond = 4
    /// Scream has no announcements, so a sender that stops is forgotten after this long.
    public static let forgetAfter: CFAbsoluteTime = 15

    private final class Socket { var fd: Int32 = -1 }
    private var socket: Socket?
    /// Sharing: another copy — the app, or a Grabber plugin — already has UDP 4010,
    /// so this one binds to the Scream **group address** instead and hears the multicast only.
    /// Unicast Scream still reaches only the other copy (checked on macOS with a test port).
    public private(set) var sharing = false
    private let lock = NSLock()
    private var table: [String: Entry] = [:]
    private var sinks: [String: ScreamReceiver] = [:]
    private var admittedThisSecond = 0
    private var admissionWindow: CFAbsoluteTime = 0
    public private(set) var refused: UInt64 = 0

    /// Opens UDP 4010 and joins the Scream group on `interfaceAddress`. Returns an error message
    /// on failure.
    public func start(interfaceAddress: String) -> String? {
        stop()
        let s = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        #if os(Windows)
        // WinSock reports through `WSAGetLastError()`, which `strerror` knows nothing about.
        guard s >= 0 else { return "Scream: socket() failed: \(socketErrorText())" }
        #else
        guard s >= 0 else { return "Scream: socket() failed: \(String(cString: strerror(errno)))" }
        #endif
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var rcvbuf = Int32(2 * 1024 * 1024)
        setsockopt(s, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))
        #if os(Windows)
        // WinSock takes the receive timeout as a DWORD of milliseconds, not a `timeval`.
        var timeout = DWORD(500)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<DWORD>.size))
        #else
        var tv = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        #endif

        // INADDR_ANY rather than the group, so unicast Scream arrives here too — unless another
        // copy has the port, when the group address is shared instead (multicast only).
        func bind(to address: in_addr_t) -> Bool {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(Scream.port).bigEndian
            addr.sin_addr.s_addr = address
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
        }
        sharing = false
        if !bind(to: INADDR_ANY) {
            #if os(Windows)
            let inUse = lastSocketError == WSAEADDRINUSE
            #else
            let inUse = errno == EADDRINUSE
            #endif
            guard inUse, bind(to: inet_addr(Scream.group)) else {
                #if os(Windows)
                let e = socketErrorText()
                #else
                let e = String(cString: strerror(errno))
                #endif
                Darwin.close(s)
                return inUse
                    ? "Scream: UDP \(Scream.port) is already in use by another app, so Scream is not listening."
                    : "Scream: could not open UDP \(Scream.port): \(e)."
            }
            sharing = true
        }
        var mreq = ip_mreq()
        mreq.imr_multiaddr.s_addr = inet_addr(Scream.group)
        mreq.imr_interface.s_addr = inet_addr(interfaceAddress)
        if setsockopt(s, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size)) != 0 {
            // Not fatal: unicast Scream still arrives. Said, so a silent group is explained.
            #if os(Windows)
            let e = socketErrorText()
            #else
            let e = String(cString: strerror(errno))
            #endif
            Darwin.close(s)
            return "Scream: could not join \(Scream.group) on \(interfaceAddress): \(e)."
        }

        let box = Socket()
        box.fd = s
        socket = box
        let t = Thread { [weak self] in self?.receiveLoop(box) }
        t.name = "Scream :\(Scream.port)"
        t.qualityOfService = .userInteractive
        t.start()
        return nil
    }

    public func stop() {
        guard let box = socket else { return }
        let fd = box.fd
        box.fd = -1
        Darwin.close(fd)
        socket = nil
        lock.lock()
        table.removeAll()
        lock.unlock()
    }

    public func attach(_ receiver: ScreamReceiver) {
        lock.lock()
        sinks[receiver.stream.id] = receiver
        lock.unlock()
    }

    public func detach(_ receiver: ScreamReceiver) {
        lock.lock()
        if sinks[receiver.stream.id] === receiver { sinks[receiver.stream.id] = nil }
        lock.unlock()
    }

    /// What has been heard recently, anything silent for `forgetAfter` dropped. Main thread.
    public func snapshot() -> [Entry] {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        defer { lock.unlock() }
        table = table.filter { now - $0.value.lastSeen < Self.forgetAfter }
        return Array(table.values)
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

    private func handle(_ p: UnsafePointer<UInt8>, _ length: Int, _ from: sockaddr_in) {
        guard let header = Scream.header(p, length), let ip = Self.text(from.sin_addr) else { return }
        let id = "scream:\(ip)"
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if var entry = table[id] {
            entry.lastSeen = now
            let d = entry.description
            if d.sampleRate != header.sampleRate || d.channels != header.channels
                || d.encoding != header.encoding || d.framesPerPacket < header.frames {
                entry.description = Self.describe(header, ip: ip)
            }
            table[id] = entry
        } else if admit(now) {
            table[id] = Entry(description: Self.describe(header, ip: ip), lastSeen: now)
        }
        let sink = sinks[id]
        lock.unlock()
        sink?.handle(p + Scream.headerBytes, header)
    }

    /// At most `maxStreams` listed, and `newStreamsPerSecond` new ones a second. Lock held.
    private func admit(_ now: CFAbsoluteTime) -> Bool {
        if now - admissionWindow >= 1 { admissionWindow = now; admittedThisSecond = 0 }
        guard table.count < Self.maxStreams, admittedThisSecond < Self.newStreamsPerSecond else {
            refused += 1
            return false
        }
        admittedThisSecond += 1
        return true
    }

    private static func text(_ a: in_addr) -> String? {
        var a = a
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN)).map { _ in String(cString: buf) }
    }

    /// No name in the protocol, so the stream is named for where it comes from.
    public static func describe(_ h: Scream.Header, ip: String) -> StreamDescription {
        StreamDescription(name: "Scream from \(ip)", originAddress: ip, groupAddress: Scream.group,
                          port: Scream.port, payloadType: 0, encoding: h.encoding,
                          sampleRate: h.sampleRate, channels: h.channels,
                          ptimeMs: Double(h.frames) * 1000 / Double(h.sampleRate),
                          ptpRef: nil, source: .scream, rawSDP: "")
    }
}
