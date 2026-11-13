import SwiftUI

/// One stream in the list: **a single line**, with the detail of the one stream you have open
/// dropping in underneath it.
///
/// It used to be three bands deep — a headline, an always-visible controls line, and a
/// disclosure — which cost about 74 points per joined stream and showed six of twelve streams
/// in a full-height window. One line is 30, and the controls did not have to go anywhere to
/// get there: the space came from the address and format line, which repeated the same string
/// under every name and is now shown once, for the stream being looked at.
///
/// **Trim stays on the row.** It is the one control people reach for while comparing two
/// streams, and putting it behind the disclosure would turn a two-second balance into
/// click-drag-click-drag.
struct StreamRowView: View {
    @Environment(AppState.self) var state
    @Environment(\.colorScheme) private var scheme
    @Environment(\.skin) private var skin
    let stream: StreamDescription
    // Open rows are on the state (`openStreamIDs`): several at once, so two
    // streams can be compared side by side. Each opens and closes by itself.

    private var active: Bool { state.isSubscribed(stream.id) }

    /// "12 s ago", "4 min ago", or a dash for never. Redrawn by the figures' own timeline.
    static func ago(_ date: Date?) -> String {
        guard let date else { return "—" }
        let s = max(0, Int(Date().timeIntervalSince(date)))
        if s < 60 { return "\(s) s ago" }
        if s < 3600 { return "\(s / 60) min ago" }
        return "\(s / 3600) h ago"
    }
    private var open: Bool { state.isOpen(stream.id) }
    private var favourite: Bool { state.favourites.contains(stream.id) }
    private var layout: SMPTELayout? { SMPTELayout.forChannelCount(stream.channels) }

    /// Out of circuit: muted, or silenced by another stream's solo. The level bar goes grey,
    /// matching the panel.
    private var silenced: Bool {
        state.isMuted(stream.id) || (state.soloed != nil && state.soloed != stream.id)
    }

    /// Column widths, in one place. A list only reads as columns if every row agrees about
    /// them — sized by natural width they line up only by luck.
    enum Column {
        static let star: CGFloat = 12
        static let play: CGFloat = 20
        static let mix: CGFloat = 68
        static let meter: CGFloat = 54
        static let trim: CGFloat = 78
        static let gain: CGFloat = 36
        /// Two PillToggles side by side (about 24 pt each, 3 apart). At 42 the S was clipped by
        /// the fixed-width controls block.
        static let states: CGFloat = 52
        /// Wide enough for "DANTE (AES67)" and the channel count (it was 92).
        static let chips: CGFloat = 112
        /// The playing row's controls — bus, level, trim, its figure, M/S — as one block.
        static let controls: CGFloat = mix + meter + trim + gain + states + 4 * 7
        static let jitter: CGFloat = 50
        /// "OK", "No packets", "Asking…": a word and a shape, never colour alone.
        static let status: CGFloat = 92
        static let rowHeight: CGFloat = 30
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headline
                .padding(.horizontal, 12)
                .frame(height: Column.rowHeight)
            if active && open { StreamDetailBlock(stream: stream) }
            if !active, let reason = state.joinFailures[stream.id] {
                // The fault on the row it belongs to, with the one thing to do.
                HStack(spacing: 8) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(Color.red).font(.system(size: 11))
                    Text(reason).font(.system(size: 11)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Button("Try again") { state.toggle(stream) }.controlSize(.small)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.red.opacity(0.35), lineWidth: 1))
                .padding(.leading, 12 + Column.star + 7 + Column.play + 7).padding(.trailing, 12)
                .padding(.bottom, 8)
            }
        }
        // **Flat rows.** Playing streams used to be
        // cards washed and outlined in the active colour, the open one more strongly, with an
        // edge down its side; that made the list harder to read, not easier. The colour now
        // marks only what is active *on* the row — stop, the bus menu, the trim — and the open
        // row, row and detail as one object, sits on a faint neutral ground.
        .background(open ? Color.primary.opacity(0.06) : Color.clear)
        .contextMenu {
            Button(favourite ? "Remove from favourites" : "Add to favourites") {
                state.toggleFavourite(stream.id)
            }
            StreamCopyItems(stream: stream)
            Divider()
            Button("Ignore this stream") { state.ignore(stream.id) }
            // Added by hand — an internet stream or pasted SDP — so taken off by hand too.
            if stream.source == .web || stream.source == .manual {
                Divider()
                Button("Remove from the list") {
                    if stream.source == .web { state.removeWebStream(stream.id) }
                    else { state.removeManualStream(stream.id) }
                }
            }
        }
    }

    private func toggleOpen() {
        guard active else { return }
        state.toggleOpen(stream.id)
    }

    // MARK: - The line

    private var headline: some View {
        HStack(spacing: 7) {
            Button { state.toggleFavourite(stream.id) } label: {
                Image(systemName: favourite ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .frame(width: Column.star)
                    .foregroundStyle(favourite ? Color.yellow : Color.secondary.opacity(0.45))
            }
            .buttonStyle(.plain)
            .help("Favourite")
            .accessibilityLabel("Favourite \(stream.name)")
            .accessibilityValue(favourite ? "on" : "off")

            Button {
                state.toggle(stream)
                // Joining opens the row only when no other is open: with several open at once,
                // opening every stream you press play on would make the tall list back. Stopping
                // closes it — a stopped stream has no detail to show.
                if state.isSubscribed(stream.id) {
                    if state.openStreamIDs.isEmpty { state.openStreamIDs.insert(stream.id) }
                } else { state.openStreamIDs.remove(stream.id) }
            } label: {
                PlayStopIcon(active: active, tint: state.tintActive(on: scheme), size: 18)
                    .frame(width: Column.play)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(active ? "Stop listening to \(stream.name)"
                                       : "Listen to \(stream.name)")
            .help(active ? "Stop listening" : "Listen")

            HStack(spacing: 6) {
            Text(stream.name)
                .font(.system(size: 13, weight: active ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                // The name before the badges: they shrink to symbols first.
                .layoutPriority(1)
            // Said on the row once the signal panel's Inputs section, which said it, is gone.
            if active, state.hasChannelSolo(stream.id) {
                ChannelSoloBadge(stream: stream)
            }
            // From another location, over the internet: said, and not encrypted.
            // Where it comes from: VBAN says local or remote; anything else only when remote.
            if stream.source == .vban { ConnectionBadge(address: stream.originAddress, encrypted: state.isEncryptedLink(stream)) }
            else if stream.source != .web, RemoteAddresses.isRemote(stream.originAddress) { RemoteBadge() }
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(state.nowPlaying[stream.id].map { "Now playing: \($0)" }
                      ?? ([.vban, .scream].contains(stream.source) ? "\(stream.name), from \(stream.originAddress)" : stream.name))
                .contentShape(Rectangle())
                .onTapGesture { toggleOpen() }

            // One fixed-width block, playing or not, so the Source column lines up on every row:
            // an idle row's placeholder and a playing row's controls had the same sum on paper,
            // but a control a little wider than its slot pushed the chips right on playing rows
            // only.
            HStack(spacing: 7) {
            if active {
                // Every channel, one hairline each, so a silent channel on a stream that is not
                // open is still seen — the job the panel's Inputs section did.
                // **Before the fold-down**, as the signal runs: what arrives, then what it is
                // folded to (the other way round would read as the fold's output).
                RowChannelMeters(stream: stream, silenced: silenced)
                    .frame(width: Column.meter)
                StreamMixMenu(stream: stream)
                    .frame(width: Column.mix, alignment: .leading)
                ResettableSlider(value: Binding(get: { Double(state.gain(for: stream.id)) },
                                                set: { state.setGain(stream.id, Float($0)) }),
                                 range: 0...1.5,
                                 defaultValue: 1,
                                 tint: state.tintActive,
                                 controlSize: .mini)
                    .frame(width: Column.trim, height: 16)
                    .help("Trim for this stream. Double-click to return it to 0 dB.")
                Text(verbatim: gainText)
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(Color.mutedLabel)
                    .frame(width: Column.gain, alignment: .leading)
                HStack(spacing: 3) {
                    PillToggle(title: "M",
                               isOn: Binding(get: { state.isMuted(stream.id) },
                                             set: { _ in state.toggleMute(stream.id) }),
                               tint: skin.style.mute ?? .red, help: "Mute this stream",
                               spokenName: "Mute \(stream.name)")
                    PillToggle(title: "S",
                               isOn: Binding(get: { state.soloed == stream.id },
                                             set: { _ in state.toggleSolo(stream.id) }),
                               tint: skin.style.solo ?? state.tintSolo, help: "Listen to this stream alone",
                               spokenName: "Solo \(stream.name)")
                }
                .frame(width: Column.states)
            } else {
                Color.clear.frame(height: 1)
            }
            }
            .frame(width: Column.controls, alignment: .leading)
            .clipped()

            HStack(spacing: 4) {
                Chip(text: stream.source.label, tint: .tint(for: stream.source), filled: true)
                    .help(stream.latencyClass.help)
                // Channel count, not the inferred layout: AES67 carries no channel-order
                // metadata, so an 8-channel stream is just as likely to be 8 discrete feeds.
                Chip(text: "\(stream.channels) ch")
                Spacer(minLength: 0)
            }
            .frame(width: Column.chips)

            status
                .frame(width: Column.status, alignment: .leading)

            if state.detailed {
                // On the app's one beat, drawn by AppKit: SwiftUI does no work for it.
                LiveFigureText(text: { [self] in (jitterText, jitterWarns) })
                    .frame(width: Column.jitter, height: 16)
            }

            if active {
                Button { toggleOpen() } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(Color.mutedLabel)
                        .frame(width: 15)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(stream.name) detail")
                .accessibilityValue(open ? "shown" : "hidden")
                .help(open ? "Hide this stream's detail" : "Show this stream's detail")
            } else {
                Color.clear.frame(width: 15, height: 1)
            }
        }
    }

    /// The row's state in a word and a symbol — the dot it replaces said it in colour alone.
    /// A Network Audio Sender asking its user first says so here, before the stream plays.
    @ViewBuilder
    private var status: some View {
        if !active, state.joinFailures[stream.id] != nil {
            statusLabel("Can't join", symbol: "xmark.octagon.fill", tint: Color.red)
                .help(state.joinFailures[stream.id] ?? "")
        } else if let approval = state.vbanApprovals[stream.id] {
            statusLabel(approval == .waiting ? "Asking…" : "Declined",
                        symbol: approval == .waiting ? "hourglass" : "xmark.octagon",
                        tint: approval == .waiting ? (skin.style.warning ?? Color.orange) : Color.red)
                .help(approval == .waiting
                      ? "The Sender's user has been asked to allow this Grabber. It plays as soon as they do."
                      : "The Sender's user declined this Grabber. It can be allowed again after the Sender is reopened.")
        } else if !active, let note = state.autoStopNote(stream.id) {
            // Auto-stop took it off (Settings → Playout); says when, and where that is set.
            statusLabel("Timed out", symbol: "timer", tint: skin.style.warning ?? Color.orange)
                .help(note)
        } else if active {
            let receiving = state.isReceiving(stream.id)
            statusLabel(receiving ? "OK" : "No packets",
                        symbol: receiving ? "checkmark.circle" : "exclamationmark.triangle.fill",
                        tint: receiving ? Color.secondary : (skin.style.warning ?? Color.orange))
                .help(receiving ? "Receiving" : "No packets arriving")
        } else {
            Color.clear.frame(height: 1)
        }
    }

    private func statusLabel(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11))
            .foregroundStyle(tint)
            .lineLimit(1)
    }

    private var gainText: String {
        let g = state.gain(for: stream.id)
        if g <= 0.0001 { return "−∞" }
        return String(format: "%+.1f", 20 * log10(Double(g)))
    }

    private var jitterText: String {
        guard active, let f = state.figures(stream.id) else { return "" }
        return String(format: "%.2f ms", f.jitterMs)
    }

    private var jitterWarns: Bool {
        guard active, let f = state.figures(stream.id) else { return false }
        return state.jitterIsNotable(f, for: stream)
    }
}

/// The open stream, underneath its own row.
///
/// **Two columns, not a stack.** The channel meters are tall and narrow, so stacking the
/// controls and figures beneath them left the middle of the window empty and pushed five rows
/// off the list for space that was already on screen. Beside them, the block is about 120
/// points instead of 260.
/// Every channel of a playing stream in the row's Level column,
/// one hairline each, so a silent channel on a stream that is not open is still seen.
struct RowChannelMeters: View {
    @Environment(AppState.self) var state
    let stream: StreamDescription
    let silenced: Bool
    var length: CGFloat = StreamRowView.Column.meter
    /// The compact window's rows: thinner, so an 8-channel stream stays the height of the
    /// row's buttons.
    var slim = false

    var body: some View {
        let n = stream.channels
        // 2 ch: two 3-point bars; 8 ch: 2-point bars; 16 and up: 1-point, no gap.
        let thickness: CGFloat = slim ? (n <= 2 ? 3 : 1) : (n <= 2 ? 3 : (n <= 8 ? 2 : 1))
        let slot: CGFloat = slim ? (n <= 2 ? 4 : (n <= 8 ? 2 : 1)) : (n <= 2 ? 5 : (n <= 8 ? 3 : 1))
        let solo = state.soloedChannels(stream.id)
        MeterStrip(count: n, orientation: .horizontal, thickness: thickness, slot: slot,
                   length: length, fps: state.meterRate,
                   paused: !state.metersActive,
                   level: { state.channelPeak(stream.id, $0) },
                   isDimmed: { silenced || (!solo.isEmpty && !solo.contains($0)) },
                   noData: { [state, id = stream.id] in !(state.health[id]?.receiving ?? false) },
                   trackless: true)
            .frame(height: slot * CGFloat(n))
            .id(n)
            // Muted by you: grey bars, as any stream not reaching the output, plus a dark red
            // surround that says why — a solo elsewhere greys the bars without it.
            .padding(3)
            .overlay(RoundedRectangle(cornerRadius: 3)
                .stroke(Color.red.opacity(state.isMuted(stream.id) ? 0.55 : 0), lineWidth: 1.5))
    }
}

/// The outlined channel-solo badge the Inputs section carried, on the row instead.
struct ChannelSoloBadge: View {
    @Environment(AppState.self) var state
    let stream: StreamDescription

    var body: some View {
        let names = state.channelLabels(for: stream, folded: true)
        let text = state.soloedChannels(stream.id).sorted()
            .map { $0 < names.count ? names[$0] : "\($0 + 1)" }.joined(separator: " ")
        Text(verbatim: "S " + text)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(state.tintSoloText)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(Capsule().stroke(state.tintSolo, lineWidth: 1))
    }
}

/// Copy SDP and Copy address, in every right-click menu a stream has: its row, the open detail
/// under it (the row's menu covers both) and its strip in the signal panel.
struct StreamCopyItems: View {
    let stream: StreamDescription

    var body: some View {
        // VBAN has no session description to copy.
        if !stream.rawSDP.isEmpty {
            Button("Copy SDP") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(stream.rawSDP, forType: .string)
            }
        }
        Button("Copy address") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(stream.source == .web ? stream.groupAddress
                                           : "\(stream.groupAddress):\(stream.port)", forType: .string)
        }
    }
}

struct StreamDetailBlock: View {
    @Environment(AppState.self) var state
    @Environment(\.colorScheme) private var scheme
    let stream: StreamDescription

    private var layout: SMPTELayout? { SMPTELayout.forChannelCount(stream.channels) }
    private var folded: Bool { state.mixMode(for: stream.id) == .downmix }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 18) {
                ChannelMeters(stream: stream,
                              labels: state.channelLabels(
                                  for: stream,
                                  folded: folded || state.hasChannelSolo(stream.id)))
                    .fixedSize()
                    // Muted by you: the same dark red surround as the row's meters.
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.red.opacity(state.isMuted(stream.id) ? 0.55 : 0), lineWidth: 1.5))
                VStack(alignment: .leading, spacing: 9) {
                    assumptions
                    if state.detailed { figures } else { facts }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // **Across the block, not beside the meters.** In a column it wrapped mid-word —
            // "SOL / O", "Fro / nt" — because a solo row for a 7.1 stream is every channel
            // plus three groups plus Clear, which is wider than any column it could sit in.
            channelSolo
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 10)
        // Neutral, as the row above it: the accent is for things switched on, and an open
        // row is only selected. The row's own ground already covers this block.
    }

    // MARK: - What this stream is assumed to be, and what it is doing

    private var assumptions: some View {
        HStack(spacing: 8) {
            // No mix menu here: it is on the row, two lines up. What this line adds is what
            // the menu's own title cannot say — the order being assumed, and the channel solo
            // that overrides the whole mix while it is engaged.
            // The channel order is an assumption either way — nothing in an AES67 stream
            // declares it — and changing it lives in the mix menu above, in both
            // densities. What must never be silent is an order that has been changed away
            // from the default, so that gets a chip of its own.
            if state.hasOwnChannelOrder(stream.id) {
                Chip(text: state.channelOrder(for: stream.id).name, tint: .orange)
            }
            // Names the fold, the order and — while one is engaged — the channel solo, which
            // is more than the mix menu alone says.
            Text(verbatim: state.mixCaption(for: stream))
                .font(.system(size: 9,
                              weight: state.hasChannelSolo(stream.id) ? .bold : .regular))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3)
                    .fill(state.tintSolo)
                    .opacity(state.hasChannelSolo(stream.id) ? 1 : 0))
                .foregroundStyle(state.hasChannelSolo(stream.id)
                                 ? AnyShapeStyle(state.tintSolo.readableForeground)
                                 : AnyShapeStyle(Color.mutedLabel))
            Spacer(minLength: 0)
        }
    }

    // MARK: - Channel solo

    /// Monitor individual channels on their own, in the positions the fold-down gives them, so
    /// soloing Lrs and Rrs on a 7.1 stream is the rear pair at the level it sits at inside the
    /// full fold. Overrides the mix mode rather than filtering it (`Downmix.soloTaps`).
    private var channelSolo: some View {
        let soloed = state.soloedChannels(stream.id)
        let names = layout?.channelNames ?? (1...stream.channels).map(String.init)
        return HStack(spacing: 4) {
            Text("Solo")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.mutedLabel)
                .fixedSize()
                .help("Monitor these channels on their own, in their fold-down positions")

            ForEach(0..<stream.channels, id: \.self) { channel in
                let on = soloed.contains(channel)
                Button { state.toggleChannelSolo(stream.id, channel) } label: {
                    Text(verbatim: channel < names.count ? names[channel] : "\(channel + 1)")
                        .font(.system(size: 9, weight: on ? .bold : .regular, design: .rounded))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(on ? state.tintSolo.opacity(0.85) : Color.primary.opacity(0.07)))
                        .foregroundStyle(on ? state.tintSolo.readableForeground : Color.secondary)
                        .fixedSize()
                }
                .buttonStyle(.plain)
            }

            // One click for the groups people actually ask for, on the layouts that have them.
            ForEach(channelGroups, id: \.name) { group in
                Button { state.soloChannels(stream.id, named: group.names) } label: {
                    Text(verbatim: group.name)
                        .font(.system(size: 9))
                        .foregroundStyle(Color.mutedLabel)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .help("Solo \(group.names.joined(separator: " "))")
            }

            Spacer(minLength: 0)
            if !soloed.isEmpty {
                Button { state.clearChannelSolo(stream.id) } label: {
                    Text(verbatim: "Clear")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(state.tintActive(on: scheme))
                        .fixedSize()
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Named groups for the known SMPTE layouts. Nothing for a discrete stream, where a "rear"
    /// would be a guess.
    private var channelGroups: [(name: String, names: [String])] {
        switch layout {
        case .quad:       return [("Front", ["L", "R"]), ("Rears", ["Ls", "Rs"])]
        case .surround51: return [("Front", ["L", "R", "C"]), ("Rears", ["Ls", "Rs"])]
        case .surround71: return [("Front", ["L", "R", "C"]),
                                  ("Sides", ["Lss", "Rss"]),
                                  ("Rears", ["Lrs", "Rrs"])]
        default:          return []
        }
    }

    // MARK: - The right-hand column

    /// Simple: what the row's second line used to carry, shown once for the stream in hand
    /// rather than twelve times for streams nobody is looking at.
    private var facts: some View {
        // One cell. Everything else that was here is either already on the row — the source
        // chip, the channel count — or is not simple: the format is the same for every AES67
        // stream on a network, and a PTP clock identifier is nobody's idea of an easy read.
        // The second row of cells was also making every open stream taller for no gain.
        // A VBAN stream is unicast or broadcast from its sender, so there is no group to name.
        if stream.source == .web {
            // An internet stream: what is on, where it comes from, and what it is.
            grid([("now playing", state.nowPlaying[stream.id] ?? "—", false),
                  ("address", stream.groupAddress, false),
                  ("format", stream.formatSummary, false)], columns: 3)
        } else {
            grid([(stream.source == .vban ? "from" : "group",
                   "\(stream.groupAddress):\(stream.port)", false)], columns: 3)
        }
    }

    /// Detailed: every figure the receiver already keeps. Polled at a few hertz rather than
    /// published — these climb continuously, and publishing them re-evaluated the whole window
    /// four times a second. Built only while a row is open, so nothing polls when
    /// nothing is looking.
    private var figures: some View {
        // Drawn by AppKit on the tick's beat, not re-evaluated by SwiftUI.
        LiveFigureGrid(columns: 4, cells: { [self] in figureCells() })
        // A height, because a `TimelineView` that resizes invalidates the layout around it
        // — but the height the cells actually need, not a number that fitted two rows
        // of them. Ten figures, the clock always among them, four across.
        .frame(height: Self.gridHeight(cells: 10, columns: 4),
               alignment: .topLeading)
    }

    /// The ten figures, polled on each beat.
    private func figureCells() -> [(String, String, Bool)] {
        let f = state.figures(stream.id) ?? StreamFigures()
        let lost = health?.lost ?? 0
        let underruns = health?.underruns ?? 0
        return [("jitter", String(format: "%.2f ms", f.jitterMs), state.jitterIsNotable(f, for: stream)),
                ("worst", String(format: "%.2f ms", f.worstJitterMs), state.jitterIsNotable(f, for: stream)),
                ("buffer", String(format: "%.0f ms", f.bufferMs), false),
                ("low water", String(format: "%.0f ms", f.minBufferMs), false),
                ("drift", String(format: "%+.0f ppm", f.driftPPM), false),
                ("lost", "\(lost)", lost > 0),
                ("underruns", "\(underruns)", underruns > 0),
                ("last underrun", Self.ago(health?.lastUnderrun), false),
                // An internet stream's "packets" are decoded blocks, which mean nothing to
                // anyone; what is playing does.
                stream.source == .web
                  ? ("now playing", state.nowPlaying[stream.id] ?? "—", false)
                  : ("packets", "\(f.packets)", false),
                // Every stream says how it keeps time: its PTP clock, or that it has none.
                ("clock", stream.ptpRef ?? stream.latencyClass.clockLabel, false)]
                // Where a VBAN or Scream stream is coming from: a Sender on several networks
                // can reach this Grabber at more than one address.
                + ([.vban, .scream].contains(stream.source) ? [("from", stream.originAddress, false)] : [])
    }

    private var health: StreamHealth? { state.health[stream.id] }

    /// "12 s ago", "4 min ago", or a dash for never. Redrawn by the figures' own timeline.
    static func ago(_ date: Date?) -> String {
        guard let date else { return "—" }
        let s = max(0, Int(Date().timeIntervalSince(date)))
        if s < 60 { return "\(s) s ago" }
        if s < 3600 { return "\(s / 60) min ago" }
        return "\(s / 3600) h ago"
    }

    /// One cell is a 7-point label over a 10-point value, and the grid spaces rows by 7.
    static func gridHeight(cells: Int, columns: Int) -> CGFloat {
        let rows = max(1, (cells + columns - 1) / columns)
        return CGFloat(rows) * 30 + CGFloat(rows - 1) * 7     // 10-point label over a 12-point value
    }

    /// Rows of equal-width cells — what a `LazyVGrid` of flexible columns draws, without a lazy
    /// container's bookkeeping. These figures are re-laid-out four times a second while a row is
    /// open, and for ten fixed cells laziness buys nothing.
    private func grid(_ cells: [(String, String, Bool)], columns: Int) -> some View {
        let rows = (cells.count + columns - 1) / columns
        return VStack(alignment: .leading, spacing: 7) {
            ForEach(0..<rows, id: \.self) { r in
                HStack(alignment: .top, spacing: 8) {
                    ForEach(0..<columns, id: \.self) { c in
                        let i = r * columns + c
                        if i < cells.count {
                            cell(cells[i]).frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                        }
                    }
                }
            }
        }
    }

    private func cell(_ cell: (String, String, Bool)) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            // Sentence case at a readable size: the 7-point bold capitals were the
            // smallest type in the app.
            Text(verbatim: cell.0.prefix(1).uppercased() + cell.0.dropFirst())
                .font(.system(size: 10))
                .foregroundStyle(Color.mutedLabel)
            Text(verbatim: cell.1)
                .font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(cell.2 ? Color.orange : Color.secondary)
                .lineLimit(1)
                // Middle: the front of an address and the tail of a clock identifier
                // are both the informative end, and this is the only mode that keeps
                // something of each.
                .truncationMode(.middle)
                // The whole value, for when the middle had to go.
                .help(cell.1)
        }
    }
}

