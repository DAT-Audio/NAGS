import SwiftUI
import Combine

extension Color {
    // Adaptive: as chosen on dark, darkened on light, where the pastel
    // text in a chip was washing out against the pale window.
    static let sourceRavenna = ThemeColors.adaptive(Color(red: 0.36, green: 0.62, blue: 0.94), key: "source-ravenna")
    static let sourceDante   = ThemeColors.adaptive(Color(red: 0.36, green: 0.78, blue: 0.55), key: "source-dante")
    static let sourceSAP     = ThemeColors.adaptive(Color(red: 0.75, green: 0.60, blue: 0.95), key: "source-sap")
    static let sourceManual  = Color.secondary
    /// Warm, where the AES67 transports are all cool: VBAN is a different family, with no
    /// clock and no announcements, and the chip should say so at a glance.
    static let sourceVBAN    = ThemeColors.adaptive(Color(red: 0.94, green: 0.56, blue: 0.40), key: "source-vban")
    /// Rose: the other clockless LAN family, set apart from VBAN's orange by hue, not only
    /// lightness, for colour-blind readers.
    static let sourceScream  = ThemeColors.adaptive(Color(red: 0.86, green: 0.44, blue: 0.66), key: "source-scream")
    /// Teal-grey: an internet stream is a different thing again — seconds of buffer, not a LAN.
    static let sourceWeb     = ThemeColors.adaptive(Color(red: 0.42, green: 0.70, blue: 0.72), key: "source-web")


    static func tint(for source: DiscoverySource) -> Color {
        switch source {
        case .ravenna: return .sourceRavenna
        case .dante:   return .sourceDante
        case .sap:     return .sourceSAP
        case .manual:  return .sourceManual
        case .vban:    return .sourceVBAN
        case .scream:  return .sourceScream
        case .web:     return .sourceWeb
        }
    }
}

/// How one stream reaches the monitor bus: fold-down, a pair, a single channel, straight
/// through on a wide bus, and the channel order to read it in.
///
/// Shared between the two windows. The compact window's stream rows had mute and solo and
/// nothing else, so the control that decides *what you actually hear* from a multichannel
/// stream — and the order its channels are assumed to be in — was reachable in
/// only one of the two layouts.
struct StreamMixMenu: View {
    @Environment(AppState.self) var state
    let stream: StreamDescription
    var size: CGFloat = 10

    private var layout: SMPTELayout? { SMPTELayout.forChannelCount(stream.channels) }

    private func channelName(_ index: Int) -> String {
        if let layout, index < layout.channelNames.count {
            return "Ch \(index + 1) — \(layout.channelNames[index])"
        }
        return "Ch \(index + 1)"
    }

    var body: some View {
    Menu {
                // Only offered where the bus is wider than a pair, because on a stereo bus it
                // would be `Ch 1/2` wearing a grander name.
                if state.busChannels > 2 {
                    let reaches = min(stream.channels, state.busChannels)
                    Button("\(Downmix.label(for: .passthrough, channels: stream.channels)) "
                         + "— channels 1–\(reaches) straight out") {
                        state.setMixMode(stream.id, .passthrough)
                    }
                    Divider()
                }
                if let layout, layout.foldsDown {
                    Button("Fold \(layout.rawValue) → 2.0 (assumes SMPTE order)") {
                        state.setMixMode(stream.id, .downmix)
                    }
                    Divider()
                }
                ForEach(Array(stride(from: 0, to: stream.channels, by: 2)), id: \.self) { start in
                    Button(Downmix.label(for: .pair(start), channels: stream.channels)) {
                        state.setMixMode(stream.id, .pair(start))
                    }
                }
                // Only where the channels have roles to order: a 1-, 3- or 12-channel stream is
                // discrete audio and an order would mean nothing.
                if ChannelOrder.smpte.roles(channels: stream.channels).count > 2 {
                    Divider()
                    Menu("Channel order") {
                        Button {
                            state.setChannelOrder(stream.id, nil)
                        } label: {
                            if state.hasOwnChannelOrder(stream.id) {
                                Text("Default (\(state.channelOrder.name))")
                            } else {
                                Label("Default (\(state.channelOrder.name))", systemImage: "checkmark")
                            }
                        }
                        Divider()
                        ForEach(ChannelOrder.allCases) { order in
                            Button {
                                state.setChannelOrder(stream.id, order)
                            } label: {
                                if state.hasOwnChannelOrder(stream.id),
                                   state.channelOrder(for: stream.id) == order {
                                    Label(order.menuLabel(channels: stream.channels),
                                          systemImage: "checkmark")
                                } else {
                                    Text(order.menuLabel(channels: stream.channels))
                                }
                            }
                        }
                    }
                }
                if stream.channels > 1 {
                    Divider()
                    Menu("Single channel") {
                        ForEach(0..<stream.channels, id: \.self) { ch in
                            Button(channelName(ch)) { state.setMixMode(stream.id, .mono(ch)) }
                        }
                    }
                }
        } label: {
            Text(Downmix.label(for: state.mixMode(for: stream.id), channels: stream.channels))
                .font(.system(size: size, design: .rounded))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(tooltip("How this stream reaches the monitor bus, and the channel order it is "
                    + "read in. Nothing in the stream declares that order, so it is an "
                    + "assumption you can change.",
                      now: "\(Downmix.label(for: state.mixMode(for: stream.id), channels: stream.channels))"
                         + " · \(state.channelOrder(for: stream.id).name)"))
    }
}

/// Choosing what sits in an insert slot, as a menu, grouped by manufacturer.
///
/// Shared, for the same reason as `InterfacePicker`: the compact window showed the plugin's name
/// as plain text, so a slot could be bypassed and delta'd there but never filled, emptied or
/// swapped.
struct InsertPluginMenu: View {
    @Environment(AppState.self) var state
    let slot: Int
    var size: CGFloat = 10

    var body: some View {
        // Plain values into an Equatable view, so the 440-item menu is not rebuilt on every
        // update of the app's state (see `PluginPicker`).
        PluginPicker(slot: slot, plugins: state.availablePlugins, current: state.slotInfo(slot), size: size,
                     choose: { [weak state] in state?.setPlugin(slot: slot, to: $0) })
            .equatable()
    }
}

/// Opens a plugin's own window. Shared so that both layouts offer it — the compact window did
/// not, which left a plugin loadable there but not editable.
struct InsertEditorButton: View {
    @Environment(AppState.self) var state
    let slot: Int
    var size: CGFloat = 10

    var body: some View {
        Button { state.showPluginUI(slot: slot) } label: {
            Image(systemName: "slider.horizontal.below.rectangle").font(.system(size: size))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.mutedLabel)
        .help(tooltip("Opens this plugin's own window, with its own controls.",
                      now: state.slotInfo(slot).map { "\($0.name) — \($0.manufacturer)" }
                        ?? "Nothing loaded."))
        .disabled(state.slotInfo(slot) == nil)
        .accessibilityLabel("Open the editor for insert \(slot + 1)")
        .accessibilityValue(state.slotInfo(slot)?.name ?? "empty")
    }
}

/// The network interface, as a menu.
///
/// Shared by both windows deliberately. The compact window had the interface as a **label** —
/// the name and a health dot, with no way to change it — which quietly broke the promise
/// `CompactView` makes in its own documentation, that every control there drives what its
/// equivalent in the full window drives. A picker you cannot pick from is worse than an absent
/// one, because it looks like the real thing.
struct InterfacePicker: View {
    @Environment(AppState.self) var state
    /// The full window has room for the address beside the name; 320 points does not.
    var showAddress = true
    var nameSize: CGFloat = 11

    var body: some View {
        Menu {
            ForEach(state.interfaces) { iface in
                Button {
                    state.selectedInterface = iface.name
                } label: {
                    Label(iface.display,
                          systemImage: iface.name == state.selectedInterface ? "checkmark" : "")
                }
            }
            Divider()
            Button("Rescan interfaces") { state.rescanInterfaces() }
            Button("Restart discovery") { state.refreshDiscovery() }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(state.selectedInterface.isEmpty ? Color.orange : Color.green)
                    .frame(width: 6, height: 6)
                Text(state.selectedInterface.isEmpty ? "No interface" : state.selectedInterface)
                    .font(.system(size: nameSize, weight: .medium))
                if showAddress {
                    Text(state.interfaceAddress)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.mutedLabel)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(tooltip("The network interface multicast groups are joined on. Also rescans the "
                    + "interface list and restarts discovery.",
                      now: state.selectedInterface.isEmpty
                        ? "None selected — nothing can arrive."
                        : "\(state.selectedInterface) — \(state.interfaceAddress)"))
    }
}

/// Converts a linear peak to a 0…1 position on a −60 dBFS meter scale.
func meterFraction(_ peak: Float) -> Double {
    guard peak > 0.0002 else { return 0 }
    let db = 20 * log10(Double(peak))
    return min(1, max(0, (db + 60) / 60))
}

/// Position on the −60 dB scale for a given level, used to pin the colour zones.
private func scalePosition(_ db: Double) -> Double { (db + 60) / 60 }

/// Meter colours keyed to **level**, not to bar position: green up to −18 dBFS, amber to
/// −6 dBFS, red above. Spreading a plain green→red ramp over the whole bar instead made a
/// healthy −18 dBFS signal look like it was clipping.
let meterStops = Gradient(stops: [
    .init(color: .green,  location: 0),
    .init(color: .green,  location: scalePosition(-18)),
    .init(color: .yellow, location: scalePosition(-12)),
    .init(color: .orange, location: scalePosition(-6)),
    .init(color: .red,    location: scalePosition(-1)),
    .init(color: .red,    location: 1),
])

/// One thin horizontal level bar with an optional peak-hold tick.
///
/// Drawn with `Canvas` rather than a gradient-filled shape behind a mask: the mask version
/// rebuilt a small view tree every frame and, multiplied across a panel of meters, cost about
/// 11 % CPU on its own. This is one clip and one gradient fill.
struct LevelBar: View {
    let peak: Float
    var hold: Float? = nil

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            let radius = size.height / 2
            let track = Path(roundedRect: CGRect(origin: .zero, size: size),
                             cornerRadius: radius)
            ctx.fill(track, with: .color(.primary.opacity(0.10)))

            let width = size.width * meterFraction(peak)
            if width > 0.5 {
                ctx.drawLayer { layer in
                    layer.clip(to: Path(roundedRect: CGRect(x: 0, y: 0, width: width,
                                                            height: size.height),
                                        cornerRadius: min(radius, width / 2)))
                    layer.fill(Path(CGRect(origin: .zero, size: size)),
                               with: .linearGradient(meterStops,
                                                     startPoint: .zero,
                                                     endPoint: CGPoint(x: size.width, y: 0)))
                }
            }
            if let hold, hold > 0.0002 {
                let x = size.width * meterFraction(hold)
                ctx.fill(Path(CGRect(x: max(0, x - 1), y: 0, width: 2, height: size.height)),
                         with: .color(hold >= 0.999 ? .red : .primary.opacity(0.55)))
            }
        }
    }
}

/// Drives level meters at a chosen frame rate.
///
/// **Always give the result a fixed frame, on the outside.** A `TimelineView` whose size is not
/// pinned asks its parent for a proposal on every tick, and the parent then re-measures every
/// sibling beside it — chips, labels, sliders, the lot. That layout pass, not the drawing, is
/// what a meter costs in SwiftUI: profiling showed `StackLayout.placeChildren` and
/// `LayoutEngineBox.sizeThatFits` at the top of the tree while nothing from the audio path
/// appeared at all.
///
/// Scope this as tightly as possible — wrapping a whole panel re-evaluates its menus, scroll
/// views and sliders on every frame, which cost about 15 % CPU while idle. `.animation` also
/// stops when the content is off-screen, which `.periodic` does not: with `.periodic` the
/// meters kept redrawing behind a locked screen.
///
/// 20 fps is the default and is right for anything numeric or repeated across a panel. The
/// master output bars run at `Self.fluid` instead: they are two small `Canvas` draws, they are
/// the thing being watched, and at 20 fps a fast fall reads as a series of steps.
/// Meter refresh rates.
///
/// `normal` is for the transient SwiftUI timelines that remain — the figures behind a row's
/// disclosure and the latency budget in Settings. Nothing continuously visible uses one.
///
/// The meters themselves follow the user's **Meter refresh** setting (`AppState.meterRate`),
/// which defaults to 30 fps. That setting was added, removed and then added back, and the
/// history is worth keeping: under the old all-SwiftUI meters the rate made no measurable
/// difference, so the control was a placebo and was dropped. Once the meters became
/// AppKit views with their own timers, the rate turned into the single largest cost in
/// the app — 60 fps measured 15.4 % of a core against 4.3 % at 30. The lesson is that
/// "this setting does nothing" was true of one architecture and false of the next.
enum MeterRate {
    static let normal = 20.0
}

/// Re-evaluates its content a few times a second: the figures behind a row's disclosure, and the
/// latency budget in Settings. Nothing continuously visible uses one.
///
/// **A timer of its own, not a `TimelineView`.** Instruments showed that a
/// `TimelineView` of either kind kept SwiftUI updating the window on every display frame —
/// 82–92 updates a second on a 120 Hz screen, about 30 % of a core with one row open in
/// Detailed view — for figures that change four times a second. `.animation` does that by
/// design; `.periodic` measured the same, with a fixed start date as well as with
/// `.now`. Without the timeline the window updated 4 times a second, at 7 %. A counter in this
/// view's own state, bumped by a timer, invalidates this view alone and only when it fires.
///
/// The timer is made once, in `init`, and kept in `@State`: a `Timer.publish` written inline in
/// `body` would be a new timer on every evaluation of the view around it, and with the parent
/// re-evaluated every 0.25 s a 4 Hz one might never fire. It runs only while the view exists,
/// which is only while the row is open or Settings is showing.
struct MeterTimeline<Content: View>: View {
    var paused = false
    @ViewBuilder var content: () -> Content
    @State private var beat = 0
    @State private var ticks: Publishers.Autoconnect<Timer.TimerPublisher>

    init(fps: Double = MeterRate.normal, paused: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.paused = paused
        self.content = content
        _ticks = State(initialValue: Timer.publish(every: 1 / fps, on: .main, in: .common).autoconnect())
    }

    var body: some View {
        let _ = beat   // read, so each beat re-evaluates this view and nothing around it
        content()
            .onReceive(ticks) { _ in if !paused { beat &+= 1 } }
    }
}

/// Several vertical bars in **one** `Canvas`.
///
/// The panel used to build a separate `VerticalMeter` view per channel, so a three-stream,
/// eight-channel panel was twenty-four independent SwiftUI views each redrawing on its own
/// schedule. Collapsing a whole row of channels into one Canvas is what makes a higher frame
/// rate affordable here: the drawing work is unchanged — the same handful of clips and
/// gradient fills — but the per-view update cost is divided by the channel count.
///
/// Bars are `barWidth` wide and centred in a `columnWidth` slot, so a label row using the same
/// column width lines up underneath without either of them measuring the other.
struct MultiMeter: View {
    let count: Int
    let peak: (Int) -> Float
    var hold: Float? = nil
    var dimmed: (Int) -> Bool = { _ in false }
    var barWidth: CGFloat = 8
    var columnWidth: CGFloat = 11
    var height: CGFloat = 46

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            let radius = min(barWidth, size.height) / 2.5
            let full = Path(CGRect(x: 0, y: 0,
                                   width: columnWidth * CGFloat(count), height: size.height))

            // Accumulate the geometry into a handful of paths first, then draw. The number of
            // clips, layers and gradient fills is then *fixed* rather than proportional to the
            // channel count — one `drawLayer` for a 16-channel row instead of sixteen, which is
            // where the cost of this view actually lives.
            let litTracks = CGMutablePath(), dimTracks = CGMutablePath()
            let litFills = CGMutablePath(), dimFills = CGMutablePath()
            let holds = CGMutablePath()
            var haveLit = false, haveDim = false

            for i in 0..<count {
                let x = columnWidth * CGFloat(i) + (columnWidth - barWidth) / 2
                let faded = dimmed(i)
                let column = CGRect(x: x, y: 0, width: barWidth, height: size.height)
                (faded ? dimTracks : litTracks).addPath(
                    CGPath(roundedRect: column, cornerWidth: radius,
                           cornerHeight: radius, transform: nil))

                let filled = size.height * meterFraction(peak(i))
                if filled > 0.5 {
                    let bar = CGPath(roundedRect: CGRect(x: x, y: size.height - filled,
                                                         width: barWidth, height: filled),
                                     cornerWidth: min(radius, filled / 2),
                                     cornerHeight: min(radius, filled / 2), transform: nil)
                    if faded { dimFills.addPath(bar); haveDim = true }
                    else { litFills.addPath(bar); haveLit = true }
                }

                if let hold, hold > 0.0002, !faded {
                    let y = size.height - size.height * meterFraction(hold)
                    holds.addRect(CGRect(x: x, y: max(0, y - 0.75), width: barWidth, height: 1.5))
                }
            }

            ctx.fill(Path(litTracks), with: .color(.primary.opacity(0.10)))
            ctx.fill(Path(dimTracks), with: .color(.primary.opacity(0.05)))

            let ramp = GraphicsContext.Shading.linearGradient(
                meterStops, startPoint: CGPoint(x: 0, y: size.height), endPoint: .zero)
            if haveLit {
                ctx.drawLayer { layer in
                    layer.clip(to: Path(litFills))
                    layer.fill(full, with: ramp)
                }
            }
            if haveDim {
                ctx.drawLayer { layer in
                    layer.opacity = 0.22
                    layer.clip(to: Path(dimFills))
                    layer.fill(full, with: ramp)
                }
            }
            ctx.fill(Path(holds),
                     with: .color((hold ?? 0) >= 0.999 ? .red : .primary.opacity(0.6)))
        }
        .frame(width: columnWidth * CGFloat(count), height: height)
    }
}

/// Every input channel of one stream. Bars shrink to fit and wrap at sixteen, so a 64-channel
/// stream becomes four tidy rows rather than a smear or a horizontal scroller.
struct ChannelMeters: View {
    @Environment(AppState.self) var state
    let stream: StreamDescription
    let labels: [String]
    var barHeight: CGFloat = 46

    private static let perRow = 16

    /// Channels being soloed within this stream. While any are, the rest are drawn grey rather
    /// than hidden — the point of a channel solo is to see what you have taken out as well as
    /// what you have left in.
    private var soloed: Set<Int> { state.soloedChannels(stream.id) }

    /// Whether the whole stream is out of circuit: muted, or silenced by another stream's solo.
    private var silenced: Bool {
        state.isMuted(stream.id) || (state.soloed != nil && state.soloed != stream.id)
    }

    /// One rule across the whole panel: **a coloured bar is reaching the output, a grey one is
    /// not.** Mute, another stream's solo and a channel solo all land here.
    private func lit(_ channel: Int) -> Bool {
        guard !silenced else { return false }
        return soloed.isEmpty || soloed.contains(channel)
    }

    /// A channel whose label should be blocked in the solo colour.
    private func highlighted(_ channel: Int) -> Bool {
        !silenced && soloed.contains(channel)
    }

    private var rows: [[Int]] {
        let all = Array(0..<stream.channels)
        return stride(from: 0, to: all.count, by: Self.perRow).map {
            Array(all[$0..<min($0 + Self.perRow, all.count)])
        }
    }

    /// Labels are dropped once bars get too narrow to sit under them legibly.
    private var showLabels: Bool { stream.channels <= 8 }

    private var barWidth: CGFloat { stream.channels > 8 ? 5 : 8 }

    /// Wide enough for the longest label, so `MultiMeter` and the label row agree without
    /// either measuring the other. Approximated rather than measured on purpose: a text layout
    /// pass per frame is one of the costs being removed here, and 7 pt rounded digits and short
    /// SMPTE names run about 4.4 pt a character.
    private var columnWidth: CGFloat {
        guard showLabels else { return barWidth + 3 }
        let longest = labels.prefix(stream.channels).map(\.count).max() ?? 1
        return max(barWidth, CGFloat(longest) * 4.4) + 3
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 2) {
                    MeterStrip(count: row.count,
                               thickness: barWidth,
                               slot: columnWidth,
                               length: barHeight,
                               fps: state.meterRate,
                               paused: !state.metersActive,
                               level: { state.channelPeak(stream.id, row[$0]) },
                               isDimmed: { !lit(row[$0]) },
                               noData: { [state, id = stream.id] in !(state.health[id]?.receiving ?? false) })
                        .frame(width: columnWidth * CGFloat(row.count), height: barHeight)
                        // Same reason as the master strip: the slot width changes when the mix
                        // mode does — numeric labels are narrower than SMPTE names — and an
                        // `NSViewRepresentable` kept across that does not reliably survive it.
                        .id(geometryKey(row.count))
                    if showLabels { labelRow(row) }
                }
            }
        }
    }

    /// Drawn by AppKit, with the **same slot arithmetic** the bars use.
    ///
    /// This was an `HStack` of fixed-width `Text`s and it did not hold: a label narrower than
    /// its slot lets the row pack by natural width, so the names drift out of step with the
    /// bars above them — worst where the labels are single digits and the slot is wide. The
    /// master meters had the same fault and the same fix; sharing the arithmetic is the
    /// only way the two rows stay in step.
    ///
    /// No timer either way: the labels do not change while audio is playing, so redrawing them
    /// at the meter rate was always pure waste.
    private func labelRow(_ row: [Int]) -> some View {
        MeterLabels(labels: row.map { $0 < labels.count ? labels[$0] : "\($0 + 1)" },
                    slot: columnWidth,
                    size: 7,
                    isDimmed: { !lit(row[$0]) },
                    isHighlighted: { highlighted(row[$0]) },
                    highlight: NSColor(state.tintSolo),
                    highlightForeground: NSColor(state.tintSolo.readableForeground))
            .frame(width: columnWidth * CGFloat(row.count), height: 10)
            .id(geometryKey(row.count))
    }

    /// Identity for the AppKit meter views: anything that changes their geometry.
    private func geometryKey(_ count: Int) -> String {
        "\(count)-\(Int(columnWidth * 10))-\(Int(barWidth))"
    }
}
