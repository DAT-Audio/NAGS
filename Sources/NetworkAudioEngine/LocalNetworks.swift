import Foundation
#if canImport(WinSDK)
import WinSDK          // the Windows port: WinSock, and WindowsCompat.swift beside it
#endif

/// One IPv4 network this Mac is on, as the interface reports it.
public struct LocalNetwork: Hashable {
    public let name: String
    public let address: String
    public let netmask: String
    /// Nil on links without one — tunnels and loopback.
    public let broadcast: String?

    public init(name: String, address: String, netmask: String, broadcast: String?) {
        self.name = name; self.address = address; self.netmask = netmask; self.broadcast = broadcast
    }

    /// Whether `ip` is on this network, by address and netmask.
    public func contains(_ ip: String) -> Bool {
        let mask = ipv4Value(netmask)
        guard let a = ipv4Value(address), let b = ipv4Value(ip), let m = mask else { return false }
        return a & m == b & m
    }
}

/// The IPv4 networks this Mac is on, read fresh from the interfaces on each call: a VPN or a new
/// DHCP lease can change the answer while an app runs. Up and running interfaces only, without
/// loopback, link-local, AirDrop or Apple's internal ones.
public enum LocalNetworks {
    public static func list() -> [LocalNetwork] {
        #if os(Windows)
        // `GetAdaptersAddresses` in place of `getifaddrs`, and it reports only adapters that are
        // up, so the flag tests below have already been made (`WindowsCompat.swift`). Loopback is
        // dropped here as it is on the Mac: nothing on it is a network anyone else can reach.
        return windowsAdapterAddresses().filter { !$0.isLoopback }.map {
            LocalNetwork(name: $0.name, address: $0.address, netmask: $0.netmask,
                         broadcast: $0.broadcast)
        }
        #else
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [LocalNetwork] = []
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  let address = numeric(sa) else { continue }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  address != "0.0.0.0", !address.hasPrefix("169.254.") else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            if name.hasPrefix("anpi") || name.hasPrefix("awdl") || name.hasPrefix("llw") { continue }
            let netmask = ifa.pointee.ifa_netmask.flatMap(numeric) ?? "255.255.255.255"
            // `ifa_dstaddr` is the broadcast address on a broadcast-capable link (C's
            // `ifa_broadaddr`) and the far end of the tunnel on a point-to-point one.
            let broadcast = flags & IFF_BROADCAST != 0 ? ifa.pointee.ifa_dstaddr.flatMap(numeric) : nil
            result.append(LocalNetwork(name: name, address: address, netmask: netmask,
                                       broadcast: broadcast))
        }
        return result
        #endif
    }

    /// `list()`, read at most every few seconds: for views drawn often, such as each row's badge.
    public static func recent() -> [LocalNetwork] {
        cacheLock.lock(); defer { cacheLock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        if now - cachedAt > 3 { cached = list(); cachedAt = now }
        return cached
    }
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cached: [LocalNetwork] = []
    nonisolated(unsafe) private static var cachedAt: CFAbsoluteTime = 0

    /// The broadcast address of the local network `ip` is on, if this Mac is on that network
    /// and it has one. How a sender reaches every receiver on a receiver's network at once.
    public static func broadcast(for ip: String) -> String? {
        list().first { $0.contains(ip) }?.broadcast
    }

    #if !os(Windows)
    private static func numeric(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
        guard sa.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                          nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: host)
    }
    #endif
}

/// A dotted-quad address as a host-order number, or nil if it is not one.
public func ipv4Value(_ text: String) -> UInt32? {
    var a = in_addr()
    guard inet_pton(AF_INET, text, &a) == 1 else { return nil }
    return UInt32(bigEndian: a.s_addr)
}
