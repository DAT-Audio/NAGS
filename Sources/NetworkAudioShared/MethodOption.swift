import SwiftUI

/// One way to connect, as a radio header, so a casual user is not shown too much at once. A title, a tag, one plain sentence saying what it is and who it is for; only
/// the chosen one opens to its details.
public struct MethodOption<Details: View>: View {
    let title: String
    let tag: String?
    let summary: String
    let chosen: Bool
    let tint: Color
    let choose: () -> Void
    let details: Details

    public init(_ title: String, tag: String? = nil, summary: String, chosen: Bool, tint: Color,
                choose: @escaping () -> Void, @ViewBuilder details: () -> Details) {
        self.title = title; self.tag = tag; self.summary = summary; self.chosen = chosen
        self.tint = tint; self.choose = choose; self.details = details()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: choose) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 13)).foregroundStyle(chosen ? tint : Color.mutedLabel)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(title).font(.system(size: 12, weight: .semibold))
                            if let tag {
                                Chip(text: tag, tint: tag == "RECOMMENDED" ? tint : .secondary,
                                     filled: tag == "RECOMMENDED")
                            }
                        }
                        Text(summary).font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(chosen ? .isSelected : [])
            if chosen {
                Divider().opacity(0.5)
                details
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(chosen ? 0.05 : 0.02)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(chosen ? tint.opacity(0.8) : Color.primary.opacity(0.12), lineWidth: chosen ? 1.5 : 1))
    }
}

/// The three ways to reach somewhere else, with the words both apps use.
public enum RemoteMethod: Int, CaseIterable {
    case remoteLink, vpn, byAddress
    public var title: String {
        switch self {
        case .remoteLink: "Remote link"
        case .vpn: "VPN"
        case .byAddress: "By address"
        }
    }
    public var tag: String? {
        switch self {
        case .remoteLink: "RECOMMENDED"
        case .vpn: nil
        case .byAddress: nil
        }
    }
    public var summary: String {
        switch self {
        case .remoteLink: "Swap a code with the other end. Encrypted, and nothing to set up on a router."
        case .vpn: "Already use Tailscale or similar? The other place is then part of your network."
        case .byAddress: "For other VBAN senders and receivers, such as Voicemeeter. Needs a port opened on a router."
        }
    }
}
