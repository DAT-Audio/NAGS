import Foundation
import SystemConfiguration

/// Which network an interface is on — not just its addresses, which two places can share
/// (192.168.1.x at home and at a studio) — for "Keep broadcasting when opened again": a
/// broadcast resumes only on the network it was started on.
///
/// macOS's own `NetworkSignatureHash` for the interface's service: a hash of its router's
/// address and hardware address. A hash, so nothing identifying is kept. A network with no
/// router falls back to the interface and its broadcast address.
public enum NetworkIdentity {
    public static func signature(interface: String, broadcast: String?) -> String {
        if let store = SCDynamicStoreCreate(nil, "NetworkAudio" as CFString, nil, nil),
           let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String] {
            for key in keys {
                guard let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                      value["InterfaceName"] as? String == interface else { continue }
                if let hash = value["NetworkSignatureHash"] as? Data {
                    return hash.map { String(format: "%02x", $0) }.joined()
                }
            }
        }
        return "local:\(interface):\(broadcast ?? "")"
    }

    /// Whether an interface is Wi-Fi, where broadcasting slows everyone down.
    public static func isWiFi(_ interface: String) -> Bool {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return false }
        return all.contains {
            SCNetworkInterfaceGetBSDName($0) as String? == interface
                && SCNetworkInterfaceGetInterfaceType($0) == kSCNetworkInterfaceTypeIEEE80211
        }
    }
}
