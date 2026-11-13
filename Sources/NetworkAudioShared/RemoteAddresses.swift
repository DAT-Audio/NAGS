import SwiftUI

/// The badge a connection to another location carries on its row: where it is, and whether it
/// is really encrypted (By address never is).
public struct RemoteBadge: View {
    let encrypted: Bool
    public init(encrypted: Bool = false) { self.encrypted = encrypted }
    public var body: some View {
        // Said in words, not only by the padlock — and, where the row is
        // short of room, as the two symbols alone, so the stream's name keeps its space.
        ViewThatFits(in: .horizontal) {
            pill(words: true)
            pill(words: false)
        }
        .help(encrypted ? "In another location, over an encrypted link."
                        : "In another location, over the internet. Not encrypted: someone able to see the traffic between the two places could listen.")
        .accessibilityLabel(encrypted ? "Remote, encrypted" : "Remote, not encrypted")
    }

    private func pill(words: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "globe").font(.system(size: 8, weight: .semibold))
            if words {
                Text("REMOTE").font(.system(size: 8, weight: .bold))
                Text("·").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            Image(systemName: encrypted ? "lock.fill" : "lock.open").font(.system(size: 8, weight: .semibold))
            if words { Text(encrypted ? "ENCRYPTED" : "NOT ENCRYPTED").font(.system(size: 8, weight: .bold)) }
        }
        .foregroundStyle(encrypted ? Color.primary : Color.orange)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .fixedSize()
    }
}

/// Where a VBAN connection is, on its row: **LOCAL**, quietly, on this
/// network; **VPN** over one; **REMOTE · NOT ENCRYPTED**, in orange, in another location — or
/// **REMOTE · ENCRYPTED** over a Remote link, which is sealed.
public struct ConnectionBadge: View {
    let remote: Bool
    let vpn: Bool
    let address: String
    /// The network it is on, when this Mac is on more than one — which one a stream arrives on
    /// was not to be told apart.
    let network: LocalNetwork?
    /// Over an encrypted Remote link: said on the remote badge.
    let encrypted: Bool
    public init(address: String, encrypted: Bool = false) {
        self.address = address
        self.encrypted = encrypted
        remote = RemoteAddresses.isRemote(address)
        vpn = !remote && RemoteAddresses.isVPN(address)
        let networks = LocalNetworks.recent()
        network = networks.count > 1 ? networks.first { $0.contains(address) } : nil
    }
    public var body: some View {
        if remote {
            RemoteBadge(encrypted: encrypted)
        } else if vpn {
            // Not "encrypted": most meshes in this range are (Tailscale is), but the app cannot
            // know which one it is.
            ViewThatFits(in: .horizontal) { quiet("lock.shield", "VPN"); quiet("lock.shield", nil) }
            .help("Over a VPN such as Tailscale: across the internet, and encrypted if the VPN is — Tailscale is. Plays on the remote buffer.")
            .accessibilityLabel("Over a VPN")
        } else {
            ViewThatFits(in: .horizontal) { quiet("house", network?.name ?? "LOCAL"); quiet("house", nil) }
            .help((network.map { "On this network: \($0.name) (\(NetworkIdentity.isWiFi($0.name) ? "Wi-Fi" : "wired")), from \(address). " }
                   ?? "On this network. ")
                  + "VBAN is not encrypted — fine on a network you trust, such as at home, in a studio or an office.")
            .accessibilityLabel(network.map { "Local, on \($0.name), not encrypted" } ?? "Local, not encrypted")
        }
    }
}

extension ConnectionBadge {
    /// A grey pill; the symbol alone where the row is short of room.
    func quiet(_ symbol: String, _ word: String?) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8, weight: .semibold))
            if let word { Text(word).font(.system(size: 8, weight: .bold)) }
        }
        .foregroundStyle(Color.secondary)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .fixedSize()
    }
}

/// The warning box, as the guide and the add fields show it.
public struct RemoteWarning: View {
    /// Whose router forwards a port: this Mac's (true), the other end's (false), or either (nil).
    let receivingEnd: Bool?
    public init(receivingEnd: Bool?) { self.receivingEnd = receivingEnd }
    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("\(Text(RemoteAddresses.warningTitle).bold()) \(RemoteAddresses.warning(receivingEnd: receivingEnd))")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
    }
}
