import SwiftUI

/// The Sender's three inserts, laid out as the Grabber's are: a plugin menu per slot, then BYP
/// and the plugin's own editor, with the dry/wet slider shown only if asked for. What goes out
/// to every target is the audio after these; the meters above read it after them too.
///
/// No Δ, unlike the Grabber's: what this Mac plays is captured *before* the inserts, so nothing
/// here can hear their effect to compare against. The note under the slots says where it is
/// heard instead.
struct SenderInserts: View {
    @Environment(SenderState.self) var state
    /// Folded by default, as the compact Grabber's inserts can be: most Senders run with
    /// none, and the summary beside the heading says what is loaded when they are folded.
    @AppStorage("insertsOpen") private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button { open.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.mutedLabel)
                            .frame(width: 8)
                        Text("Inserts").font(SenderView.headingFont)
                            .foregroundStyle(Color.mutedLabel)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(open ? "Fold the inserts away" : "Show the inserts")
                Spacer(minLength: 8)
                Text(summary)
                    .font(.system(size: 10)).monospacedDigit()
                    .foregroundStyle(Color.mutedLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12).frame(height: 34)
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    VStack(spacing: 5) {
                        ForEach(0..<state.slotInfo.count, id: \.self) { slot in
                            SenderInsertSlot(slot: slot)
                        }
                    }
                    if state.hasInserts {
                        // Calm on purpose: this is how the Sender works, not a fault.
                        Label("Inserts are applied to the stream only — you will hear them at the "
                              + "receiver, not on this Mac.", systemImage: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.mutedLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 10)
            }
        }
    }

    /// Folded, what is loaded; open, what is available — the count that says the scan finished,
    /// since an empty menu is what a failed scan looks like.
    private var summary: String {
        let loaded = state.slotInfo.compactMap { $0?.name }
        if !open { return loaded.isEmpty ? "none" : loaded.joined(separator: ", ") + chainLatency }
        return state.availablePlugins.isEmpty ? "scanning…" : "\(state.availablePlugins.count) AU\(chainLatency)"
    }

    /// What the loaded inserts add before the audio leaves.
    private var chainLatency: String {
        let total = (0..<state.slotInfo.count)
            .filter { state.slotIsLive($0) && !state.slotBypassed[$0] }
            .map { state.slotLatencyMs($0) }
            .reduce(0, +)
        return total > 0.05 ? String(format: " · +%.1f ms", total) : ""
    }
}

private struct SenderInsertSlot: View {
    @Environment(SenderState.self) var state
    let slot: Int

    private var info: PluginInfo? { state.slotInfo[slot] }

    var body: some View {
        if let failure = state.slotFailure(slot) {
            FailedInsertRow(menu: AnyView(menu), reason: failure, reload: { state.reloadPlugin(slot: slot) })
        } else {
            working
        }
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                menu.layoutPriority(-1)
                Spacer(minLength: 0)
                if info != nil {
                    if state.slotIsRefused(slot) {
                        Chip(text: "needs \(state.insertChannels) ch", tint: .orange, filled: true)
                            .help(tooltip("This plugin will not take \(state.insertChannels) "
                                        + "channels, so it is held out of the chain rather than "
                                        + "applied to part of it.",
                                          now: "Out of circuit. Set Settings → Channels to Stereo, "
                                             + "or use a plugin that handles this many."))
                    }
                    if state.slotIsLive(slot) {
                        InsertThroughMeter(paused: !state.isActive) { [state, slot] out in
                            state.slotLevel(slot, output: out)
                        }
                    }
                    PillToggle(title: "BYP",
                               isOn: Binding(get: { state.slotBypassed[slot] },
                                             set: { _ in state.toggleBypass(slot: slot) }),
                               tint: .orange,
                               help: tooltip("Bypass — takes the plugin out of what is sent. A hard "
                                           + "bypass: the wet path is silenced rather than the "
                                           + "plugin being asked to stop.",
                                             now: state.slotBypassed[slot] ? "ON — out of circuit"
                                                                           : "off — processing"))
                    Button { state.showPluginUI(slot: slot) } label: {
                        Image(systemName: "slider.horizontal.below.rectangle").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.mutedLabel)
                    .help(tooltip("Opens this plugin's own window.", now: info?.display ?? ""))
                }
            }
            if info != nil, state.showInsertMix { mixRow }
        }
        // The Grabber's slot, point for point: the two apps' inserts are the same feature.
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    /// Dry/wet as the Grabber draws it: the same labels, the same double-click-to-reset slider in
    /// the secondary colour, dimmed rather than hidden while the slot is bypassed.
    private var mixRow: some View {
        HStack(spacing: 5) {
            Text(verbatim: "DRY")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(Color.mutedLabel)
            ResettableSlider(value: Binding(get: { state.slotMix[slot] },
                                            set: { state.setSlotMix(slot, $0) }),
                             defaultValue: 1,
                             tint: state.theme.active,
                             controlSize: .mini)
                .frame(height: 16)
            Text(verbatim: "WET")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(Color.mutedLabel)
            Text(verbatim: "\(Int((state.slotMix[slot] * 100).rounded())) %")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(Color.mutedLabel)
                .frame(width: 34, alignment: .trailing)
        }
        .opacity(state.slotBypassed[slot] ? 0.4 : 1)
        .help(tooltip("Dry/wet balance for this insert — ours, not the plugin's, so it works for "
                    + "every plugin. Double-click to put it back to fully wet.",
                      now: state.slotBypassed[slot] ? "Inert — the insert is bypassed."
                         : "\(Int((state.slotMix[slot] * 100).rounded())) % wet."))
    }

    /// The Grabber's picker, taking plain values so its 440-item menu is rebuilt only when the
    /// list or the choice changes.
    private var menu: some View {
        PluginPicker(slot: slot, plugins: state.availablePlugins, current: info,
                     choose: { [weak state] in state?.setPlugin(slot: slot, to: $0) })
            .equatable()
    }
}
