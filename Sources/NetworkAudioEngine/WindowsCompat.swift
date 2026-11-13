#if os(Windows)
import Foundation
import WinSDK

/// Windows stand-ins for what the engine reaches for on the Mac. **Every line of this file is inside `#if os(Windows)`, so the Mac
/// build never sees it.**
///
/// It exists so the rest of the engine reads the same on both platforms. Where Windows differs in
/// *behaviour* — `getifaddrs`, `recvmsg`, the destination-address option, the audio lock — the
/// file that uses it has its own `#if os(Windows)` branch instead; nothing is papered over here
/// that a reader would want to know about at the call site.
///
/// Four jobs:
///  1. `CFAbsoluteTime`, which is CoreFoundation's and which Windows' Foundation does not carry.
///  2. The POSIX socket names Windows spells differently (`in_addr_t`, `s_addr`, `IPPROTO_UDP`).
///  3. WinSock under POSIX names with an `Int32` descriptor, so the engine's socket calls compile
///     unchanged.
///  4. `WSAStartup`, once, before the first socket.

// MARK: - CoreFoundation's clock

/// Seconds since 2001-01-01 00:00:00 UTC. The engine uses this only ever as a difference — "how
/// long since I last saw this stream" — so what matters is that it is one clock throughout.
public typealias CFAbsoluteTime = Double

/// Foundation's `Date` counts from the same instant, so this is the same number the Mac gets.
public func CFAbsoluteTimeGetCurrent() -> CFAbsoluteTime { Date().timeIntervalSinceReferenceDate }

// MARK: - Socket types Windows spells differently

public typealias in_addr_t = UInt32
public typealias in_port_t = UInt16
public typealias sa_family_t = UInt16

extension in_addr {
    /// Windows reaches the address through a union and a macro (`#define s_addr S_un.S_addr`),
    /// and Swift cannot import a macro. This puts the POSIX name back.
    public var s_addr: in_addr_t {
        get { S_un.S_addr }
        set { S_un.S_addr = newValue }
    }
}

extension sockaddr_in {
    /// BSD's length byte. Windows' `sockaddr_in` has no such field and WinSock wants none: the
    /// address length is passed to every call that needs it. Reading it back gives the size, so
    /// the field is never silently wrong; writing it does nothing, which is correct here.
    public var sin_len: UInt8 {
        get { UInt8(MemoryLayout<sockaddr_in>.size) }
        set { }
    }
}

extension addrinfo {
    /// `IPPROTO_UDP` is a plain `Int32` in Apple's headers and an `IPPROTO` enum in Windows', so
    /// the memberwise initialiser does not take it. This overload does, and otherwise matches it
    /// field for field — Windows happens to declare `addrinfo` in the same order as Darwin.
    public init(ai_flags: Int32, ai_family: Int32, ai_socktype: Int32, ai_protocol: IPPROTO,
                ai_addrlen: Int, ai_canonname: UnsafeMutablePointer<CChar>?,
                ai_addr: UnsafeMutablePointer<sockaddr>?, ai_next: UnsafeMutablePointer<addrinfo>?) {
        self.init(ai_flags: ai_flags, ai_family: ai_family, ai_socktype: ai_socktype,
                  ai_protocol: ai_protocol.rawValue, ai_addrlen: ai_addrlen,
                  ai_canonname: ai_canonname, ai_addr: ai_addr, ai_next: ai_next)
    }
}

/// BSD splits "another socket may bind this address" from "another socket may bind this exact
/// address and port"; Windows gives both under `SO_REUSEADDR`, so asking twice is right and does
/// no harm. The engine sets the pair together wherever it wants a shared port.
public let SO_REUSEPORT: Int32 = SO_REUSEADDR

// MARK: - WinSock under POSIX names

/// `WSAStartup`, once, before the first socket is made. Winsock 2.2.
private let winsockStarted: Bool = {
    var data = WSADATA()
    return WSAStartup(0x0202, &data) == 0
}()

/// WinSock's `SOCKET` is a handle, not a small descriptor. Windows guarantees handle values fit
/// in 32 bits (they are passed to 32-bit processes unchanged), so the engine's `Int32` carries
/// one, and `INVALID_SOCKET` becomes -1 — which is what the engine already tests for.
@inline(__always) private func handle(_ fd: Int32) -> SOCKET {
    fd < 0 ? INVALID_SOCKET : SOCKET(UInt32(bitPattern: fd))
}

@inline(__always) private func descriptor(_ s: SOCKET) -> Int32 {
    s == INVALID_SOCKET ? -1 : Int32(bitPattern: UInt32(truncatingIfNeeded: s))
}

private func winSocket(_ domain: Int32, _ type: Int32, _ proto: IPPROTO) -> Int32 {
    guard winsockStarted else { return -1 }
    return descriptor(WinSDK.socket(domain, type, proto.rawValue))
}

private func winBind(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    WinSDK.bind(handle(fd), addr, length)
}

private func winClose(_ fd: Int32) -> Int32 {
    fd < 0 ? 0 : closesocket(handle(fd))
}

public func socket(_ domain: Int32, _ type: Int32, _ proto: IPPROTO) -> Int32 {
    winSocket(domain, type, proto)
}

public func bind(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    winBind(fd, addr, length)
}

@discardableResult
public func close(_ fd: Int32) -> Int32 { winClose(fd) }

/// The receive files write `Darwin.socket`, `Darwin.bind` and `Darwin.close` where a method of the
/// same name on the enclosing class would otherwise be chosen. Windows has no `Darwin` module, so
/// this stands in its place: the same spelling at the call site, WinSock underneath, and the Mac
/// build — which has the real one — never sees this.
public enum Darwin {
    public static func socket(_ domain: Int32, _ type: Int32, _ proto: IPPROTO) -> Int32 {
        winSocket(domain, type, proto)
    }
    public static func bind(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        winBind(fd, addr, length)
    }
    @discardableResult
    public static func close(_ fd: Int32) -> Int32 { winClose(fd) }
}

@discardableResult
public func setsockopt(_ fd: Int32, _ level: Int32, _ name: Int32,
                       _ value: UnsafeRawPointer?, _ length: socklen_t) -> Int32 {
    WinSDK.setsockopt(handle(fd), level, name,
                      value?.assumingMemoryBound(to: CChar.self), length)
}

@discardableResult
public func getsockname(_ fd: Int32, _ addr: UnsafeMutablePointer<sockaddr>,
                        _ length: UnsafeMutablePointer<socklen_t>) -> Int32 {
    WinSDK.getsockname(handle(fd), addr, length)
}

public func recv(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ length: Int, _ flags: Int32) -> Int {
    Int(WinSDK.recv(handle(fd), buffer.assumingMemoryBound(to: CChar.self), Int32(length), flags))
}

public func recvfrom(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ length: Int, _ flags: Int32,
                     _ from: UnsafeMutablePointer<sockaddr>?,
                     _ fromLength: UnsafeMutablePointer<socklen_t>?) -> Int {
    Int(WinSDK.recvfrom(handle(fd), buffer.assumingMemoryBound(to: CChar.self), Int32(length),
                        flags, from, fromLength))
}

@discardableResult
public func sendto(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ length: Int, _ flags: Int32,
                   _ to: UnsafePointer<sockaddr>?, _ toLength: socklen_t) -> Int {
    Int(WinSDK.sendto(handle(fd), buffer?.assumingMemoryBound(to: CChar.self), Int32(length),
                      flags, to, toLength))
}

/// Windows takes the buffer size as a `size_t` here; Apple takes a `socklen_t`. This overload
/// takes the `socklen_t` the engine passes.
public func inet_ntop(_ family: Int32, _ address: UnsafeRawPointer?,
                      _ buffer: UnsafeMutablePointer<CChar>?,
                      _ size: socklen_t) -> UnsafePointer<CChar>? {
    WinSDK.inet_ntop(family, address, buffer, Int(size))
}

/// `addrinfo.ai_addrlen` is a `size_t` on Windows where Apple makes it a `socklen_t`, so a
/// resolved address's length arrives as an `Int`. This overload takes it as it comes.
@discardableResult
public func sendto(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ length: Int, _ flags: Int32,
                   _ to: UnsafePointer<sockaddr>?, _ toLength: Int) -> Int {
    sendto(fd, buffer, length, flags, to, socklen_t(toLength))
}

// MARK: - Socket errors

/// WinSock reports through `WSAGetLastError()`, not `errno`, and `strerror` has nothing to say
/// about its codes. The engine's socket files branch to these.
public var lastSocketError: Int32 { WSAGetLastError() }

/// Windows' own words for a socket error, trimmed of its trailing newline.
public func socketErrorText(_ code: Int32 = WSAGetLastError()) -> String {
    var buffer: LPWSTR?
    let length = withUnsafeMutablePointer(to: &buffer) {
        $0.withMemoryRebound(to: WCHAR.self, capacity: 1) {
            FormatMessageW(DWORD(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM
                                 | FORMAT_MESSAGE_IGNORE_INSERTS),
                           nil, DWORD(bitPattern: code), 0, $0, 0, nil)
        }
    }
    guard length > 0, let text = buffer else { return "WinSock error \(code)" }
    defer { LocalFree(text) }
    return String(decodingCString: text, as: UTF16.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The errors that mean "the host or the network cannot be reached", for the Sender's auto-stop.
public let unreachableSocketErrors: Set<Int32> = [
    WSAEHOSTDOWN, WSAEHOSTUNREACH, WSAENETUNREACH, WSAENETDOWN, WSAEADDRNOTAVAIL,
]

// MARK: - Network interfaces

/// One IPv4 address on one adapter, as `GetAdaptersAddresses` reports it. Windows has no
/// `getifaddrs`, so this is the engine's stand-in for it; `LocalNetworks` and `Interfaces` both
/// read it in their `#if os(Windows)` branches.
public struct WindowsAdapterAddress {
    /// The adapter's friendly name — "Ethernet", "Wi-Fi" — which is what a Windows user is shown
    /// elsewhere, and so what belongs in a menu here. (The Mac's equivalent is "en0".)
    public let name: String
    public let address: String
    public let netmask: String
    /// Nil on a link without one: loopback and tunnels.
    public let broadcast: String?
    public let isLoopback: Bool
    public let isWiFi: Bool
    public let isTunnel: Bool
}

/// Every usable IPv4 address on every adapter that is up, read fresh on each call: a VPN or a new
/// DHCP lease can change the answer while an app runs. Unassigned (0.0.0.0) and link-local
/// (169.254/16) addresses are dropped, as the Mac drops them.
///
/// One approximation worth knowing about: `IP_ADAPTER_ADDRESSES` carries its "no multicast" flag
/// in a C bitfield, which Swift cannot import, so this makes no claim about multicast and the
/// caller does not ask. Every adapter a user would choose for AES67 carries it.
public func windowsAdapterAddresses() -> [WindowsAdapterAddress] {
    var size = ULONG(15 * 1024)
    let family = ULONG(AF_INET)
    let flags = ULONG(GAA_FLAG_INCLUDE_PREFIX | GAA_FLAG_SKIP_ANYCAST
                      | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER)
    // Twice at most: once to be told the size, once with it. The list can grow between the two.
    for _ in 0..<3 {
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { raw.deallocate() }
        let list = raw.assumingMemoryBound(to: IP_ADAPTER_ADDRESSES.self)
        let status = GetAdaptersAddresses(family, flags, nil, list, &size)
        if status == ULONG(ERROR_BUFFER_OVERFLOW) { continue }
        guard status == ULONG(ERROR_SUCCESS) else { return [] }
        return readAdapters(list)
    }
    return []
}

private func readAdapters(_ first: UnsafeMutablePointer<IP_ADAPTER_ADDRESSES>) -> [WindowsAdapterAddress] {
    var result: [WindowsAdapterAddress] = []
    var adapter: UnsafeMutablePointer<IP_ADAPTER_ADDRESSES>? = first
    while let a = adapter {
        defer { adapter = a.pointee.Next }
        guard a.pointee.OperStatus == IfOperStatusUp else { continue }
        let type = Int32(bitPattern: a.pointee.IfType)
        let isLoopback = type == IF_TYPE_SOFTWARE_LOOPBACK
        let isWiFi = type == IF_TYPE_IEEE80211
        let isTunnel = type == IF_TYPE_TUNNEL || type == IF_TYPE_PPP
        let name = a.pointee.FriendlyName.map { String(decodingCString: $0, as: UTF16.self) } ?? ""
        guard !name.isEmpty else { continue }

        var unicast = a.pointee.FirstUnicastAddress
        while let u = unicast {
            defer { unicast = u.pointee.Next }
            guard let sa = u.pointee.Address.lpSockaddr,
                  sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let value = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let address = ipv4Text(value)
            guard address != "0.0.0.0", !address.hasPrefix("169.254.") else { continue }

            let bits = min(UInt32(u.pointee.OnLinkPrefixLength), 32)
            let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
            // A tunnel and loopback have no broadcast address; everything else does.
            let broadcast = isLoopback || isTunnel ? nil : ipv4Text((value & mask) | ~mask)
            result.append(WindowsAdapterAddress(name: name, address: address,
                                                netmask: ipv4Text(mask), broadcast: broadcast,
                                                isLoopback: isLoopback, isWiFi: isWiFi,
                                                isTunnel: isTunnel))
        }
    }
    return result
}

/// A host-order IPv4 address as dotted-quad text.
private func ipv4Text(_ hostOrder: UInt32) -> String {
    var a = in_addr()
    a.s_addr = hostOrder.bigEndian
    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    guard inet_ntop(AF_INET, &a, &buffer, Int(INET_ADDRSTRLEN)) != nil else { return "" }
    return String(cString: buffer)
}
#endif
