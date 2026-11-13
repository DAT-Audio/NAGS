import SwiftUI

/// An insert slot's plugin menu, grouped by manufacturer — shared by both apps' inserts.
///
/// **Rebuilt only when the list or the choice changes.** A SwiftUI `Menu` builds every
/// item each time the view around it is evaluated, and with 440 plugins installed that is three
/// 440-item menus rebuilt whenever the window updates — several times a second while a stream
/// plays. It cost the Grabber's window about 20 % CPU (27 % with the inserts open against 7 %
/// with them closed), enough to starve the audio of the main thread's time and push
/// jitter and underruns up. So this view takes plain values, not the app's state, and is
/// `Equatable`: `.equatable()` lets SwiftUI skip it entirely while its inputs stay the same.
public struct PluginPicker: View, Equatable {
    let slot: Int
    let plugins: [PluginInfo]
    let current: PluginInfo?
    let size: CGFloat
    let choose: (PluginInfo?) -> Void
    /// The search popover: opened only from this menu's "Search…".
    @State private var searching = false

    public init(slot: Int, plugins: [PluginInfo], current: PluginInfo?, size: CGFloat = 10,
                choose: @escaping (PluginInfo?) -> Void) {
        self.slot = slot; self.plugins = plugins; self.current = current; self.size = size
        self.choose = choose
    }

    /// The closure is left out: it is rebuilt with every parent evaluation and does the same thing.
    public static func == (a: PluginPicker, b: PluginPicker) -> Bool {
        a.slot == b.slot && a.current == b.current && a.size == b.size && a.plugins == b.plugins
    }

    public var body: some View {
        // Grouped here, which now runs only when the list or the choice changes.
        var order: [String] = []
        var byMaker: [String: [PluginInfo]] = [:]
        for p in plugins {
            if byMaker[p.manufacturer] == nil { order.append(p.manufacturer) }
            byMaker[p.manufacturer, default: []].append(p)
        }
        return Menu {
            // Search on top of the maker lists rather than instead of them: the lists are how
            // most people find a plugin, and a search is for when the name is known.
            Button { searching = true } label: { Label("Search…", systemImage: "magnifyingglass") }
            Divider()
            Button("— Empty —") { choose(nil) }
            Divider()
            ForEach(order, id: \.self) { maker in
                Menu(maker) {
                    ForEach(byMaker[maker] ?? []) { plugin in
                        Button(plugin.name) { choose(plugin) }
                    }
                }
            }
        } label: {
            HStack(spacing: 0) {
                Text(verbatim: "\(slot + 1)   \(current?.name ?? "Empty")")
                    .font(.system(size: size))
                    .foregroundStyle(current == nil ? Color.secondary : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .menuStyle(.borderlessButton)
        .popover(isPresented: $searching, arrowEdge: .bottom) {
            PluginSearch(plugins: plugins, current: current) { picked in
                searching = false
                choose(picked)
            }
        }
    }
}

/// The plugin list with a search field, grouped by maker as the menu is.
private struct PluginSearch: View {
    let plugins: [PluginInfo]
    let current: PluginInfo?
    let choose: (PluginInfo) -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    private var groups: [(maker: String, items: [PluginInfo])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var order: [String] = []
        var byMaker: [String: [PluginInfo]] = [:]
        for p in plugins where q.isEmpty || p.name.lowercased().contains(q) || p.manufacturer.lowercased().contains(q) {
            if byMaker[p.manufacturer] == nil { order.append(p.manufacturer) }
            byMaker[p.manufacturer, default: []].append(p)
        }
        return order.map { ($0, byMaker[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search plugins", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .plainEntry()
                .onSubmit { if let first = groups.first?.items.first { choose(first) } }
            let found = groups
            if found.isEmpty {
                Text("No plugin matches “\(query)”.").font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(found, id: \.maker) { group in
                            Text(group.maker).font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.mutedLabel)
                                .padding(.top, 5)
                            ForEach(group.items) { plugin in
                                Button { choose(plugin) } label: {
                                    HStack {
                                        Text(plugin.name).font(.system(size: 12))
                                        Spacer()
                                        if plugin.id == current?.id {
                                            Image(systemName: "checkmark").font(.system(size: 10))
                                        }
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(height: 300)
            }
            Text("Return loads the first match.").font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
        }
        .padding(10)
        .frame(width: 280)
        .onAppear { focused = true }
    }
}
