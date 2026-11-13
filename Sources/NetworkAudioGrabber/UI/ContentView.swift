import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) var state
    @Environment(\.colorScheme) private var scheme
    @State private var showLog = false
    @State private var showManualSDP = false
    @State private var connectingSender = false
    @State private var askingTrust = false
    @State private var columnHeight: CGFloat = 600
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // **The shaper is a sibling, not a background.**
        //
        // It used to hang off `.background` on the `Group` below — and a `switch` changes that
        // view's structural identity between its branches, so every switch between the full and
        // compact windows tore the shaper down and built a new one. A new one has no memory of
        // which mode was applied last, so it took its "first layout of a freshly opened window"
        // path every time: adopt whatever size the window happens to be, record *that* as the
        // incoming mode's size, and resize nothing. Which is exactly what it looked like — the
        // compact window arriving at the full window's width, with its remembered width
        // overwritten to match.
        //
        // As a ZStack child of its own it keeps its identity across the switch, because its
        // position in the tree never changes. Three earlier attempts at this bug were all in
        // `apply`'s mode-change branch, which was never running.
        ZStack {
            // Not inside a DAW: the host owns the plugin's window and its size.
            if !AudioOutput.hostMode {
            WindowShaper(mode: state.viewMode,
                         minimumSize: minimumSize,
                         targetSize: state.windowSize(for: state.viewMode),
                         snapToMinimumHeight: state.viewMode == .compact,
                         memory: state.windowShape,
                         onSizeChange: { mode, size in state.rememberWindowSize(mode, size) })
                .frame(width: 0, height: 0)
            }
            Group {
                if AudioOutput.hostMode {
                    // Inside a DAW the host sets the window's size: the full layout when it fits,
                    // the compact one when it does not, rather than a full layout cut off on every
                    // side. The width offered, measured by
                    // a GeometryReader — the content's own width is always the full layout's.
                    GeometryReader { geo in
                        Group {
                            if geo.size.width >= Self.fullMinimumWidth(for: state) { fullWindow } else { CompactView() }
                        }
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    }
                } else {
                    switch state.viewMode {
                    case .full:    fullWindow
                    case .compact: CompactView()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // A skin that is light or dark by nature (Audio Hijack's, Audacity's) says which.
        .preferredColorScheme(state.skin.style.appearance ?? state.appearance.colorScheme)
        // Switches, sliders and the like in the theme's colour, as in the Sender, rather than
        // the system accent.
        .tint(state.tintActive)
        // Every switch in the scheme's colour: macOS 26 ignores `.tint` on its own.
        .toggleStyle(ThemedSwitchStyle(tint: state.tintActive))
        // The skin: SwiftUI views read it from here; the AppKit meters and sliders from
        // `Skin.current`, kept in step as the scheme changes (it is idempotent).
        .environment(\.skin, currentSkin)
        .sheet(isPresented: $showManualSDP) { ManualSDPSheet() }
        // In a DAW there is no window to open, so the guide is a sheet — with the same first
        // question and Remote link as the app's.
        .sheet(isPresented: $connectingSender) { PluginConnectSheet().environment(state) }
        .trustNotice(isPresented: $askingTrust) { showConnectGuide() }
        .onChange(of: state.addStreamRequested) { _, asked in
            guard asked else { return }
            state.addStreamRequested = false
            state.showSettings = false
            showManualSDP = true
        }
        .onChange(of: state.connectGuideRequested) { _, asked in
            guard asked else { return }
            state.connectGuideRequested = false
            openConnectGuide()
        }
    }

    /// The Receive / Send window, after the notice that VBAN is not encrypted unless that was
    /// turned off. On the tab `state.connectTab` names.
    private func openConnectGuide() {
        if UserDefaults.standard.bool(forKey: TrustNotice.skipKey) { showConnectGuide() } else { askingTrust = true }
    }

    /// Its own window in the app; a sheet inside a DAW, which has no scenes to open.
    private func showConnectGuide() {
        if AudioOutput.hostMode || state.send == nil { connectingSender = true } else { openWindow(id: ConnectSendWindow.id) }
    }

    /// The full window's floor width for what it is showing: the list, the signal panel and
    /// the source sidebar when each is on.
    static func fullMinimumWidth(for state: AppState) -> CGFloat {
        // Detailed adds the jitter column, which squeezed the stream names once the source
        // sidebar took its share.
        // 780, up from 760 when the Source column widened for "DANTE (AES67)", so
        // names keep their room at the narrowest.
        780 + (state.detailed ? StreamRowView.Column.jitter + 7 : 0)
            + (state.showPanel ? SignalPanel.width + 1 : 0)
            + (state.showSourceBar && !state.showSettings && state.sourceFilterPlacement == .sidebar
               ? SourceSidebar.width + 1 : 0)
    }

    private var minimumSize: CGSize { Self.minimumSize(for: state) }

    private var currentSkin: Skin {
        let skin = state.skin
        if Skin.current != skin { Skin.current = skin }
        return skin
    }

    /// The window's floor for the mode it is in. Static so the render harness can shoot every
    /// window at exactly the size a user can shrink it to.
    static func minimumSize(for state: AppState) -> CGSize {
        switch state.viewMode {
        case .full:
            // Width: the row's fixed columns — to-bus, level, trim, mute/solo, source, jitter —
            // plus the panel. 1000 was from before those columns existed, and it disagreed with
            // the figure on `fullWindow` itself; a split like that is what lets a window be
            // dragged narrower than its own content.
            //
            // The list's columns need ~760; the panel is `SignalPanel.width` beside it (272, down from 352).
            //
            // Height: enough that the output's readings still fit beside its meters. The output
            // is the flexible section, so a short window takes the space out of its meters.
            let panel = SignalPanel.minimumWindowHeight(slots: state.slotInfo.count,
                                                        showMix: state.showInsertMix,
                                                        showLoudness: state.showLoudness,
                                                        showHistory: state.showLevelHistory,
                                                        insertsOpen: state.panelInsertsOpen)
            // The Send section along the bottom takes its share below the list.
            return CGSize(width: Self.fullMinimumWidth(for: state),
                          height: (state.showPanel ? max(520, panel) : 520) + sendFloor(for: state))
        case .compact:
            // The floor follows the folds, and **the folded headers are part of it**: the first
            // version counted only the open sections, so shutting everything gave a floor of
            // 210 for 300 points of content and the fold headers scrolled out of sight — the
            // one thing that must always be reachable.
            //
            //   header 32 · peak 34 · meters 22 · level 22 · DIM/MONO 26 · padding 24 ·
            //   spacing 44 · three fold headers 81 · dividers 3 · footer 32
            //
            // 300 was the first guess and it was short by about the monitor block's own
            // spacing, which chopped the last fold header and put a scroll bar in a window
            // that had nothing to scroll.
            var height = 322.0
            // The Receive / Send tabs under the header.
            if state.send != nil { height += 30 }
            // A wide bus makes the monitor strip taller — one meter row a channel — and the
            // floor has to follow, or the window shrinks under its own meters.
            height += CompactView.meterBlockHeight(for: state.busChannels) - 22
            if state.showLoudness && state.loudnessOpen { height += 110 }   // block + window row
            if state.showLevelHistory { height += 44 }
            // Per slot, not a number that happened to be two of them: the third slot would
            // otherwise hang below the floor and put a scroll bar in the compact window.
            if state.insertsOpen { height += CGFloat(state.slotInfo.count) * 39 }
            if state.streamsOpen {
                // Enough for what is playing, capped: past three rows the list scrolls rather
                // than dictating how tall the window has to be.
                // 52 a row, not 44: the rows became two lines and the floor was still
                // measured against the one-line version, so three streams came up ~30 short.
                height += 40 + 52 * Double(min(max(state.subscribed.count, 1), 3))
                // The source toggles above the list, once there is more than one kind.
                if state.sourceCounts.count > 1 || state.sourceFilter != nil { height += 20 }
            }
            // Wide enough for the folded loudness row to hold all three figures, which is the
            // widest thing that has to fit: below this the row starts shedding readings, and a
            // floor that hides data by default is the wrong floor. 240 was too mean — it left
            // the header stacking "48 kHz" vertically.
            return CGSize(width: 330, height: height)
        }
    }

    /// What the Send section adds to the full window's floor: its folded line, or its least
    /// open height, and its handle.
    static func sendFloor(for state: AppState) -> CGFloat {
        guard state.send != nil, !state.showSettings else { return 0 }
        return 7 + (state.sendOpen ? SendBottomSection.minimumOpen : SendBottomSection.headerHeight)
    }

    private var fullWindow: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            banners
            HStack(spacing: 0) {
                // Settings has its own sidebar, so this one steps aside while it is open.
                if state.showSourceBar && !state.showSettings && state.sourceFilterPlacement == .sidebar {
                    SourceSidebar()
                    Divider()
                }
                VStack(spacing: 0) {
                    if state.showSettings { SettingsSurface() } else { content }
                    if let layout = state.previewSendLayout, layout.hasPrefix("strip") {
                        Divider()
                        SendStripMock(open: layout == "strip-open")
                    }
                    if let layout = state.previewSendLayout, layout.hasPrefix("bottom") {
                        SendBottomMock(open: layout == "bottom-open")
                    }
                    // Send, along the bottom (not while Settings has the column).
                    if let send = state.send, !state.showSettings, state.previewSendLayout == nil {
                        Divider()
                        SendBottomSection(send: send, columnHeight: columnHeight)
                    }
                    Divider()
                    statusBar
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { columnHeight = $0 }
                if state.showPanel {
                    Divider()
                    SignalPanel()
                }
            }
            if showLog {
                Divider()
                LogPane(activity: state.activity)
            }
        }
        .frame(minWidth: Self.fullMinimumWidth(for: state), minHeight: 520 + Self.sendFloor(for: state))
        .background(state.surfaceWash(scheme))
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            AppEmblem(.grabber, size: 22, caption: .beside)
            Divider().frame(height: 18)
            InterfacePicker()

            Divider().frame(height: 14)

            // The output device, chosen here or in Settings → Output.
            // A menu keeps only its label's text, so the rate sits beside it.
            HStack(spacing: 5) {
                OutputDeviceMenu {
                    Label(state.outputDeviceName,
                          systemImage: state.outputFallback ? "exclamationmark.triangle.fill" : "headphones")
                        .font(.system(size: 11))
                }
                Text(String(format: "%.4g kHz", state.outputRate / 1000))
                    .font(.system(size: 10)).monospacedDigit()
                    .foregroundStyle(state.outputRate == 48000 ? Color.secondary : Color.orange)
            }
            .fixedSize()
            .help(state.outputFallback
                  ? "\(state.outputDeviceChosenName) isn't connected: playing on the system default until it's back."
                  : (state.outputDeviceUID == nil ? "The output device: the system default, following the Mac's setting. Click to choose another."
                                                  : "The output device chosen for the Grabber. Click to change it."))

            Spacer(minLength: 8)


            Button { state.showSourceBar.toggle() } label: {
                Image(systemName: "sidebar.left").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(state.showSourceBar ? state.tintActive(on: scheme) : Color.secondary)
            .help(tooltip("The source sidebar: show every kind of stream, or only one — RAVENNA, "
                        + "Dante, VBAN and the rest — when the list gets long. The choice is remembered.",
                          now: state.showSourceBar
                            ? "Shown, " + (state.sourceFilter.map { "showing \(SourceSidebar.name($0)) only." } ?? "showing all streams.")
                            : "Hidden."))
            .accessibilityLabel("Source sidebar")
            .accessibilityValue(state.showSourceBar ? "shown" : "hidden")

            Button { state.showPanel.toggle() } label: {
                Image(systemName: state.showPanel ? "sidebar.trailing" : "sidebar.right")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(state.showPanel ? state.tintActive(on: scheme) : Color.secondary)
            .help(tooltip("The signal panel: the whole monitor path top to bottom — every "
                        + "input channel, the inserts, the output meters and the loudness "
                        + "readings.",
                          now: state.showPanel ? "Shown." : "Hidden."))
            .accessibilityLabel("Signal panel")
            .accessibilityValue(state.showPanel ? "shown" : "hidden")

            // The full window only, inside a DAW: the host sizes the plugin's window.
            if !AudioOutput.hostMode {
            Button { state.viewMode = .compact } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(Color.mutedLabel)
            .help(tooltip("Switches to the compact window — the same controls in a strip "
                        + "narrow enough to leave beside something else. ⌥⌘C either way, and "
                        + "each window remembers its own size.",
                          now: "In the full window."))
            .accessibilityLabel("Switch to the compact window")
            }

            Button { state.showSettings.toggle() } label: {
                Image(systemName: state.showSettings ? "gearshape.fill" : "gearshape")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(state.showSettings ? state.tintActive(on: scheme) : Color.secondary)
            .help(state.showSettings ? "Back to the streams (⌘,)" : "Settings (⌘,)")
            .accessibilityLabel("Settings")
            .accessibilityValue(state.showSettings ? "open" : "closed")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)          // 44 points with the 22-point emblem, as the Sender's
    }

    /// The filter and ACTIVE: they act on the stream list, so they sit on the list bar rather
    /// than in the header beside the window's own controls.
    @ViewBuilder
    private var listFilters: some View {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                TextField("Filter", text: Bindable(state).searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .frame(width: 130)
                if !state.searchText.isEmpty {
                    Button { state.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 9))
                    }
                    .buttonStyle(.plain).foregroundStyle(Color.mutedLabel)
                    .accessibilityLabel("Clear the filter")
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.06)))

            PillToggle(title: "ACTIVE", isOn: Bindable(state).showActiveOnly, tint: state.tintActive,
                       help: tooltip("Filters the list to the streams you have joined, so a "
                                   + "network announcing dozens of flows stays readable. It "
                                   + "changes nothing about what is playing.",
                                     now: state.showActiveOnly
                                        ? "ON — showing \(state.subscribed.count) joined of "
                                        + "\(state.streams.count) discovered."
                                        : "Off — showing all \(state.streams.count) discovered."))

    }

    /// A bar over the stream list holding what acts on the list —
    /// its count, the filter and ACTIVE — with the column titles under it.
    private var listBar: some View {
        HStack(spacing: 8) {
            // "Receive", beside the Send section below.
            Text("Receive").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.mutedLabel)
            Text(verbatim: state.streams.isEmpty ? "none yet"
                           : "\(state.subscribed.count) playing of \(state.streams.count)")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(Color.mutedLabel)
            Spacer()
            listFilters
            // What adds to the list sits on it too, and is always there — not only on the empty
            // screen's guide: a Sender over VBAN, and a stream by its SDP or web address.
            Button { state.connectTab = 0; openConnectGuide() } label: {
                Label(state.send != nil || state.previewSendLayout == "window" ? "Connect / Send…" : "Connect…",
                      systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered).controlSize(.small)
            .help(state.send != nil
                  ? "Receive from Network Audio Sender, or send this Mac's audio to other receivers."
                  : "Steps for Network Audio Sender on the same network, over VBAN, and the other ways to connect.")
            Button { showManualSDP = true } label: {
                Label(state.webStreamsEnabled ? "Add stream…" : "SDP Address…", systemImage: "plus")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }


    // MARK: - Banners

    @ViewBuilder
    private var banners: some View {
        if state.danteNeedsAES67 {
            banner(icon: "exclamationmark.triangle.fill", tint: .sourceDante,
                   text: "\(String(state.danteDevices.count)) Dante device(s) found, but none are publishing AES67. "
                       + "In Dante Controller: enable AES67 mode on the device, then create a multicast "
                       + "flow with \u{201C}AES67 flow\u{201D} ticked — flows can take up to 30 s to appear. "
                       + "Note that Dante Virtual Soundcard and Dante Via cannot do AES67 at all.")
        }
    }

    private func banner(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(tint)
            Text(text).font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(tint.opacity(0.10))
    }

    // MARK: - Stream list

    @ViewBuilder
    private var content: some View {
        let visible = state.visibleStreams
        // The column titles stay up with nothing under them, so the window has the same shape
        // before the first stream arrives as after — they used to appear with it.
        listBar
        // The stream filter as a row, when it is not the sidebar (Settings → View; always in
        // the Audio Unit).
        if state.showSourceBar && state.sourceFilterPlacement == .row {
            SourceFilterRow().padding(.horizontal, 12).padding(.top, 6)
        }
        columnTitles
        Divider()
        if visible.isEmpty && state.ignoredPresent.isEmpty && state.gonePresent.isEmpty {
            emptyState
        } else {
            ScrollView {
                // Flat rows with hairlines between them, not cards.
                LazyVStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { i, stream in
                        StreamRowView(stream: stream.description)
                        // Where an open row meets the next, the hairline alone vanished against
                        // the open row's ground: see `OpenRowEdge`.
                        let nextOpen = i + 1 < visible.count && state.isOpen(visible[i + 1].id)
                        OpenRowEdge(touchesOpen: state.isOpen(stream.id) || nextOpen)
                    }
                    if !state.gonePresent.isEmpty { GoneSection() }
                    if !state.ignoredPresent.isEmpty { IgnoredSection() }
                }
            }
            .scrollContentBackground(.hidden)
            // A stream that has been filtered out, stopped or has left the network cannot stay
            // selected: the detail would be of something the list is no longer showing.
            .onChange(of: visible.map(\.id)) { _, ids in
                let shown = Set(ids)
                if !state.openStreamIDs.isSubset(of: shown) { state.openStreamIDs.formIntersection(shown) }
            }
        }
    }

    /// Names for the columns the rows line up in, in sentence case over their columns.
    /// The Connect button that sat among them is in the status bar now, which is where a way to
    /// add to the list belongs rather than in its column headings.
    private var columnTitles: some View {
        HStack(spacing: 7) {
            Color.clear.frame(width: StreamRowView.Column.star, height: 1)
            Color.clear.frame(width: StreamRowView.Column.play, height: 1)
            Text("Stream").frame(maxWidth: .infinity, alignment: .leading)
            Text("Level")
                .frame(width: StreamRowView.Column.meter, alignment: .leading)
            Text("Bus")
                .frame(width: StreamRowView.Column.mix, alignment: .leading)
            // Inset to where the slider's track begins, not its frame, so it sits over the track.
            Text("Trim").padding(.leading, 7)
                .frame(width: StreamRowView.Column.trim + 7 + StreamRowView.Column.gain,
                       alignment: .leading)
            Text("M / S")
                .frame(width: StreamRowView.Column.states, alignment: .leading)
            Text("Source")
                .frame(width: StreamRowView.Column.chips, alignment: .leading)
            Text("Status")
                .frame(width: StreamRowView.Column.status, alignment: .leading)
            if state.detailed {
                Text("Jitter")
                    .frame(width: StreamRowView.Column.jitter, alignment: .trailing)
            }
            Color.clear.frame(width: 15, height: 1)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Color.mutedLabel)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var emptyState: some View {
        if state.streams.isEmpty {
            // Scrolls: the whole guide is taller than the window's 520-point floor, and without
            // this it pushed the header out of the top of the window.
            ScrollView { welcomeGuide }
        } else {
            plainEmptyState
        }
    }

    /// First launch on a quiet network says what the Grabber can
    /// pick up and how, each with the one button that does it, instead of only "Listening…".
    private var welcomeGuide: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: "Listening on \(state.selectedInterface)…")
                        .font(.system(size: 15, weight: .semibold))
                }
                Text("Nothing has arrived yet. The Grabber plays these kinds of stream:")
                    .font(.system(size: 12)).foregroundStyle(Color.mutedLabel)
                Text("This list is kept in Settings → Sources.")
                    .font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
            }
            SourcesGuide()
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private var plainEmptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: state.streams.isEmpty ? "dot.radiowaves.left.and.right" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 28)).foregroundStyle(Color.mutedLabel)
            Text(state.streams.isEmpty ? "Listening for announcements…" : "Nothing matches the filter")
                .font(.callout).foregroundStyle(Color.mutedLabel)
            if state.streams.isEmpty {
                Text("Streams appear as senders announce themselves. Check that the interface above "
                   + "is the one on the audio network.")
                    .font(.caption2).multilineTextAlignment(.center).foregroundStyle(Color.mutedLabel)
                    .frame(maxWidth: 360)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            if state.soloed != nil {
                Text("Solo").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(state.tintSoloText)
                Button("Clear") { state.soloed = nil }.controlSize(.small)
            }
            Spacer()
            if state.previewSendLayout != nil { SendingIndicator(targets: 2) }
            if let send = state.send { SendPillButton(send: send) { state.sendOpen = true } }
            if !state.subscribed.isEmpty {
                Button("Stop all") { state.unsubscribeAll() }.controlSize(.small)
            }
            Button { withAnimation { showLog.toggle() } } label: {
                Image(systemName: showLog ? "chevron.down.square" : "text.alignleft").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(Color.mutedLabel)
            .help("Activity log")
            .accessibilityLabel("Activity log")
            .accessibilityValue(showLog ? "shown" : "hidden")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

/// One insert slot: plugin chooser, bypass, and its editor window.
struct InsertSlotView: View {
    @Environment(AppState.self) var state
    let slot: Int

    private var info: PluginInfo? { state.slotInfo(slot) }

    private var failure: String? {
        state.slotFailure.indices.contains(slot) ? state.slotFailure[slot] : nil
    }

    var body: some View {
        if let failure {
            FailedInsertRow(menu: AnyView(InsertPluginMenu(slot: slot)), reason: failure,
                            reload: { state.reloadPlugin(slot: slot) })
        } else {
            VStack(alignment: .leading, spacing: 4) {
                chooser
                // Only worth the room once there is something to blend.
                if info != nil, state.showInsertMix { mixRow }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        }
    }

    private var chooser: some View {
        HStack(spacing: 3) {
            InsertPluginMenu(slot: slot)
            // Deliberately *not* fixed: the plugin name is the thing that should truncate when
            // the row is tight, rather than the controls that act on it.
            .layoutPriority(-1)

            Spacer(minLength: 0)

            if info != nil {
                if state.slotIsRefused(slot) {
                    Chip(text: "needs \(state.busChannels) ch", tint: .orange, filled: true)
                        .help(tooltip("This plugin will not take a bus this wide, so it is held "
                                    + "out of the chain entirely rather than applied to part of "
                                    + "it — what you hear would not be what the meters show. "
                                    + "Most EQ and room-correction Audio Units are stereo-only.",
                                      now: "Out of circuit. Narrow the output bus beside the "
                                         + "meters, or use a plugin that handles "
                                         + "\(state.busChannels) channels."))
                }
                if state.slotIsLive(slot) {
                    InsertThroughMeter(paused: !state.metersActive) { [state, slot] out in
                        state.slotLevel(slot, output: out)
                    }
                }
                PillToggle(title: "BYP",
                           isOn: Binding(get: { state.slotIsBypassed(slot) },
                                         set: { _ in state.toggleBypass(slot: slot) }),
                           tint: .orange,
                           help: bypassHelp)
                PillToggle(title: "Δ",
                           isOn: Binding(get: { state.deltaSlot == slot },
                                         set: { _ in state.toggleDelta(slot: slot) }),
                           tint: .delta,
                           help: deltaHelp)
                    .disabled(state.slotIsBypassed(slot) || !state.slotIsLive(slot))
                    .opacity(state.slotIsBypassed(slot) || !state.slotIsLive(slot) ? 0.4 : 1)
                InsertEditorButton(slot: slot)
            }
        }
    }

    /// **Bypass** and **delta** answer different questions, and the tooltips say which.
    /// Processed = unprocessed + the difference: BYP gives the first term, Δ the second, and
    /// normal playback the sum. That distinction is not obvious from two adjacent pills, so it
    /// is spelled out where someone hovering will find it.
    private var bypassHelp: String {
        tooltip("Bypass — takes the plugin out of circuit entirely, so you hear the signal "
              + "without it. A hard bypass: the wet path is silenced rather than the plugin "
              + "being asked to stop, which several Audio Units ignore. It is also the only "
              + "path with no insert latency in it.",
                now: state.slotIsBypassed(slot)
                    ? "ON — this plugin is out of circuit."
                    : "Off — the plugin is processing.")
    }

    private var deltaHelp: String {
        let what = "Delta — hear only what this plugin changed: wet minus dry, and none of the "
                 + "programme. Silence means it is doing nothing at all. One insert at a time, "
                 + "and it overrides the dry/wet balance while it is on."
        if state.slotIsBypassed(slot) {
            return tooltip(what, now: "Unavailable — the insert is bypassed, so there is no "
                                    + "difference to hear.")
        }
        if state.slotIsRefused(slot) {
            return tooltip(what, now: "Unavailable — this plugin will not take a "
                                    + "\(state.busChannels)-channel bus, so it is out of the "
                                    + "chain and there is no difference to hear. Narrow the "
                                    + "output bus and it comes back.")
        }
        if !state.slotIsLive(slot) {
            return tooltip(what, now: "Unavailable — waiting for the plugin to finish loading.")
        }
        guard state.deltaSlot == slot else {
            return tooltip(what, now: "Off — you are hearing the processed signal.")
        }
        let ms = state.slotLatencyMs[slot]
        let alignment = ms > 0.05
            ? String(format: "the dry path is delayed %.1f ms to match the plugin", ms)
            : "the plugin reports no latency, so nothing is compensated — if it has any, this "
            + "combs rather than nulls"
        return tooltip(what, now: "ON — you are hearing the difference, not the programme; "
                                + alignment + ".")
    }

    private var mixHelp: String {
        let what = "Dry/wet balance for this insert — ours, not the plugin's, so it works for "
                 + "every plugin including the many with no mix control of their own. The dry "
                 + "path is delayed to match the plugin's reported latency, so a partial blend "
                 + "sums instead of comb-filtering."
        if state.slotIsBypassed(slot) {
            return tooltip(what, now: "Inert — the insert is bypassed. The setting is kept.")
        }
        if state.deltaSlot == slot {
            return tooltip(what, now: "Overridden by Δ, which compares at unity. It comes back "
                                    + "when Δ is released.")
        }
        let percent = Int((state.slotMix[slot] * 100).rounded())
        let ms = state.slotLatencyMs[slot]
        let aligned = ms > 0.05 ? String(format: " Dry path aligned %.1f ms.", ms) : ""
        return tooltip(what, now: "\(percent) % wet.\(aligned)")
    }

    /// Dry/wet balance for this slot, applied as gains on the two parallel paths around the
    /// plugin rather than by the plugin itself. Inert while the slot is bypassed, so it is
    /// dimmed rather than hidden — the setting is still there when bypass comes off.
    private var mixRow: some View {
        HStack(spacing: 5) {
            Text(verbatim: "DRY")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(Color.mutedLabel)
            ResettableSlider(value: Binding(get: { state.slotMix[slot] },
                                            set: { state.setSlotMix(slot, $0) }),
                             defaultValue: 1,
                             tint: state.tintActive,
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
        .opacity(state.slotIsBypassed(slot) || state.deltaSlot == slot ? 0.4 : 1)
        .help(mixHelp)
    }

}

// MARK: - Log

struct LogPane: View {
    @Environment(AppState.self) var state
    var activity: ActivityLog

    var body: some View {
        // Built once per update: `log` formats up to 300 lines.
        let lines = state.log
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Color.mutedLabel)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(7)
            }
            .frame(height: 120)
            // On the log's own count: the drawer's stops changing at 300 lines.
            .onChange(of: activity.entries.count) { _, _ in
                proxy.scrollTo(lines.count - 1, anchor: .bottom)
            }
        }
    }
}

// MARK: - Manual SDP

struct ManualSDPSheet: View {
    @Environment(AppState.self) var state
    @Environment(\.dismiss) private var dismiss
    /// Internet stream first: it is what most people adding a stream by hand have.
    @AppStorage("addStreamKind") private var kind = "web"
    @State private var text = ""
    @State private var url = ""
    @State private var message: String?
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Internet streams are beta and off by default; with them off, this is the SDP sheet
            // it always was.
            if state.webStreamsEnabled {
                HStack(spacing: 8) {
                    Picker("", selection: $kind) {
                        Text("Internet stream").tag("web")
                        Text("SDP").tag("sdp")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                    if kind == "web" { BetaBadge() }
                }
            }
            if state.webStreamsEnabled && kind == "web" { webForm } else { sdpForm }
        }
        .padding(16)
        .frame(width: 492)
        .onChange(of: kind) { _, _ in message = nil }
    }

    private var webForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste a stream's address")
                .font(.headline)
            Text("An Icecast, SHOUTcast or plain HTTP stream in MP3, AAC or FLAC — a station's "
               + "direct stream link, or an .m3u or .pls playlist of one. Internet streams are "
               + "buffered for a couple of seconds: they are for listening, not for monitoring a "
               + "live bus.")
                .font(.caption).foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://…", text: $url)
                .textFieldStyle(.roundedBorder)
                .plainEntry()
                .onSubmit(add)
                .disabled(checking)
            if checking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking the stream…").font(.caption).foregroundStyle(Color.mutedLabel)
                }
            } else if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { state.cancelWebProbe(); dismiss() }
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || checking)
            }
        }
    }

    private func add() {
        guard !checking else { return }
        checking = true
        message = nil
        state.addWebStream(url) { error in
            checking = false
            if let error { message = error } else { dismiss() }
        }
    }

    private var sdpForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste SDP").font(.headline)
            Text("For a sender that announces nothing — copy the session's SDP out of ANEMAN, "
               + "Dante Controller's AES67 page, or the device's web UI.")
                .font(.caption).foregroundStyle(Color.mutedLabel)
            if !state.webStreamsEnabled {
                Text("Internet radio streams are in beta: switch them on under Settings → Discovery.")
                    .font(.caption).foregroundStyle(Color.mutedLabel)
            }
            TextEditor(text: $text)
                .font(.system(size: 11, design: .monospaced))
                .frame(minWidth: 460, minHeight: 220)
                .border(Color.secondary.opacity(0.3))
            if let message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    if let err = state.addManualSDP(text) { message = err } else { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.isEmpty)
            }
        }
    }
}

/// Playing streams whose sender has left: no audio and no announcement for a while.
/// Under the list, above Ignored. Each is still joined and plays again if it comes back; left
/// alone it stops by itself after five minutes, except one added by hand.
struct GoneSection: View {
    @Environment(AppState.self) var state

    var body: some View {
        let gone = state.gonePresent
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button { state.goneOpen.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: state.goneOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold)).frame(width: 8)
                        Text(verbatim: "Gone  \(gone.count)")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                    }
                    .foregroundStyle(Color.mutedLabel)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Streams that were playing and whose sender has left: no audio and no announcement "
                      + "for a while. Each plays again if it comes back, and stops by itself after five "
                      + "minutes.")
                Button("Clear all") { state.clearGone() }
                    .controlSize(.small)
                    .help("Stop every gone stream and take it off the list.")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if state.goneOpen {
                ForEach(gone) { stream in
                    HStack(spacing: 8) {
                        Text(stream.description.name).font(.system(size: 12))
                            .foregroundStyle(Color.mutedLabel).lineLimit(1)
                        Chip(text: stream.description.source.label,
                             tint: .tint(for: stream.description.source), filled: true)
                            .opacity(0.6)
                        Label("Gone", systemImage: "moon.zzz")
                            .font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                        Spacer()
                        Button("Stop") { state.stopGone(stream.id) }.controlSize(.small)
                            .help("Stop it and take it off the list. It is listed again if it comes back.")
                    }
                    .padding(.leading, 12 + 12 + 7 + 20 + 7).padding(.trailing, 12)
                    .frame(height: 28)
                    .contextMenu {
                        Button("Stop and remove") { state.stopGone(stream.id) }
                        Button("Ignore this stream") { state.ignore(stream.id) }
                        Divider()
                        Button("Clear all gone streams") { state.clearGone() }
                    }
                }
            }
        }
    }
}

/// The streams moved out of the list, folded at its foot. Each can be brought
/// back; nothing here plays.
struct IgnoredSection: View {
    @Environment(AppState.self) var state

    var body: some View {
        let ignored = state.ignoredPresent
        VStack(alignment: .leading, spacing: 0) {
            Button { state.ignoredOpen.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: state.ignoredOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold)).frame(width: 8)
                    Text(verbatim: "Ignored  \(ignored.count)")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(Color.mutedLabel)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .help("Streams you chose to ignore. They are remembered, and not listed with the others.")
            if state.ignoredOpen {
                ForEach(ignored) { stream in
                    HStack(spacing: 8) {
                        Text(stream.description.name).font(.system(size: 12))
                            .foregroundStyle(Color.mutedLabel).lineLimit(1)
                        Chip(text: stream.description.source.label,
                             tint: .tint(for: stream.description.source), filled: true)
                            .opacity(0.6)
                        Spacer()
                        Button("Show in list") { state.unignore(stream.id) }.controlSize(.small)
                    }
                    .padding(.leading, 12 + 12 + 7 + 20 + 7).padding(.trailing, 12)
                    .frame(height: 28)
                    .contextMenu { Button("Show in list") { state.unignore(stream.id) } }
                }
            }
        }
    }
}


/// The line under a stream row. Between plain rows, the usual hairline. Where it borders an open
/// row, a small gap of plain background as well, so two open rows side by side no longer run
/// together as one grey block.
struct OpenRowEdge: View {
    let touchesOpen: Bool

    var body: some View {
        if touchesOpen {
            VStack(spacing: 0) {
                Divider().opacity(0.5)
                Color.clear.frame(height: 6)
                Divider().opacity(0.5)
            }
        } else {
            Divider().opacity(0.5)
        }
    }
}
