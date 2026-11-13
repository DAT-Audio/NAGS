import SwiftUI

/// "Where is the other end?", in both apps' connection guides — on this network, or somewhere else.
public struct WhereQuestion: View {
    @Binding var choice: Int
    let tint: Color
    public init(choice: Binding<Int>, tint: Color) { _choice = choice; self.tint = tint }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Where is the other end?").font(.system(size: 12, weight: .semibold))
            HStack(spacing: 10) {
                card(0, symbol: "house", title: "On this network",
                     text: "The same home, studio or office. Most streams here are found by themselves.")
                card(1, symbol: "globe", title: "Somewhere else",
                     text: "Another building — home and work, say — across the internet.")
            }
            Label("Already on a VPN such as Tailscale? Choose **On this network**: the VPN makes the other place part of it.",
                  systemImage: "info.circle")
                .font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card(_ tag: Int, symbol: String, title: String, text: String) -> some View {
        let on = choice == tag
        return Button { choice = tag } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(tint)
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: on ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 11)).foregroundStyle(on ? tint : Color.mutedLabel)
                }
                Text(text).font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(on ? 0.08 : 0.03)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(on ? tint : Color.primary.opacity(0.12), lineWidth: on ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

