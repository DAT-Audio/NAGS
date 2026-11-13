import Foundation
#if canImport(WinSDK)
import WinSDK          // the Windows port: WinSock, and WindowsCompat.swift beside it
#endif

/// A usable IPv4 network interface on this Mac.
public struct NetInterface: Identifiable, Hashable {
    /// What sort of link this is. Worth knowing rather than guessing: AES67 is multicast, and
    /// what an access point does with multicast is very different from what a switch does.
    /// `vpn` is only ever reported by `receiveAddresses`: AES67 cannot cross a tunnel, VBAN can.
    public enum Kind: Hashable { case wired, wifi, loopback, vpn }

    public let name: String        // "en5"
    public let address: String     // "192.0.2.20"
    public let kind: Kind
    /// The subnet's broadcast address, where the link has one ("192.0.2.255"). Only
    /// `receiveAddresses` fills it in: it is what a VBAN sender can target to reach every
    /// receiver on that network at once.
    public var broadcast: String? = nil

    public init(name: String, address: String, kind: Kind, broadcast: String? = nil) {
        self.name = name; self.address = address; self.kind = kind; self.broadcast = broadcast
    }

    public var id: String { name }

    public var display: String {
        switch kind {
        case .wired:    return "\(name) — \(address)"
        case .wifi:     return "\(name) — \(address)   Wi-Fi"
        case .loopback: return "\(name) — \(address)   loopback"
        case .vpn:      return "\(name) — \(address)   VPN"
        }
    }

    /// What the link is, in the words a user would use to pick an address.
    public var kindLabel: String {
        switch kind {
        case .wired:    return "Wired"
        case .wifi:     return "Wi-Fi"
        case .loopback: return "This Mac only"
        case .vpn:      return "VPN"
        }
    }
}

public enum Interfaces {
    /// Interfaces that are up, running, multicast-capable and carry an IPv4 address.
    /// Loopback, AWDL, point-to-point tunnels and Apple-internal NICs are filtered out
    /// because AES67 never arrives on them.
    /// Set `AES67_SHOW_LOOPBACK=1` to also list lo0, which makes it possible to test the
    /// app against `Tools/test_sender.py` with no audio network attached.
    public static var includeLoopback: Bool { ProcessInfo.processInfo.environment["AES67_SHOW_LOOPBACK"] == "1" }

    public static func listIPv4() -> [NetInterface] {
        #if os(Windows)
        // `GetAdaptersAddresses` in place of `getifaddrs` (`WindowsCompat.swift`): it reports only
        // adapters that are up, and gives the link type outright, so the flag tests and the name
        // prefixes the Mac branch needs have no Windows equivalent to make. Tunnels are left out
        // here as the Mac leaves out point-to-point links: AES67 never arrives on one.
        let adapters = windowsAdapterAddresses()
        wifiNames = Set(adapters.filter(\.isWiFi).map(\.name))
        var result: [NetInterface] = []
        var seen = Set<String>()
        for a in adapters {
            guard !a.isLoopback || includeLoopback, !a.isTunnel, !seen.contains(a.name) else { continue }
            seen.insert(a.name)
            let kind: NetInterface.Kind = a.isLoopback ? .loopback : a.isWiFi ? .wifi : .wired
            result.append(NetInterface(name: a.name, address: a.address, kind: kind))
        }
        #else
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [NetInterface] = []
        var seen = Set<String>()

        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_MULTICAST != 0 else { continue }
            let loopback = flags & IFF_LOOPBACK != 0
            guard !loopback || includeLoopback, flags & IFF_POINTOPOINT == 0 else { continue }

            let name = String(cString: ifa.pointee.ifa_name)
            // anpi* = Apple internal NICs, awdl/llw = AirDrop link, utun = VPN tunnels.
            if name.hasPrefix("anpi") || name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("utun") {
                continue
            }
            guard !seen.contains(name) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let addr = String(cString: host)
            guard addr != "0.0.0.0", !addr.hasPrefix("169.254.") else { continue }
            seen.insert(name)
            let kind: NetInterface.Kind = loopback ? .loopback
                                        : isWiFi(name) ? .wifi : .wired
            result.append(NetInterface(name: name, address: addr, kind: kind))
        }
        #endif
        // Wired NICs usually carry the AES67 network, so surface them ahead of Wi-Fi, and
        // loopback last — it is only there for the test sender.
        func rank(_ i: NetInterface) -> Int {
            switch i.kind {
            case .wired: return 0
            case .wifi: return 1
            case .loopback: return 2
            case .vpn: return 3
            }
        }
        return result.sorted { (rank($0), $0.name) < (rank($1), $1.name) }
    }

    /// Every address a unicast sender could reach this Mac on — what a VBAN sender is pointed
    /// at. Unlike `listIPv4`, this keeps VPN tunnels (`utun`, `ipsec`, `ppp`) and does not ask
    /// for multicast, because the VBAN listener binds every interface and a tunnel is exactly
    /// how a sender on another network reaches it. Read fresh on every call: a VPN or a new
    /// DHCP lease can change the answer while the app runs.
    public static func receiveAddresses() -> [NetInterface] {
        #if os(Windows)
        // As `listIPv4`, but tunnels are kept and reported as VPNs: a VBAN sender on another
        // network reaches this PC through one.
        let adapters = windowsAdapterAddresses()
        wifiNames = Set(adapters.filter(\.isWiFi).map(\.name))
        var result: [NetInterface] = []
        for a in adapters {
            guard !a.isLoopback || includeLoopback else { continue }
            let kind: NetInterface.Kind = a.isLoopback ? .loopback
                                        : a.isTunnel ? .vpn
                                        : a.isWiFi ? .wifi : .wired
            result.append(NetInterface(name: a.name, address: a.address, kind: kind,
                                       broadcast: a.broadcast))
        }
        #else
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [NetInterface] = []
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0 else { continue }
            let loopback = flags & IFF_LOOPBACK != 0
            guard !loopback || includeLoopback else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            if name.hasPrefix("anpi") || name.hasPrefix("awdl") || name.hasPrefix("llw") { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let addr = String(cString: host)
            guard addr != "0.0.0.0", !addr.hasPrefix("169.254.") else { continue }
            let tunnel = flags & IFF_POINTOPOINT != 0 || name.hasPrefix("utun")
                || name.hasPrefix("ipsec") || name.hasPrefix("ppp")
            let kind: NetInterface.Kind = loopback ? .loopback
                                        : tunnel ? .vpn
                                        : isWiFi(name) ? .wifi : .wired
            // `ifa_dstaddr` is the broadcast address on a broadcast-capable link (C's
            // `ifa_broadaddr`), and the far end of the tunnel on a point-to-point one.
            var broadcast: String?
            if flags & IFF_BROADCAST != 0, let b = ifa.pointee.ifa_dstaddr,
               b.pointee.sa_family == sa_family_t(AF_INET) {
                var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(b, socklen_t(b.pointee.sa_len), &text, socklen_t(text.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    broadcast = String(cString: text)
                }
            }
            result.append(NetInterface(name: name, address: addr, kind: kind, broadcast: broadcast))
        }
        #endif
        func rank(_ i: NetInterface) -> Int {
            switch i.kind {
            case .wired: return 0
            case .wifi: return 1
            case .vpn: return 2
            case .loopback: return 3
            }
        }
        return result.sorted { (rank($0), $0.name, $0.address) < (rank($1), $1.name, $1.address) }
    }

    /// Whether this is a Wi-Fi interface, asked of CoreWLAN rather than inferred from the name.
    ///
    /// The previous test was `!name.hasPrefix("ap")`, which is wrong twice: `ap1` is the
    /// *hotspot* interface, and the Wi-Fi client on a Mac is `en0`. So Wi-Fi was classified as
    /// wired and — being alphabetically first among the `en*` names — sorted to the top of the
    /// menu and became the default selection, which is the opposite of what the sort was for
    /// `interfaceNames()` reports the hardware whether or not Wi-Fi is switched on or
    /// associated, so it is a safe classifier for a menu label.
    public static func isWiFi(_ name: String) -> Bool { wifiNames.contains(name) }

    /// The Wi-Fi interfaces' names, given by the platform at launch (the Mac asks CoreWLAN;
    /// the engine has none of its own). Names don't change while the app runs.
    public nonisolated(unsafe) static var wifiNames: Set<String> = []

    public static func defaultInterface() -> NetInterface? { listIPv4().first }
}


