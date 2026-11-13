import Foundation
#if canImport(WinSDK)
import WinSDK          // the Windows port: WinSock, and WindowsCompat.swift beside it
#endif

/// A UDP socket joined to one IPv4 multicast group on one specific interface.
///
/// The socket is bound to the *group address* rather than INADDR_ANY. On macOS/BSD that
/// makes the kernel filter delivery by destination address, so several AES67 streams that
/// all use port 5004 (the norm) each land only in their own socket.
public final class MulticastSocket {
    public private(set) var fd: Int32 = -1
    private let group: String
    private let port: Int
    private let interfaceAddress: String

    public init(group: String, port: Int, interfaceAddress: String) {
        self.group = group
        self.port = port
        self.interfaceAddress = interfaceAddress
    }

    deinit { close() }

    /// 224.0.0.0/4.
    public static func isMulticast(_ address: String) -> Bool {
        guard let first = address.split(separator: ".").first.flatMap({ Int($0) }) else { return false }
        return (224...239).contains(first)
    }

    /// Whether this socket is for a stream sent to this Mac's own address (D3), which is bound
    /// to the port on every address and joins nothing — and so, on BSD, also receives multicast
    /// for groups joined by other sockets on the same port. `RTPReceiver` checks each packet's
    /// destination for that reason.
    public var isUnicast: Bool { !Self.isMulticast(group) }

    /// Opens, binds and joins. Returns an error message on failure.
    public func open(receiveBufferBytes: Int = 4 * 1024 * 1024, timeoutMs: Int = 500) -> String? {
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { return "socket() failed: \(errnoText())" }

        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

        var rcvbuf = Int32(receiveBufferBytes)
        setsockopt(s, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))

        #if os(Windows)
        // WinSock takes the receive timeout as a DWORD of milliseconds, not a `timeval`.
        var timeout = DWORD(timeoutMs)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<DWORD>.size))
        #else
        var tv = timeval(tv_sec: timeoutMs / 1000, tv_usec: Int32((timeoutMs % 1000) * 1000))
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        #endif

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = isUnicast ? INADDR_ANY : ipv4(group)
        #if os(Windows)
        // WinSock will not bind to a multicast address (every SAP bind failed). It needs no such filter either: it hands a group's datagrams
        // only to the sockets that joined that group, so the any-address does what the group
        // address does on BSD.
        addr.sin_addr.s_addr = INADDR_ANY
        #endif
        #if !os(Windows)
        if isUnicast {
            // Ask for each datagram's destination, so multicast arriving on this port can be
            // told from what was sent here.
            setsockopt(s, IPPROTO_IP, IP_RECVDSTADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        }
        // Windows has no such option and needs none: it delivers a group's datagrams only to the
        // sockets that joined that group, so nothing arrives here that was not sent here.
        // `RTPReceiver.receiveUnicast` says the same from the other side.
        #endif

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(s)
            return "bind \(group):\(port) failed: \(errnoText())"
        }

        if isUnicast {
            fd = s
            return nil
        }
        var mreq = ip_mreq()
        mreq.imr_multiaddr.s_addr = ipv4(group)
        mreq.imr_interface.s_addr = ipv4(interfaceAddress)
        guard setsockopt(s, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size)) == 0 else {
            let e = errnoText()
            Darwin.close(s)
            return "joining \(group) on \(interfaceAddress) failed: \(e)"
        }

        fd = s
        return nil
    }

    public func close() {
        guard fd >= 0 else { return }
        if isUnicast { Darwin.close(fd); fd = -1; return }
        var mreq = ip_mreq()
        mreq.imr_multiaddr.s_addr = ipv4(group)
        mreq.imr_interface.s_addr = ipv4(interfaceAddress)
        setsockopt(fd, IPPROTO_IP, IP_DROP_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))
        Darwin.close(fd)
        fd = -1
    }

    private func errnoText() -> String {
        #if os(Windows)
        // WinSock reports through `WSAGetLastError()`, which `strerror` knows nothing about.
        return socketErrorText()
        #else
        return String(cString: strerror(errno))
        #endif
    }
}

/// Converts a dotted-quad string into a network-order `in_addr_t`.
public func ipv4(_ s: String) -> in_addr_t {
    var a = in_addr()
    guard inet_pton(AF_INET, s, &a) == 1 else { return 0 }
    return a.s_addr
}
