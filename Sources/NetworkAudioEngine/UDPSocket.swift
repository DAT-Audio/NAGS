import Foundation
#if canImport(WinSDK)
import WinSDK          // the Windows port: WinSock, and WindowsCompat.swift beside it
#endif
#if canImport(Darwin)
import Darwin
#endif

/// The one place the engine touches sockets: a UDP endpoint and a
/// UDP socket, so the transmitter, the offer and the Remote link speak in these and a Windows
/// build only has to give this file its WinSock branch. IPv4 only, like the protocol.
///
/// **Built on both**: WinSock is reached through POSIX names in
/// `WindowsCompat.swift`, and the two places Windows behaves differently — the receive timeout
/// (a DWORD of milliseconds) and the error code for *unreachable* (`WSAGetLastError()`) — have
/// their own `#if os(Windows)` branches below.

/// An IPv4 address and port, ready to send to.
public struct UDPEndpoint: Hashable, CustomStringConvertible {
    public let raw: sockaddr_in

    public init(raw: sockaddr_in) { self.raw = raw }

    /// From dotted-decimal text; nil if it isn't one.
    public init?(ip: String, port: Int) {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = UInt16(clamping: port).bigEndian
        guard inet_pton(AF_INET, ip, &a.sin_addr) == 1 else { return nil }
        raw = a
    }

    /// Looks a host name up (blocking: call it off the main thread).
    public static func resolve(host: String, port: UInt16) -> UDPEndpoint? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: IPPROTO_UDP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info,
              let a = first.pointee.ai_addr else { return nil }
        defer { freeaddrinfo(info) }
        return UDPEndpoint(raw: a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee })
    }

    public var ip: String {
        var a = raw.sin_addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN)).map { _ in String(cString: buf) } ?? ""
    }
    public var port: Int { Int(UInt16(bigEndian: raw.sin_port)) }
    /// Address and port in one number, for keeping endpoints in sets and dictionaries.
    public var key: UInt64 { UInt64(raw.sin_addr.s_addr) << 16 | UInt64(raw.sin_port) }
    public var description: String { "\(ip):\(port)" }

    public static func == (a: UDPEndpoint, b: UDPEndpoint) -> Bool { a.key == b.key }
    public func hash(into h: inout Hasher) { h.combine(key) }
}

/// A bound UDP socket. Sending from one thread while another receives on it is safe.
public final class UDPSocket {
    public let descriptor: Int32
    /// The port it was bound to: the first of the ports asked for that was free.
    public let boundPort: Int

    public enum SendResult {
        case sent
        /// The network says the host or network can't be reached (auto-stop's "Unreachable").
        case unreachable
        case failed
    }

    private init(descriptor: Int32, boundPort: Int) {
        self.descriptor = descriptor
        self.boundPort = boundPort
    }

    /// A socket bound on every interface to the first free port of `ports` (0 = any). `broadcast`
    /// lets it send to broadcast addresses; `audio` marks what it sends as live audio (see
    /// `markAsAudio`). Nil if it can't be made or none of the ports is free.
    public static func open(ports: [Int], broadcast: Bool = false, sendBuffer: Int? = nil,
                            audio: Bool = false) -> UDPSocket? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        if broadcast { setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size)) }
        if var size = sendBuffer.map(Int32.init) {
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        if audio { markAsAudio(fd) }
        TestBinding.apply(fd)
        for port in ports {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(clamping: port).bigEndian
            addr.sin_addr.s_addr = INADDR_ANY
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            guard ok else { continue }
            var bound = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &length) }
            }
            return UDPSocket(descriptor: fd, boundPort: Int(UInt16(bigEndian: bound.sin_port)))
        }
        close(fd)
        return nil
    }

    /// DSCP EF (46), the marking AES67 gives its audio: switches and Wi-Fi access points that
    /// honour it queue these packets ahead of bulk traffic, and the rest ignore it. On a Mac the
    /// socket is also "Interactive Voice", which sends it in the Mac's own Wi-Fi voice queue.
    /// A hint only: nothing fails if a network ignores or clears it.
    public static let audioDSCP: Int32 = 46

    /// Marks a socket's packets as live audio. Best effort: a failure is ignored.
    static func markAsAudio(_ fd: Int32) {
        #if canImport(Darwin)
        var service = Int32(NET_SERVICE_TYPE_VO)
        setsockopt(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE, &service, socklen_t(MemoryLayout<Int32>.size))
        var tos = audioDSCP << 2
        setsockopt(fd, IPPROTO_IP, IP_TOS, &tos, socklen_t(MemoryLayout<Int32>.size))
        #endif
        // Windows: not yet. It ignores IP_TOS from an app; marking needs the qWAVE API.
    }

    /// The DSCP the socket's packets carry, for the self-check.
    public var dscp: Int32 {
        #if canImport(Darwin)
        var tos: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, IPPROTO_IP, IP_TOS, &tos, &length) == 0 else { return -1 }
        return tos >> 2
        #else
        return 0
        #endif
    }

    deinit { close(descriptor) }

    /// Sends `length` bytes from `bytes`. Allocates nothing.
    @inline(__always)
    public func send(_ bytes: UnsafeRawPointer, _ length: Int, to endpoint: UDPEndpoint) -> SendResult {
        var address = endpoint.raw
        let sent = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(descriptor, bytes, length, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if sent == length { return .sent }
        #if os(Windows)
        // WinSock reports through `WSAGetLastError()`, not `errno`; the codes are its own.
        return unreachableSocketErrors.contains(lastSocketError) ? .unreachable : .failed
        #else
        let e = errno
        return [EHOSTDOWN, EHOSTUNREACH, ENETUNREACH, ENETDOWN, EADDRNOTAVAIL].contains(e) ? .unreachable : .failed
        #endif
    }

    @discardableResult
    public func send(_ bytes: [UInt8], to endpoint: UDPEndpoint) -> SendResult {
        bytes.withUnsafeBytes { send($0.baseAddress!, $0.count, to: endpoint) }
    }

    /// How long `receive` waits before giving up and returning nil.
    public func setReceiveTimeout(_ seconds: Double) {
        #if os(Windows)
        // WinSock takes the receive timeout as a DWORD of milliseconds, not a `timeval`.
        var timeout = DWORD(max(0, seconds) * 1000)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<DWORD>.size))
        #else
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        #endif
    }

    /// One datagram into `buffer`: its length and who sent it, or nil on a timeout or error.
    public func receive(into buffer: UnsafeMutableRawPointer, capacity: Int) -> (length: Int, from: UDPEndpoint)? {
        var from = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(descriptor, buffer, capacity, 0, $0, &length)
            }
        }
        return n > 0 ? (n, UDPEndpoint(raw: from)) : nil
    }
}
