import Foundation
#if canImport(WinSDK)
import WinSDK          // the Windows port: WinSock, and WindowsCompat.swift beside it
#endif

/// Receives one RTP stream — AES67, or plain RTP from PipeWire, PulseAudio, VLC or GStreamer
/// — on its own socket, multicast or sent to this Mac, and decodes L16/L24/L32 big-endian
/// PCM. It never reads RTP timestamps or PTP: buffering, drift control, mixing and metering are
/// `StreamReceiver`'s, by arrival, which is why a stream without a PTP clock plays as well.
public final class RTPReceiver: StreamReceiver {
    private var socket: MulticastSocket?
    private var thread: Thread?
    private var running = false
    private var expectedSeq: UInt16 = 0
    private var haveSeq = false

    deinit { stop() }

    // MARK: - Network

    /// Starts receiving. Returns an error message on failure.
    public override func start(interfaceAddress: String) -> String? {
        stop()
        let sock = MulticastSocket(group: stream.groupAddress, port: stream.port,
                                   interfaceAddress: interfaceAddress)
        if let err = sock.open() { return err }
        socket = sock
        running = true
        let t = Thread { [weak self] in self?.receiveLoop(sock) }
        t.name = "RTP \(stream.groupAddress):\(stream.port)"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        return nil
    }

    public override func stop() {
        running = false
        socket?.close()
        socket = nil
        thread = nil
    }

    private func receiveLoop(_ sock: MulticastSocket) {
        if sock.isUnicast { receiveUnicast(sock); return }
        var buf = [UInt8](repeating: 0, count: 4096)
        while running && sock.fd >= 0 {
            let n = recv(sock.fd, &buf, buf.count, 0)
            if n <= 0 { continue }
            buf.withUnsafeBufferPointer { p in
                if let base = p.baseAddress { handlePacket(base, n) }
            }
        }
    }

    /// A stream sent to this Mac's own address. The socket is bound to the port on every
    /// address, and on BSD that also delivers multicast for groups other sockets have joined on
    /// the same port — AES67's usual 5004. So each datagram's destination is read and anything
    /// sent to a group is dropped: it belongs to another stream.
    private func receiveUnicast(_ sock: MulticastSocket) {
        #if os(Windows)
        // Windows hands a datagram sent to a multicast group only to the sockets that joined that
        // group, so a socket bound to the port on every address hears what was sent to this PC and
        // nothing else. There is no stray multicast to tell apart, and so nothing for the
        // destination-address option to answer: a plain `recv` is both simpler and right here.
        var buf = [UInt8](repeating: 0, count: 4096)
        while running && sock.fd >= 0 {
            let n = recv(sock.fd, &buf, buf.count, 0)
            if n <= 0 { continue }
            buf.withUnsafeBufferPointer { p in
                if let base = p.baseAddress { handlePacket(base, n) }
            }
        }
        #else
        var buf = [UInt8](repeating: 0, count: 4096)
        let controlSize = 64
        let control = UnsafeMutableRawPointer.allocate(byteCount: controlSize, alignment: 8)
        defer { control.deallocate() }
        while running && sock.fd >= 0 {
            let n: Int = buf.withUnsafeMutableBytes { raw in
                var iov = iovec(iov_base: raw.baseAddress, iov_len: raw.count)
                return withUnsafeMutablePointer(to: &iov) { iovp in
                    var msg = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: iovp, msg_iovlen: 1,
                                     msg_control: control, msg_controllen: socklen_t(controlSize),
                                     msg_flags: 0)
                    let got = recvmsg(sock.fd, &msg, 0)
                    guard got > 0, !Self.sentToGroup(&msg) else { return 0 }
                    return got
                }
            }
            if n <= 0 { continue }
            buf.withUnsafeBufferPointer { p in
                if let base = p.baseAddress { handlePacket(base, n) }
            }
        }
        #endif
    }

    #if !os(Windows)
    /// Whether `IP_RECVDSTADDR` says the datagram went to a multicast address.
    private static func sentToGroup(_ msg: inout msghdr) -> Bool {
        guard msg.msg_controllen >= socklen_t(MemoryLayout<cmsghdr>.size),
              let base = msg.msg_control else { return false }
        var offset = 0
        let end = Int(msg.msg_controllen)
        while offset + MemoryLayout<cmsghdr>.size <= end {
            let header = base.load(fromByteOffset: offset, as: cmsghdr.self)
            let length = Int(header.cmsg_len)
            guard length >= MemoryLayout<cmsghdr>.size, offset + length <= end else { return false }
            if header.cmsg_level == IPPROTO_IP, header.cmsg_type == IP_RECVDSTADDR,
               length >= MemoryLayout<cmsghdr>.size + MemoryLayout<in_addr>.size {
                let addr = base.loadUnaligned(fromByteOffset: offset + MemoryLayout<cmsghdr>.size, as: in_addr.self)
                let first = UInt32(bigEndian: addr.s_addr) >> 24
                return (224...239).contains(first)
            }
            // CMSG_ALIGN: 4-byte on Darwin.
            offset += (length + 3) & ~3
        }
        return false
    }
    #endif

    private func handlePacket(_ p: UnsafePointer<UInt8>, _ length: Int) {
        guard length >= 12, (p[0] >> 6) == 2 else { return }          // RTP version 2
        let csrcCount = Int(p[0] & 0x0F)
        let hasExtension = (p[0] & 0x10) != 0
        let payloadType = p[1] & 0x7F
        guard payloadType == stream.payloadType else { return }

        var offset = 12 + csrcCount * 4
        if hasExtension {
            guard length >= offset + 4 else { return }
            let words = Int(p[offset + 2]) << 8 | Int(p[offset + 3])
            offset += 4 + words * 4
        }
        guard length > offset else { return }

        let seq = UInt16(p[2]) << 8 | UInt16(p[3])
        let bytesPerFrame = stream.encoding.bytesPerSample * stream.channels
        let frames = (length - offset) / bytesPerFrame
        guard frames > 0, frames <= maxPacketFrames else { return }

        // Sequence continuity: pad short gaps with silence so channel alignment survives loss.
        if haveSeq {
            let delta = Int(Int16(bitPattern: seq &- expectedSeq))   // signed, wrap-safe
            if delta < 0 {
                return                                               // reordered or duplicate
            } else if delta > 0 && delta < 64 {
                recordLoss(packets: delta, silenceFrames: delta * frames)
            } else if delta >= 64 {
                recordLoss(packets: 1, silenceFrames: 0)             // sender restarted; just carry on
            }
        }
        expectedSeq = seq &+ 1
        haveSeq = true

        decode(p + offset, frames: frames, into: scratch)
        deliver(frames: frames)
    }

    private func decode(_ src: UnsafePointer<UInt8>, frames: Int, into dst: UnsafeMutablePointer<Float>) {
        let count = frames * stream.channels
        switch stream.encoding {
        case .L16:
            let scale = Float(1.0 / 32768.0)
            for i in 0..<count {
                let b = src + i * 2
                let v = Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))
                dst[i] = Float(v) * scale
            }
        case .L24:
            let scale = Float(1.0 / 8388608.0)
            for i in 0..<count {
                let b = src + i * 3
                var v = Int32(b[0]) << 16 | Int32(b[1]) << 8 | Int32(b[2])
                if v & 0x800000 != 0 { v -= 0x1000000 }               // sign-extend 24-bit
                dst[i] = Float(v) * scale
            }
        case .L32:
            let scale = Float(1.0 / 2147483648.0)
            for i in 0..<count {
                let b = src + i * 4
                let u = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
                dst[i] = Float(Int32(bitPattern: u)) * scale
            }
        case .PCM16, .PCM24, .PCM32, .F32, .F64:
            break                                                    // VBAN's; no SDP announces them
        }
    }
}
