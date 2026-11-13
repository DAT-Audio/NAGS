import SwiftUI

/// The compact window: the monitor controls, the loudness readings and whatever is playing, in
/// a strip narrow enough to leave on screen beside something else.
///
/// It is a different arrangement of the same state, not a cut-down mode — every control here
/// drives exactly what its equivalent in the full window drives. What it gives up is the
/// discovery list (folded away behind a disclosure), the per-channel input meters and the
/// diagnostic figures, none of which are readable at this width.
struct CompactView: View {
    @Environment(\.skin) private var skin
    @Environment(AppState.self) var state
    @Environment(\.colorScheme) private var scheme
    @State private var showAvailable = false

    /// **Four type roles, not six sizes.** This window had 7, 8, 9, 10, 11 and 24 point text in
    /// one 320-point column, which is what made it read as dense rather than detailed: nothing
    /// in a hierarchy that fine is legibly ranked. Everything now lands on one of these.
    /// The output meter's geometry, in one place so the bars and their labels cannot disagree.
    ///
    /// A stereo bus gets the full 11-point slots it always had. Wider buses share a **fixed
    /// 44-point block** instead of growing the window a row at a time — sixteen channels at
    /// 11 points each would be 176 points of meter in a window whose whole monitor strip is
    /// about 150.
    private var meterSlot: CGFloat { Self.meterSlot(for: state.busChannels) }

    /// Slot height for a bus of this width, shared with `ContentView.minimumSize` so the window
    /// floor and the meter cannot disagree about how tall the monitor strip is.
    static func meterSlot(for channels: Int) -> CGFloat {
        guard channels > 2 else { return 11 }
        return min(11, max(4, 72 / CGFloat(channels)))
    }

    static func meterBlockHeight(for channels: Int) -> CGFloat {
        meterSlot(for: channels) * CGFloat(max(1, channels))
    }

    private var meterBar: CGFloat { max(2, meterSlot - 4) }

    /// Labels beside the bars, where there is room to read them: `L`/`R` on a stereo bus, the
    /// abbreviated SMPTE names up to eight channels, and nothing above that — a 3-point slot
    /// cannot hold a character, and the bus menu says what the layout is.
    private var meterLabels: [String]? {
        guard state.busChannels > 2 else { return ["L", "R"] }
        // A row shorter than 7 points cannot hold a legible character — at 8 channels in a
        // 44-point block the first attempt drew them into each other. Above that the bus menu
        // says what the layout is.
        guard meterSlot >= 7 else { return nil }
        return state.busChannelLabels.map { $0.count <= 2 ? $0 : String($0.prefix(2)) }
    }

    private enum Size {
        static let headline: CGFloat = 24   // the dBFS figure, the one thing read at a glance
        static let body: CGFloat = 11       // names — streams, devices, plugins
        static let label: CGFloat = 9       // units, counts, section headers, small values

        /// Narrowest the window goes. Matches `ContentView.minimumSize`, and is what the folded
        /// loudness row needs to hold its figures.
        static let floorWidth: CGFloat = 330
    }

    /// The source filter the full window's sidebar sets, shared and remembered.
    private func passes(_ s: DiscoveredStream) -> Bool {
        state.sourceFilter.map { s.description.source == $0 } ?? true
    }

    private var listening: [DiscoveredStream] {
        // With any auto-stop stopped, so the note is seen where the stream was playing.
        state.streams.filter { (state.isSubscribed($0.id) || state.autoStopped[$0.id] != nil) && passes($0) }
    }

    private var available: [DiscoveredStream] {
        state.streams.filter { !state.isSubscribed($0.id) && state.autoStopped[$0.id] == nil
                               && !state.ignoredStreams.contains($0.id) && passes($0) }
    }

    /// The compact window's source filter: small toggles, not a sidebar — one per kind found,
    /// and only once there is more than one kind to choose between.
    /// The compact window's stream filter: the same row as the full window's, compacted, with
    /// ‹ › when it does not fit — once there is more than one kind to choose between.
    @ViewBuilder private var sourceToggles: some View {
        if state.sourceCounts.count > 1 || state.sourceFilter != nil {
            SourceFilterRow(compact: true).padding(.bottom, 2)
        }
    }

    /// The Audio Unit's window opens at this width: the compact layout.
    static let pluginOpenWidth: CGFloat = 380

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if state.showSettings {
                // Same panes as the full window, picked from a row of icons: there is no room
                // for a sidebar at this width.
                SettingsSurface(compact: true)
            } else if let send = state.send, state.compactTab == 1 {
                sendTabs
                GrabberSendTab(send: send)
            } else {
                if state.send != nil { sendTabs }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        monitor
                        if state.showLoudness {
                            Divider()
                            loudnessSection
                        }
                        // No inserts inside a DAW: the host's own slots do that job.
                        if !AudioOutput.hostMode {
                            Divider()
                            insertsSection
                        }
                        Divider()
                        streamsSection
                    }
                }
            }
            Divider()
            footer
        }
        // **The width floor belongs here as well as on the window.** It was removed when a
        // 320-point `minWidth` was making the content overflow a narrower window — but the
        // overflow was the *mismatch*, not the minimum: the app uses
        // `.windowResizability(.contentMinSize)`, so with no `minWidth` here SwiftUI derives
        // the window's floor from whatever the content will squeeze to, and the window went
        // under 330 again. Same number in both places, so they cannot disagree.
        .frame(minWidth: Size.floorWidth, minHeight: 200)
        .background(state.surfaceWash(scheme))
    }

    /// Receive / Send: the monitor as it was, or the Sender's controls.
    private var sendTabs: some View {
        @Bindable var state = state
        return Picker("", selection: $state.compactTab) {
            Text("Receive").tag(0)
            Text("Send").tag(1)
        }
        .pickerStyle(.segmented).labelsHidden().controlSize(.small)
        .padding(.horizontal, 11).padding(.vertical, 5)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 7) {
            // Which app this is, as the full window's header says it; an identifier, not a control.
            AppEmblem(.grabber, size: 18, caption: .beside)
            // A menu, not a label: the interface was previously unchangeable here.
            InterfacePicker(showAddress: false)

            // The rate belongs beside the device it describes, as it does in the full window —
            // it used to sit down beside DIM and MONO, where it read as a property of the
            // monitor controls.
            HStack(spacing: 4) {
                OutputDeviceMenu {
                    Label(state.outputDeviceName,
                          systemImage: state.outputFallback ? "exclamationmark.triangle.fill" : "headphones")
                        .font(.system(size: Size.body))
                }
                Text(String(format: "%.4g kHz", state.outputRate / 1000))
                    .font(.system(size: 10)).monospacedDigit()
                    .foregroundStyle(state.outputRate == 48000 ? Color.secondary : Color.orange)
                // How many outputs the device has, which was nowhere in this window: the bus
                // menu says how many are in use, and this says how many there are to use.
                Text(verbatim: "\(state.outputChannels) ch")
                    .font(.system(size: 10)).monospacedDigit()
                    .foregroundStyle(Color.mutedLabel)
                    .fixedSize()
            }
            .help(tooltip("The output device the monitor bus plays out of, and the rate it is "
                        + "running at. AES67 is 48 kHz; at any other rate a sample-rate "
                        + "conversion sits in the path.",
                          now: "\(state.outputDeviceName) at "
                             + String(format: "%.4g kHz", state.outputRate / 1000)))

            Spacer(minLength: 4)

            // Inside a DAW the layout follows the plugin window's width instead.
            if !AudioOutput.hostMode {
            Button { state.viewMode = .full } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10))
            }
            .buttonStyle(.plain).foregroundStyle(Color.mutedLabel)
            .help("Back to the full window (⌥⌘C)")
            .accessibilityLabel("Switch to the full window")
            }

            Button { state.showSettings.toggle() } label: {
                Image(systemName: state.showSettings ? "gearshape.fill" : "gearshape")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(state.showSettings ? state.tintActive(on: scheme) : Color.secondary)
            .accessibilityLabel("Settings")
            .accessibilityValue(state.showSettings ? "open" : "closed")
            .help(state.showSettings ? "Back to the monitor (⌘,)" : "Settings (⌘,)")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
    }

    // MARK: - Monitor

    private var monitor: some View {
        VStack(alignment: .leading, spacing: 11) {
            // The peak figure, its label, the pinned loudness reading and the clip dot, in one
            // row. This was a `ViewThatFits` over four arrangements, for a window that went down
            // to 240 points; at the 330-point floor all four fit, and measuring four candidates
            // on every quarter-second update is the cost the many-streams
            // benchmark measured: it was most of the compact window's layout time.
            CompactPeakRow(readouts: state.readouts, label: true, pinned: true)

            // Horizontal bars rather than the panel's vertical pair: at this width there is far
            // more resolution to be had across the window than up it.
            HStack(spacing: 6) {
                // **One number decides the height of both columns.** Two bars in an 11-point
                // slot need 22 points; the frame gave them 18, so the lower bar lost four and
                // the meter looked cut off — which reads as a clipped meter rather than a
                // mis-sized frame. The labels take a whole slot each, so their centres land on
                // the bars' centres instead of two points above them.
                // One row per bus channel, not a hard-coded pair: this window was showing two
                // bars for a 7.1 bus and calling it the output.
                if let labels = meterLabels {
                    VStack(spacing: 0) {
                        ForEach(Array(labels.enumerated()), id: \.offset) { _, name in
                            Text(verbatim: name)
                                .font(.system(size: meterSlot >= 9 ? 8 : 7,
                                              weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.mutedLabel)
                                .frame(width: 13, height: meterSlot)
                        }
                    }
                }
                // **No `GeometryReader` here.** Measuring the available width and handing it
                // back as `length` derived the same geometry twice, and on a shrink the second
                // derivation lagged the first — the bars kept the old window's length and ran
                // past the edge. `MeterStrip.sizeThatFits` takes the width it is offered,
                // so the frame below is the only place the length is decided. `length` is the
                // fallback for a proposal that offers nothing, never the real layout.
                MeterStrip(count: state.busChannels, orientation: .horizontal,
                           thickness: meterBar, slot: meterSlot,
                           length: Size.floorWidth,
                           fps: state.meterRate,
                           paused: !state.metersActive,
                           level: { state.outputPeak($0) },
                           hold: { state.outputPeakHold })
                    .frame(maxWidth: .infinity)
                    .frame(height: meterSlot * CGFloat(state.busChannels))
                    // REAPER's look: its scale over the bars, ticks at the edges.
                    .overlay { if skin.style.scale == .between { ReaperScale(vertical: false) } }
            }

            if state.showLevelHistory { LevelHistoryStrip(height: 18) }

            HStack(spacing: 7) {
                Image(systemName: state.masterVolume > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                ResettableSlider(value: Bindable(state).masterVolume, defaultValue: 1,
                                 tint: state.tintActive)
                    .frame(height: 20)
                Text(verbatim: state.masterVolumeLabel)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Color.mutedLabel)
                    .frame(width: 46, alignment: .trailing)
            }
            .help(state.masterVolumeHelp)

            HStack(spacing: 6) {
                PillToggle(title: "DIM", isOn: Bindable(state).dimmed, tint: state.tintActive, help: "−20 dB")
                PillToggle(title: "MONO", isOn: Bindable(state).monoFold, tint: state.tintActive,
                           help: "Sum to mono for a phase check")
                Spacer(minLength: 0)
                // The bus width, in the space the sample rate used to take. Only where the
                // device offers a choice, as in the full window.
                if state.busWidthOptions.count > 1 {
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
                        // "2 of 16 ch" rather than "Stereo": in this window the interesting
                        // fact is how much of the device is in use, and "Stereo" hid it.
                        Text(verbatim: "\(state.busChannels) of \(state.outputChannels) ch")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(tooltip("How many of the device's outputs the app plays out of.",
                                  now: state.busChannels == 2
                                    ? "Stereo — wider streams fold down."
                                    : "\(state.busWidthLabel(state.busChannels)) of "
                                    + "\(state.outputChannels) available."))
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 12)
    }


    // MARK: - Folding sections
    //
    // Each section folds on its own and remembers itself. The summary beside a folded header is
    // the point of the design: folding something away should cost you the *detail*, not the
    // fact — a collapsed LISTENING still says how many, and a collapsed LOUDNESS still gives
    // all three figures, because they fit on one line when laid out across rather than down.

    private func sectionHeader<Summary: View>(_ title: String, open: Binding<Bool>,
                                              @ViewBuilder summary: () -> Summary) -> some View {
        HStack(spacing: 6) {
            // **Only the chevron and the title fold the section.** The summary beside them is
            // live data, and on the loudness row it is data you double-click to reset — so a
            // header that swallowed the whole row meant resetting a reading folded the section
            // instead.
            Button { open.wrappedValue.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: open.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.mutedLabel)
                        .frame(width: 8)
                    Text(verbatim: title)
                        .font(SignalPanel.headingFont)
                        .foregroundStyle(Color.mutedLabel)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tooltip("Folds this section away, or opens it. Only the name folds it — "
                        + "anything beside it belongs to the section.",
                          now: open.wrappedValue ? "Open." : "Folded."))
            Spacer(minLength: 8)
            if !open.wrappedValue { summary() }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
    }

    private var loudnessSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Loudness", open: Bindable(state).loudnessOpen) {
                // All three across, and only as many as fit: the row is the *summary*, so it
                // must never be the thing that forces the window wider. Three figures, then two,
                // then the one that moves — chosen from the room the row has, measured when the
                // window resizes, not by trying each layout on every update as `ViewThatFits` did
                // four times a second. Each figure has a fixed width, so the choice
                // holds whatever the readings say.
                CompactLoudnessSummary(readouts: state.readouts, which: summaryKeys)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { summaryRoom = $0 }
                // Same gesture as the block it summarises: double-click any figure to start
                // the measurement again (⇧⌘L does it too).
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { state.resetLoudness() }
                // No live figure in the tooltip: reading `readouts` here made the whole compact
                // window re-evaluate four times a second, and the figures are right beside it.
                .help("Short-term, windowed and integrated loudness against their targets. "
                    + "Double-click to reset the integrated and windowed readings (⇧⌘L).")
            }
            if state.loudnessOpen { loudness }
        }
    }

    @State private var summaryRoom: CGFloat = 0

    /// Three figures if they fit the row, then two, then one.
    private var summaryKeys: [String] {
        let fits = { (n: Int) in CGFloat(n) * CompactLoudnessSummary.itemWidth
                                 + CGFloat(n - 1) * CompactLoudnessSummary.spacing <= summaryRoom }
        return fits(3) ? ["S", "W", "I"] : fits(2) ? summaryPair : summaryLast
    }

    /// What the folded loudness row keeps as the width runs out.
    ///
    /// **The last figure standing is the pinned one.** Always shedding down to short-term made
    /// no sense when the reading pinned at the top of the window — and therefore the one being
    /// judged by — was integrated: the row would drop the figure you chose and keep one you
    /// did not.
    private var summaryLast: [String] {
        switch state.pinnedLoudness {
        case .window:            return ["W"]
        case .integrated:        return ["I"]
        case .shortTerm, .none:  return ["S"]
        }
    }

    /// With room for two, show the two that are **not** pinned: the pinned figure is already
    /// on the line above at twice the size, and spending a third of a narrow row repeating it
    /// is the one thing the summary should not do.
    private var summaryPair: [String] {
        switch state.pinnedLoudness {
        case .shortTerm:        return ["W", "I"]
        case .window:           return ["S", "I"]
        case .integrated:       return ["S", "W"]
        case .none:             return ["S", "I"]
        }
    }

    private var insertsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Inserts", open: Bindable(state).insertsOpen) {
                let loaded = state.slotInfo.compactMap { $0 }
                Text(verbatim: loaded.isEmpty
                     ? "none"
                     : loaded.map(\.name).joined(separator: ", "))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mutedLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if state.insertsOpen { inserts }
        }
    }

    private var streamsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Listening", open: Bindable(state).streamsOpen) {
                // Names what is playing rather than counting it: the footer already carries
                // "3 of 6", and a summary that repeats another line earns nothing.
                Text(verbatim: listening.isEmpty
                     ? "nothing"
                     : listening.count > 1
                        ? "\(listening[0].description.name)  +\(listening.count - 1)"
                        : listening[0].description.name)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mutedLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if state.streamsOpen { streams }
        }
    }

    // MARK: - Loudness

    private var loudness: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Spacer()
                Text(verbatim: "\(state.lufsWindowSeconds) s · target \(CompactPeakRow.target(state.targetIntegrated))")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Color.mutedLabel)
                Button { state.resetLoudness() } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 9, weight: .bold))
                        .accessibilityLabel("Reset the loudness measurement")
                }
                .buttonStyle(.plain).foregroundStyle(Color.mutedLabel)
                .help("Reset the integrated and window readings (⇧⌘L)")
            }
            LoudnessBlock(readouts: state.readouts)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
    }

    // MARK: - Inserts

    private var inserts: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Both slots, filled or not, exactly as the full window shows them. The section
            // used to appear only once something was loaded, which meant the compact window
            // could show an insert and never add one.
            // **The full window's slot, not a copy of it.** The two had drifted — the
            // compact one showed the dry/wet as a bare percentage, with nothing to set it by —
            // and two windows showing the same three slots should look like one feature.
            ForEach(0..<state.slotInfo.count, id: \.self) { slot in
                InsertSlotView(slot: slot)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
    }

    // MARK: - Streams

    private var streams: some View {
        VStack(alignment: .leading, spacing: 6) {
            sourceToggles
            if state.streams.isEmpty {
                // The first-launch guide, cut to what fits — where it is listening,
                // the way to the full list of sources, and the SDP button.
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "Nothing found on \(state.selectedInterface) yet.")
                        .font(.system(size: 11, weight: .medium))
                    Text("AES67, RAVENNA and Dante in AES67 mode appear by themselves. VBAN, "
                       + "internet radio and the rest are switched on in Settings.")
                        .font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Button("Sources…") {
                            state.settingsPane = SettingsPane.sources.rawValue
                            state.showSettings = true
                        }
                        Button("SDP Address…") { state.addStreamRequested = true }
                    }
                    .controlSize(.small)
                }
            } else if listening.isEmpty {
                Text("Nothing selected yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mutedLabel)
            } else {
                // Flat, with a rule between them, as the full window's list is: the
                // secondary colour is on the stop button and the bus menu, not washed over the row.
                VStack(spacing: 0) {
                    ForEach(listening) { stream in
                        CompactStreamRow(stream: stream.description)
                        if stream.id != listening.last?.id { Divider().opacity(0.5) }
                    }
                }
            }

            if !available.isEmpty {
                Button { withAnimation { showAvailable.toggle() } } label: {
                    HStack(spacing: 4) {
                        Text(verbatim: "\(available.count) available")
                            .font(.system(size: Size.label))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(showAvailable ? 90 : 0))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.mutedLabel)
                .padding(.top, 2)

                if showAvailable {
                    ForEach(available) { stream in
                        CompactStreamRow(stream: stream.description)
                    }
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if state.soloed != nil {
                Text("Solo").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(state.tintSoloText)
                Button("Clear") { state.soloed = nil }.controlSize(.small)
            }
            // The way to add a stream by hand, always in reach here too.
            Button { state.addStreamRequested = true } label: {
                Image(systemName: "plus").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(Color.mutedLabel)
            .help(state.webStreamsEnabled ? "Add a stream: SDP or an internet stream" : "SDP Address…")
            .accessibilityLabel("Add a stream by hand")
            Spacer()
            if state.previewSendLayout != nil { SendingIndicator(targets: 2) }
            // Each tab's footer tells of the other: what is sending while
            // receiving, what is received while on Send.
            if state.send != nil && state.compactTab == 1 {
                ReceivingPill { state.compactTab = 0 }
            } else {
                if let send = state.send { SendPillButton(send: send) { state.compactTab = 1 } }
                Text(verbatim: "\(state.subscribed.count) of \(state.streams.count)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Color.mutedLabel)
                if !state.subscribed.isEmpty {
                    Button("Stop all") { state.unsubscribeAll() }.controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
    }
}

/// One stream in the compact window: play/stop, name, level, and mute/solo once it is running.
private struct CompactStreamRow: View {
    @Environment(\.skin) private var skin
    @Environment(AppState.self) var state
    @Environment(\.colorScheme) private var scheme
    let stream: StreamDescription

    private var active: Bool { state.isSubscribed(stream.id) }
    private var receiving: Bool { state.isReceiving(stream.id) }

    private var silenced: Bool {
        state.isMuted(stream.id) || (state.soloed != nil && state.soloed != stream.id)
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { state.toggle(stream) } label: {
                PlayStopIcon(active: active, tint: state.tintActive(on: scheme), size: 17)
                    .accessibilityLabel(active ? "Stop listening to \(stream.name)"
                                               : "Listen to \(stream.name)")
            }
            .buttonStyle(.plain)
            .help(active ? "Stop listening" : "Listen")

            // **Two lines, identity above state.** Everything used to share one line beside a
            // two-line name block — dot, name, level, count, mix menu, mute, solo — six things
            // competing for 320 points. The name now has the width to itself and the controls
            // sit together on the line below, where they line up across rows.
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.tint(for: stream.source))
                        .frame(width: 5, height: 5)
                    Text(stream.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    if active, state.hasChannelSolo(stream.id) { ChannelSoloBadge(stream: stream) }
                    if stream.source == .vban { ConnectionBadge(address: stream.originAddress, encrypted: state.isEncryptedLink(stream)) }
                    else if stream.source != .web, RemoteAddresses.isRemote(stream.originAddress) { RemoteBadge() }
                    Spacer(minLength: 4)
                    // The facts about the stream ride with its name; the second line is for
                    // the meter and the controls. Putting the channel count and the warning
                    // down there with everything else is what made "no packets" wrap to three
                    // lines at 320 points.
                    Text(verbatim: "\(stream.channels) ch")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(Color.mutedLabel)
                        .fixedSize()
                    if !active, let reason = state.joinFailures[stream.id] {
                        Label("Can't join", systemImage: "xmark.octagon.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.red)
                            .fixedSize()
                            .help(reason + " Press play to try again.")
                    }
                    if !active, let note = state.autoStopNote(stream.id) {
                        Label("Timed out", systemImage: "timer")
                            .font(.system(size: 10))
                            .foregroundStyle(skin.style.warning ?? .orange)
                            .fixedSize()
                            .help(note)
                    }
                    if active, !receiving, state.isGone(stream.id) {
                        // Its sender has left (the full window lists it under Gone).
                        Label("Gone", systemImage: "moon.zzz")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.mutedLabel)
                            .fixedSize()
                            .help("No audio and no announcement for a while. It plays again if it comes back, "
                                  + "and stops by itself after five minutes.")
                    } else if active, !receiving {
                        Label("No packets", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(skin.style.warning ?? .orange)
                            .fixedSize()
                    }
                }
                if active {
                    HStack(spacing: 6) {
                        // Every channel, as the full window's rows show them, with
                        // the same red surround when muted.
                        RowChannelMeters(stream: stream, silenced: silenced, length: 60, slim: true)
                            .frame(width: 66)
                        Spacer(minLength: 4)
                        if stream.channels > 1 {
                            StreamMixMenu(stream: stream, size: 9)
                        }
                        PillToggle(title: "M",
                                   isOn: Binding(get: { state.isMuted(stream.id) },
                                                 set: { _ in state.toggleMute(stream.id) }),
                                   tint: skin.style.mute ?? .red, help: "Mute this stream")
                        PillToggle(title: "S",
                                   isOn: Binding(get: { state.soloed == stream.id },
                                                 set: { _ in state.toggleSolo(stream.id) }),
                                   tint: skin.style.solo ?? state.tintSolo, help: "Listen to this stream alone")
                    }
                }
                // Detailed adds where each stream comes from — it changed nothing here before
                // and two Senders' "Mac Audio" read the same.
                if !active || state.detailed {
                    Text(verbatim: state.detailed && !stream.originAddress.isEmpty
                         ? "\(stream.source.label) · from \(stream.originAddress)" : stream.source.label)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.mutedLabel)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
    }
}

/// The peak figure, its label and the pinned loudness reading.
///
/// **Observes `Readouts` directly.** Reading `state.readouts.…` from a view that observes only
/// `AppState` looks right and is not: `Readouts` is its own `ObservableObject`, so the figures
/// then refresh when something *else* in `AppState` publishes rather than when they change. In
/// the compact window that read as the loudness numbers freezing after a reset — they were
/// waiting for an unrelated change to drag them along. The full window never had it, because
/// `LoudnessBlock` takes the object.
private struct CompactPeakRow: View {
    @Environment(AppState.self) var state
    var readouts: Readouts
    let label: Bool
    let pinned: Bool

    private var pinnedReading: LoudnessReading? {
        // Off in Settings → Loudness means off everywhere, including here.
        guard state.showLoudness else { return nil }
        switch state.pinnedLoudness {
        case .none:       return nil
        case .shortTerm:  return readouts.shortTerm
        case .window:     return readouts.window
        case .integrated: return readouts.integrated
        }
    }

    private var pinnedTarget: Double {
        switch state.pinnedLoudness {
        case .shortTerm:        return state.targetShortTerm
        case .window:           return state.targetWindow
        case .integrated, .none: return state.targetIntegrated
        }
    }

    /// A target as a heading shows it: whole numbers without the point, and the same minus as
    /// the readings beside it.
    static func target(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(verbatim: readouts.outputMax)
                    .font(.system(size: 30, weight: .light))
                    .monospacedDigit()
                    .fixedSize()
                if label {
                    Text(verbatim: "dBFS max")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.mutedLabel)
                        .fixedSize()
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { state.clearClip() }
            .help("Highest output level since it was last reset. Double-click to reset it "
                + "and start logging a new maximum.")

            if pinned, let reading = pinnedReading {
                Spacer(minLength: 6)
                // The figure large, and under it what it means — "+0.2 against −23" —
                // rather than a bare signed number beside a badge.
                VStack(alignment: .trailing, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(verbatim: reading.value)
                            .font(.system(size: 30, weight: .light))
                            .monospacedDigit()
                            .foregroundStyle(reading.provisional ? Color.secondary : Color.primary)
                            .fixedSize()
                        Text(verbatim: state.pinnedLoudness.badge)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.mutedLabel)
                            .fixedSize()
                    }
                    if let delta = reading.delta?.trimmingCharacters(in: .whitespaces), !delta.isEmpty {
                        Text(verbatim: "\(delta) against \(Self.target(pinnedTarget))")
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(reading.colour)
                            .fixedSize()
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { state.resetLoudness() }
                .help(tooltip("The loudness reading pinned beside the peak — chosen in "
                            + "Settings → View. Double-click to reset the measurement (⇧⌘L). "
                            + "The full set is in the loudness section.",
                              now: "\(state.pinnedLoudness.label): \(reading.value) LUFS"))
            }

            Spacer(minLength: 4)
            Button { state.clearClip() } label: {
                Circle()
                    .fill(state.clipped ? Color.red : Color.primary.opacity(0.12))
                    .frame(width: 9, height: 9)
            }
            .buttonStyle(.plain)
            .help(state.clipped
                  ? "Clipped — click to reset the maximum and the clip indicator"
                  : "Click to reset the maximum")
        }
    }
}

/// The folded loudness row: a label, a figure and its deviation, for each reading asked for.
/// Observes `Readouts` for the reason given on `CompactPeakRow`.
struct CompactLoudnessSummary: View {
    @Environment(AppState.self) var state
    var readouts: Readouts
    let which: [String]

    /// Room for "S −21.2 +1.8" at these sizes, fixed so the row's layout cannot move with the
    /// figures.
    static let itemWidth: CGFloat = 78
    static let spacing: CGFloat = 9

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(which, id: \.self) { key in
                let reading = key == "S" ? readouts.shortTerm
                            : key == "W" ? readouts.window
                                         : readouts.integrated
                HStack(spacing: 3) {
                    Text(verbatim: key)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.mutedLabel)
                    Text(verbatim: reading.value)
                        .font(.system(size: 12))
                        .monospacedDigit()
                    Text(verbatim: reading.delta?.trimmingCharacters(in: .whitespaces) ?? "—")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(reading.colour)
                }
                .lineLimit(1)
                .frame(width: Self.itemWidth, alignment: .trailing)
            }
        }
    }
}
