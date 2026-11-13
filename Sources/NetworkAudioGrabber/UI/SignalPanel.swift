import SwiftUI

/// The right-hand signal panel: the monitor path read top to bottom, in the order the audio
/// actually travels — the inserts, then the output.
///
/// **No Inputs section** (decided from the layout mockups): each
/// playing row carries every channel in its Level column, and several rows can be open at once,
/// which were the two things the section was for. The output, with every loudness reading beside
/// its meters, takes the room it left; the full window has no separate Loudness section (the
/// compact window keeps its own).
struct SignalPanel: View {
    @Environment(\.skin) private var skin
    @Environment(AppState.self) var state

    /// 272, from 352: with the readings beside the meters the panel no longer needs the width
    /// the Inputs strips and the old readout row took (narrower still than the 300 first
    /// suggested).
    static let width: CGFloat = 272

    var body: some View {
        VStack(spacing: 0) {
            // No inserts inside a DAW: the host's own plugin slots do that job.
            if let layout = state.previewSendLayout, layout.hasPrefix("panel") {
                SendPanelSectionMock(open: layout == "panel-open")
                Divider()
            }
            if !AudioOutput.hostMode {
                inserts
                Divider()
            }
            OutputSection(meterHelp: outputMeterHelp)
        }
        .frame(width: Self.width)
        .background(skin.style.panel.map { Color(nsColor: $0) } ?? Color.primary.opacity(0.03))
    }

    /// The shortest the panel can be and still show every reading.
    ///
    /// The output is the flexible section: its meters take whatever height the window gives,
    /// down to the floor at which the readings beside them still fit — measured off
    /// `full-floor.png`, which is rendered at exactly this height so the shot shows the moment it
    /// stops being true.
    static func minimumHeight(slots: Int, showMix: Bool, showLoudness: Bool,
                              showHistory: Bool = false, insertsOpen: Bool = true) -> CGFloat {
        // A folded section is its heading alone.
        let folded: CGFloat = 34
        let inserts = insertsOpen ? 30 + CGFloat(slots) * (showMix ? 52 : 32) : folded
        // Heading 30 · the figures column (peak, and the three readings when loudness is on) ·
        // volume and DIM/MONO 66 · padding 12.
        let figures: CGFloat = showLoudness ? 272 : 150
        let output = 30 + figures + 66 + 12 + (showHistory ? 40 : 0)
        return inserts + output + 12
    }

    /// The window height that floor implies, including the toolbar and status bar.
    static func minimumWindowHeight(slots: Int, showMix: Bool, showLoudness: Bool,
                                    showHistory: Bool = false, insertsOpen: Bool = true) -> CGFloat {
        minimumHeight(slots: slots, showMix: showMix, showLoudness: showLoudness,
                      showHistory: showHistory, insertsOpen: insertsOpen) + 72
    }

    // MARK: - Inserts

    private var inserts: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The count is of plugins *available*, not loaded: an empty menu is what a failed
            // AU scan looks like, so the number that says the scan finished has to stay.
            // The chain's added latency goes beside it, not instead of it.
            HStack(spacing: 6) {
                foldButton("Inserts", open: Bindable(state).panelInsertsOpen)
                Spacer(minLength: 6)
                if state.panelInsertsOpen {
                    Text(verbatim: state.availablePlugins.isEmpty
                         ? "scanning…" : "\(state.availablePlugins.count) AU\(chainLatency)")
                        .font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(Color.mutedLabel)
                } else {
                    insertsSummary
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, state.panelInsertsOpen ? 6 : 9)
            if state.panelInsertsOpen {
                VStack(spacing: 5) {
                    ForEach(0..<state.slotBypassed.count, id: \.self) { slot in
                        InsertSlotView(slot: slot)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
    }

    /// Folded, what is loaded — and a failed insert said in red, so folding cannot hide it.
    @ViewBuilder private var insertsSummary: some View {
        let failed = state.slotFailure.compactMap { $0 }.count
        if failed > 0 {
            Label(failed == 1 ? "1 insert stopped" : "\(failed) inserts stopped", systemImage: "xmark.octagon.fill")
                .font(.system(size: 10)).foregroundStyle(Color.red).lineLimit(1)
        } else {
            let loaded = state.slotInfo.enumerated().compactMap { i, info in
                info.map { state.slotBypassed[i] ? "\($0.name) (bypassed)" : $0.name }
            }
            Text(verbatim: loaded.isEmpty ? "none" : loaded.joined(separator: ", "))
                .font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    /// What the loaded inserts add to the monitor path, which delta already measures per slot.
    private var chainLatency: String {
        let total = state.slotLatencyMs.enumerated()
            .filter { state.slotLive[$0.offset] && !state.slotBypassed[$0.offset] }
            .map(\.element)
            .reduce(0, +)
        return total > 0.05 ? String(format: " · +%.1f ms", total) : ""
    }

    /// A target as the heading shows it: whole numbers without the point, and the same minus as
    /// the readings beside it.
    static func target(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }


    /// What the master bars are showing, which depends on what else is switched on — the tap
    /// is at the **end** of the chain, so the inserts, DIM and MONO are all in it.
    private var outputMeterHelp: String {
        let what = "The monitor bus, peak, taken after the inserts and the monitor controls — "
                 + "the last thing before the output device. Green to −18 dBFS, amber to −6, "
                 + "red above; the tick is the peak hold. The loudness readings are measured "
                 + "somewhere else entirely, ahead of all of this."
        var now = "Stereo out of \(state.outputDeviceName)."
        if let delta = state.deltaSlot {
            now += " Insert \(delta + 1) is in Δ, so these bars are showing a difference "
                 + "signal, not the programme."
        }
        if state.monoFold { now += " MONO: both channels carry the same sum." }
        if state.dimmed { now += " DIM: 20 dB down." }
        return tooltip(what, now: now)
    }

    // MARK: - Shared

    static let headingFont = Font.system(size: 12, weight: .semibold)

    /// A section heading that folds its section, as the compact window's do: only the chevron and
    /// the title are the button, so anything beside them stays usable.
    private func foldButton(_ title: String, open: Binding<Bool>) -> some View {
        Button { open.wrappedValue.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: open.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.mutedLabel)
                    .frame(width: 8)
                Text(verbatim: title).font(Self.headingFont).foregroundStyle(Color.mutedLabel)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(open.wrappedValue ? "open" : "folded")
    }
}

/// The output: the peak maximum and the loudness readings on the left, the meters on the right
/// at the panel's edge, as tall as the window allows; the level, DIM, MONO and the history under
/// them (laid out after Wwise's master meters).
private struct OutputSection: View {
    @Environment(AppState.self) var state
    @Environment(\.skin) private var skin
    let meterHelp: String

    /// REAPER's master: two bars with the scale between them, as its mixer draws a stereo meter.
    private var reaperStereo: Bool { skin.style.scale == .between && state.busChannels == 2 }

    private static let scale: [Int] = [0, -6, -12, -18, -24, -30, -40, -50, -60]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                // Never folded: the output is what the app is for. Inset
                // by the chevron's width so its title lines up with the folding sections'.
                Text(verbatim: "Output").font(SignalPanel.headingFont).foregroundStyle(Color.mutedLabel)
                    .fixedSize()
                    .padding(.leading, 14)
                Text(state.outputDeviceName).font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                    .lineLimit(1).truncationMode(.middle)
                    .help("The output device the monitor bus plays out of. Change it in Settings → Output, or macOS's own Sound settings.")
                Spacer(minLength: 4)
                // Only worth showing where there is a choice to make. On the two-channel
                // devices most people monitor on, there is not.
                if state.busWidthOptions.count > 1 { busWidthMenu }
                Text(verbatim: String(format: "%.4g kHz", state.outputRate / 1000))
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(Color.mutedLabel)
                    .fixedSize()
            }
            .padding(.top, 9)

            GeometryReader { geo in
                // Every figure shrinks together as the readings' column narrows — a wider bus
                // takes more of the panel for its bars — so none wraps (a 5.1 bus once pushed
                // the integrated figure's last digit onto a second line).
                let scale = Self.fontScale(column: geo.size.width - metersWidth - 12)
                HStack(alignment: .top, spacing: 12) {
                    // Its own view, reading `Readouts` itself, so the figures changing four times
                    // a second re-evaluate the figures and nothing else.
                    OutputFigures(scale: scale)
                        .frame(height: geo.size.height - 12, alignment: .top)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    meters(length: max(60, geo.size.height - 30))
                        .help(meterHelp)
                }
            }
            .frame(minHeight: state.showLoudness ? 272 : 150, maxHeight: .infinity)

            HStack(spacing: 6) {
                Image(systemName: state.masterVolume > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                ResettableSlider(value: Bindable(state).masterVolume, defaultValue: 1, tint: state.tintActive)
                    .frame(height: 20).controlSize(.small)
                    .tint(state.tintActive)
                // Fixed width and monospaced digits, so the slider does not shift under the
                // pointer as the number changes width while dragging.
                Text(verbatim: state.masterVolumeLabel).font(.system(size: 10)).monospacedDigit()
                    .foregroundStyle(Color.mutedLabel).frame(width: 46, alignment: .trailing)
            }
            .help(state.masterVolumeHelp)
            HStack(spacing: 5) {
                PillToggle(title: "DIM", isOn: Bindable(state).dimmed, tint: state.tintActive,
                           help: tooltip("Drops the monitor level by 20 dB — the "
                                       + "conventional dim on a monitor controller. It "
                                       + "sits after the loudness measurement, so it "
                                       + "cannot move a reading.",
                                         now: state.dimmed ? "ON — output is 20 dB down." : "Off."))
                PillToggle(title: "MONO", isOn: Bindable(state).monoFold, tint: state.tintActive,
                           help: tooltip("Sums the bus to one signal and sends it to "
                                       + "every channel, for a phase check: anything "
                                       + "that thins or disappears is out of phase. "
                                       + "Averaged, not added, so a correlated mix "
                                       + "stays at the level it was.",
                                         now: state.monoFold
                                            ? "ON — you are hearing a mono sum, not the mix."
                                            : "Off — hearing the mix as it is."))
            }
            if state.showLevelHistory { LevelHistoryStrip() }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    /// How wide the monitor bus is, next to the meters that show it.
    ///
    /// Bounded by the device, but not dictated by it: a 16-output interface is rarely a
    /// 16-speaker room, so the layouts it *could* carry are all offered and the device maximum
    /// is just one of them. The choice is remembered per device.
    private var busWidthMenu: some View {
        Menu {
            ForEach(state.busWidthOptions, id: \.self) { width in
                Button {
                    state.setBusWidth(width)
                } label: {
                    if width == state.busChannels {
                        Label(state.busWidthLabel(width), systemImage: "checkmark")
                    } else {
                        Text(state.busWidthLabel(width))
                    }
                }
            }
        } label: {
            Text(verbatim: state.busChannels == 2 ? "Stereo" : state.busWidthLabel(state.busChannels))
                .font(.system(size: 9, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(busWidthHelp)
    }

    private var busWidthHelp: String {
        let what = "How wide the monitor bus is — how many of this device's outputs the app "
                 + "plays out of. Streams that fit go out channel for channel; anything wider "
                 + "than the bus folds to stereo on the first pair. Remembered for this device, "
                 + "so headphones and a monitor rig each keep their own answer."
        let now = state.busChannels == 2
            ? "Stereo — wider streams fold down. \(state.outputDeviceName) offers "
            + "\(state.outputChannels) channels."
            : "\(state.busWidthLabel(state.busChannels)) of \(state.outputChannels) available "
            + "on \(state.outputDeviceName). Fold-down no longer applies to streams that fit."
        return tooltip(what, now: now)
    }

    /// The bars' block is capped at this width, so however wide the bus, the readings keep
    /// at least ~115 points of the panel (12 and 16 channels squeezed them to a letter a line).
    private static let maxBarsWidth: CGFloat = 96

    /// Bar thickness and slot for `n` channels: fat for stereo, then as wide as the cap allows.
    static func barGeometry(_ n: Int) -> (thickness: CGFloat, slot: CGFloat) {
        if n <= 2 { return (24, 30) }
        let slot = min(16, (maxBarsWidth / CGFloat(n)).rounded(.down))
        return (max(3, slot - (slot >= 10 ? 4 : 2)), slot)
    }

    /// The meters' own width: the scale, then one slot a channel.
    private var metersWidth: CGFloat {
        reaperStereo ? 22 + 26 + 22
                     : 22 + 4 + Self.barGeometry(state.busChannels).slot * CGFloat(state.busChannels)
    }

    /// Channel names under the bars: in full to 6, two letters to 8 (`LFE` → `LF`, 7.1's
    /// `Lss`/`Lrs` → `Ls`/`Lr`), and past that every fourth channel only — enough to count from,
    /// and honest about the rest rather than truncating "13" to "1". SMPTE names, or numbers
    /// when the bus is not in SMPTE order (`busChannelLabels` decides).
    private var barLabels: [String] {
        let names = state.busChannelLabels
        let n = state.busChannels
        if n > 8 { return names.indices.map { $0 % 4 == 0 ? names[$0] : "" } }
        if n > 6 { return names.map { $0.count <= 2 ? $0 : String($0.prefix(2)) } }
        return names
    }

    /// 1 at 150 points and wider — what the pinned integrated figure and its delta need at full
    /// size — down to 0.7, in proportion.
    static func fontScale(column: CGFloat) -> CGFloat {
        min(1, max(0.7, column / 150))
    }

    @ViewBuilder private func meters(length: CGFloat) -> some View {
        if reaperStereo { reaperMeters(length: length) } else { standardMeters(length: length) }
    }

    private func reaperMeters(length: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach([0, 1], id: \.self) { ch in
                if ch == 1 {
                    ReaperScale(vertical: true, dashed: true)
                        .frame(width: 26, height: length)
                }
                VStack(spacing: 4) {
                    MeterStrip(count: 1, thickness: 22, slot: 22, length: length,
                               fps: state.meterRate, paused: !state.metersActive,
                               level: { _ in state.outputPeak(ch) }, hold: { state.outputPeakHold })
                        .frame(width: 22, height: length)
                    Text(verbatim: ch == 0 ? "L" : "R")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.mutedLabel)
                }
            }
        }
    }

    private func standardMeters(length: CGFloat) -> some View {
        let n = state.busChannels
        let (thickness, slot) = Self.barGeometry(n)
        let names = barLabels
        return HStack(alignment: .top, spacing: 4) {
            // The scale, on the meter's own −60 dBFS mapping.
            ZStack(alignment: .topTrailing) {
                ForEach(Self.scale, id: \.self) { db in
                    Text(verbatim: "\(db)")
                        .font(.system(size: 9)).monospacedDigit().foregroundStyle(Color.mutedLabel)
                        .frame(width: 22, alignment: .trailing)
                        .offset(y: length * CGFloat(-db) / 60 - 6)
                }
            }
            .frame(width: 22, height: length, alignment: .topTrailing)
            .accessibilityHidden(true)
            VStack(spacing: 4) {
                MeterStrip(count: n, thickness: thickness, slot: slot, length: length,
                           fps: state.meterRate, paused: !state.metersActive,
                           level: { state.outputPeak($0) }, hold: { state.outputPeakHold })
                    .frame(width: slot * CGFloat(n), height: length)
                    // Keyed on the width: an `NSViewRepresentable` kept across a change of bar
                    // count does not reliably survive it — the meters came back blank after
                    // narrowing the bus.
                    .id(n)
                HStack(spacing: slot - thickness) {
                    ForEach(0..<n, id: \.self) { i in
                        Text(verbatim: i < names.count ? names[i] : "\(i + 1)")
                            .font(.system(size: n <= 6 ? 8 : 7, weight: .semibold))
                            .lineLimit(1)
                            .foregroundStyle(Color.mutedLabel)
                            .fixedSize()
                            .frame(width: thickness)
                    }
                }
            }
        }
    }
}

/// The peak maximum with its clip dot, then the loudness readings — the pinned one first and
/// larger. Everything here follows `Readouts`, and nothing outside it does.
private struct OutputFigures: View {
    @Environment(\.skin) private var skin
    @Environment(AppState.self) var state
    let scale: CGFloat

    var body: some View {
        let r = state.readouts
        // Gaps that give a little and take a little: wider in a tall window,
        // closing up as it is made shorter, but capped, so the readings stay one group near the
        // top rather than spreading to the meters' foot.
        VStack(alignment: .leading, spacing: 0) {
            peak(r)
            if state.showLoudness {
                Color.clear.frame(minHeight: 10, maxHeight: 26)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text("Loudness").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            .foregroundStyle(Color.mutedLabel)
                        Spacer(minLength: 4)
                        Button { state.resetLoudness() } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.mutedLabel)
                        .help("Reset the integrated and window readings (⇧⌘L)")
                        .accessibilityLabel("Reset the loudness measurement")
                    }
                    // The target on its own line under the heading, so a narrow column never
                    // squeezes the two together.
                    Text(verbatim: "target \(SignalPanel.target(state.targetIntegrated)) LUFS")
                        .font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                        .lineLimit(1)
                }
                // Indented under their heading and its target line. The pinned reading leads,
                // larger (Settings → View → Pinned loudness); with none pinned, the three in their
                // usual order at one size.
                ForEach(orderedReadings(r), id: \.label) { item in
                    Color.clear.frame(minHeight: 6, maxHeight: 18)
                    reading(item.label, item.value, large: item.pinned)
                        .padding(.leading, 8)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// A maximum, not a live level: the bars already show the level, and a figure that only
    /// moves when a new peak beats the old one can be published rather than redrawn.
    private func peak(_ r: Readouts) -> some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: r.outputMax).font(.system(size: 28 * scale, weight: .light))
                    .monospacedDigit().lineLimit(1)
                    .foregroundStyle(skin.style.figureText ?? Color.primary)
                    .accessibilityLabel("Peak output")
                    .accessibilityValue("\(r.outputMax) dBFS maximum")
                Text("dBFS max").font(.system(size: 10)).foregroundStyle(Color.mutedLabel).lineLimit(1)
            }
            // `contentShape` so the gaps between the labels are hittable too — without it a
            // double-click has to land exactly on a glyph.
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { state.clearClip() }
            .help("Highest output level since it was last reset. Double-click to "
                + "reset it and start logging a new maximum.")
            Button { state.clearClip() } label: {
                Circle()
                    .fill(state.clipped ? Color.red : Color.primary.opacity(0.12))
                    .frame(width: 8, height: 8)
            }
            .buttonStyle(.plain)
            .padding(.top, 10 * scale)
            .help(state.clipped
                  ? "Clipped — click to reset the maximum and the clip indicator"
                  : "Click to reset the maximum")
            .accessibilityLabel("Clip indicator — reset the peak maximum")
            .accessibilityValue(state.clipped ? "clipped" : "no clip")
        }
    }

    private func orderedReadings(_ r: Readouts) -> [(label: String, value: LoudnessReading, pinned: Bool)] {
        let all: [(LoudnessPin, String, LoudnessReading)] = [
            (.shortTerm, "Short-term", r.shortTerm),
            (.window, "Window \(state.lufsWindowSeconds) s", r.window),
            (.integrated, "Integrated", r.integrated),
        ]
        let pin = state.pinnedLoudness
        let first = all.filter { $0.0 == pin }, rest = all.filter { $0.0 != pin }
        return (first + rest).map { ($0.1, $0.2, $0.0 == pin) }
    }

    private func reading(_ label: String, _ value: LoudnessReading, large: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: label).font(.system(size: 10)).foregroundStyle(Color.mutedLabel).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: value.value).font(.system(size: (large ? 30 : 18) * scale, weight: .light))
                    .monospacedDigit().foregroundStyle(large ? value.colour : (skin.style.figureText ?? Color.primary))
                    .lineLimit(1)
                if let delta = value.delta {
                    Text(verbatim: delta).font(.system(size: max(9, 11 * scale), weight: .medium))
                        .monospacedDigit().lineLimit(1)
                        .foregroundStyle(value.colour)
                }
            }
        }
        // Double-click resets, as the rows of the compact window's loudness block do.
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { state.resetLoudness() }
        .accessibilityElement(children: .combine)
    }
}
