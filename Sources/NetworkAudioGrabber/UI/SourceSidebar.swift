import SwiftUI

/// Which kinds of stream the list shows, down the left of the full window. With many sources on
/// a network, "all of them" is where people get lost. All is
/// the default; the choice is remembered. A kind appears once any stream of it has been found,
/// or while it is the one chosen, so the sidebar grows with the network rather than listing
/// protocols nobody uses.
struct SourceSidebar: View {
    @Environment(\.skin) private var skin
    @Environment(AppState.self) var state

    /// 164, to fit "Dante (AES67)" (was 150).
    static let width: CGFloat = 164

    /// Every kind, in the order a monitoring engineer reaches for them.
    private static let order: [DiscoverySource] = [.ravenna, .dante, .sap, .vban, .scream, .web, .manual]

    var body: some View {
        let counts = state.sourceCounts
        let total = counts.values.reduce(0, +)
        VStack(alignment: .leading, spacing: 2) {
            Text("Sources")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.mutedLabel)
                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
            row(nil, "All streams", symbol: "square.stack.3d.up", count: total)
            ForEach(Self.order.filter { (counts[$0] ?? 0) > 0 || state.sourceFilter == $0 }, id: \.self) { kind in
                row(kind, Self.name(kind), symbol: nil, count: counts[kind] ?? 0)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(width: Self.width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(skin.style.panel.map { Color(nsColor: $0) } ?? Color.primary.opacity(0.03))
    }

    static func name(_ kind: DiscoverySource) -> String {
        switch kind {
        case .ravenna: return "RAVENNA"
        case .dante:   return "Dante (AES67)"
        case .sap:     return "AES67 (SAP)"
        case .vban:    return "VBAN"
        case .scream:  return "Scream"
        case .web:     return "Internet radio"
        case .manual:  return "Manual"
        }
    }

    private func row(_ kind: DiscoverySource?, _ title: String, symbol: String?, count: Int) -> some View {
        let selected = state.sourceFilter == kind
        return Button { state.sourceFilter = kind } label: {
            HStack(spacing: 7) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10)).frame(width: 10)
                        .foregroundStyle(Color.mutedLabel)
                } else if let kind {
                    Circle().fill(Color.tint(for: kind)).frame(width: 7, height: 7).frame(width: 10)
                }
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(verbatim: "\(count)").font(.system(size: 10)).monospacedDigit()
                    .foregroundStyle(Color.mutedLabel)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(selected ? Color.primary.opacity(0.09) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(kind == nil ? "Every stream found, of every kind." : "Only \(title) streams.")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Where the full window's stream filter sits: the sidebar, or a row above the list
/// — narrower, for a small window or a plugin's. The Audio Unit always uses the row.
enum SourceFilterPlacement: String, CaseIterable, Identifiable {
    case sidebar, row
    var id: String { rawValue }
    var label: String { self == .sidebar ? "Sidebar" : "Row above the list" }
}

/// The stream filter as a row: All and each kind found, with ‹ › to step along when the row is
/// wider than its room. Stepping rather than scrolling: the row
/// shows the kinds from `first` on, and the arrows appear only where there is more that way.
/// Widths are measured when the kinds or the room change, never on the app's tick.
struct SourceFilterRow: View {
    @Environment(AppState.self) var state
    @Environment(\.skin) private var skin
    /// The compact window's: smaller type, no counts.
    var compact = false

    @State private var first = 0
    @State private var room: CGFloat = 0
    @State private var widths: [String: CGFloat] = [:]

    private static let order: [DiscoverySource] = [.ravenna, .dante, .sap, .vban, .scream, .web, .manual]
    private static let spacing: CGFloat = 4

    private struct Item: Identifiable { let id: String; let kind: DiscoverySource?; let title: String; let count: Int }

    private var items: [Item] {
        let counts = state.sourceCounts
        let kinds = Self.order.filter { (counts[$0] ?? 0) > 0 || state.sourceFilter == $0 }
        return [Item(id: "all", kind: nil, title: compact ? "All" : "All streams",
                     count: counts.values.reduce(0, +))]
            + kinds.map { Item(id: $0.rawValue, kind: $0, title: compact ? $0.label : SourceSidebar.name($0),
                               count: counts[$0] ?? 0) }
    }

    var body: some View {
        let all = items
        let start = min(first, max(0, all.count - 1))
        let shown = Array(all[start...])
        let used = shown.reduce(CGFloat(0)) { $0 + (widths[$1.id] ?? 60) + Self.spacing }
        let canLeft = start > 0
        let canRight = used - Self.spacing > room + 1
        HStack(spacing: 4) {
            if canLeft { arrow("chevron.left") { first = max(0, start - 1) } }
            HStack(spacing: Self.spacing) {
                ForEach(shown) { item in
                    chip(item)
                        .fixedSize()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths[item.id] = $0 }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { room = $0 }
            if canRight { arrow("chevron.right") { first = min(all.count - 1, start + 1) } }
        }
        .frame(height: compact ? 20 : 24)
    }

    private func arrow(_ symbol: String, _ step: @escaping () -> Void) -> some View {
        Button(action: step) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                .frame(width: 14, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Color.mutedLabel)
        .help(symbol == "chevron.left" ? "Earlier kinds of stream" : "More kinds of stream")
    }

    private func chip(_ item: Item) -> some View {
        let on = state.sourceFilter == item.kind
        let tint = item.kind.map { Color.tint(for: $0) } ?? Color.secondary
        return Button { state.sourceFilter = on && item.kind != nil ? nil : item.kind } label: {
            HStack(spacing: 4) {
                if let kind = item.kind, !compact {
                    Circle().fill(Color.tint(for: kind)).frame(width: 6, height: 6)
                }
                Text(verbatim: item.title)
                    .font(.system(size: compact ? 9 : 11, weight: on ? .semibold : .regular,
                                  design: compact ? .rounded : .default))
                if !compact {
                    Text(verbatim: "\(item.count)").font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(Color.mutedLabel)
                }
            }
            .padding(.horizontal, compact ? 5 : 8).padding(.vertical, compact ? 2 : 3)
            .foregroundStyle(on ? (compact ? tint : Color.primary) : (compact ? Color.mutedLabel : Color.primary))
            .background(RoundedRectangle(cornerRadius: skin.chipRadius ?? (compact ? 20 : 5))
                .fill(on ? (compact ? tint.opacity(0.24) : Color.primary.opacity(0.10)) : Color.primary.opacity(0.05)))
        }
        .buttonStyle(.plain)
        .help(item.kind.map { "Only \(SourceSidebar.name($0)) streams." } ?? "Every stream found, of every kind.")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
