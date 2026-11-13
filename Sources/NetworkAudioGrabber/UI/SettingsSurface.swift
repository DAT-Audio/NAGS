import SwiftUI

/// Settings, in the window rather than in a popover.
///
/// The seven sections are unchanged — Playout, Fold-down, Discovery, Output, Loudness, Theme,
/// View — because the README refers to them by name (`Settings → Loudness` and so on). What
/// changed is how you reach one: they are a list you pick from instead of a column you scroll
/// past. Three things were making the popover hard to read:
///
/// * **Everything was visible at once.** Seven sections stacked in a 380-point column meant
///   finding a setting was a scroll and a scan, and the section titles — 9 pt tertiary caps —
///   were the weakest thing on screen rather than the strongest.
/// * **The prose outweighed the controls.** Playout is two controls and two paragraphs; Theme is
///   four controls and a paragraph longer than all of them. The explanations are worth keeping —
///   each one answers a question the app would otherwise be asked — but they are read once and
///   skipped forever after, so they now sit behind `Explainer`, shut by default.
/// * **Labels were hand-aligned** to a 96-point column that drifted as controls were added.
///   `Form` with `.formStyle(.grouped)` does that alignment itself, and brings the grouped-box
///   look of the system's own settings with it.
///
/// It takes over the stream list rather than opening a window of its own, which keeps the
/// signal panel, the master meters and the status bar visible beside it — so the buffer can be
/// tuned while watching the thing it affects, which was the one real argument for the popover.
struct SettingsSurface: View {
    @Environment(\.skin) private var skin
    @Environment(AppState.self) var state
    @Environment(\.colorScheme) private var scheme

    /// The compact window has no room for a sidebar at 320 points, so the same panes are picked
    /// from a row of icons instead. Passed in rather than measured: the two windows already know
    /// which they are, and a `GeometryReader` here would re-measure on every meter frame.
    var compact = false

    /// Deliberately not persisted. Which pane was open last is not a setting, and both `--render`
    /// and `--selftest` run against a throwaway defaults suite to leave no trace.
    /// Which pane is showing, held on `AppState` rather than here. This view is rebuilt when
    /// the window mode changes, so a `@State` pane was thrown back to Playout every time
    /// someone switched between the full and compact windows — from inside the View pane,
    /// which is where that switch lives.
    private var pane: SettingsPane {
        get { SettingsPane(rawValue: state.settingsPane) ?? .playout }
        nonmutating set { state.settingsPane = newValue.rawValue }
    }

    private var paneBinding: Binding<SettingsPane> {
        Binding(get: { pane }, set: { pane = $0 })
    }

    var body: some View {
        if compact {
            VStack(spacing: 0) {
                rail
                Divider()
                paneBody
            }
        } else {
            HStack(spacing: 0) {
                sidebar
                Divider()
                paneBody
            }
        }
    }

    // MARK: - Picking a pane

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(SettingsPane.allCases) { item in
                Button { pane = item } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 11))
                            .frame(width: 16)
                            .foregroundStyle(pane == item
                                             ? AnyShapeStyle(state.tintActive(on: scheme))
                                             : AnyShapeStyle(Color.mutedLabel))
                        Text(item.title)
                            .font(.system(size: 12, weight: pane == item ? .semibold : .regular))
                            .foregroundStyle(pane == item ? Color.primary : Color.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(state.tintActive.opacity(pane == item ? 0.16 : 0)))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            QuickStartLink(short: true).padding(.horizontal, 8).padding(.bottom, 2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(width: 150, alignment: .leading)
        .background(skin.style.panel.map { Color(nsColor: $0) } ?? Color.primary.opacity(0.03))
    }

    /// The compact window's equivalent: icons only, with the name carried by the pane header
    /// underneath. Seven 30-point targets fit inside 320 points with room to spare.
    private var rail: some View {
        HStack(spacing: 2) {
            ForEach(SettingsPane.allCases) { item in
                Button { pane = item } label: {
                    Image(systemName: item.symbol)
                        .font(.system(size: 12))
                        .frame(width: 26, height: 22)
                        .foregroundStyle(pane == item
                                         ? AnyShapeStyle(state.tintActive(on: scheme))
                                         : AnyShapeStyle(Color.mutedLabel))
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(state.tintActive.opacity(pane == item ? 0.16 : 0)))
                }
                .buttonStyle(.plain)
                .help(item.title)
            }
            Spacer(minLength: 0)
            QuickStartLink(iconOnly: true).frame(width: 26, height: 22)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    // MARK: - The pane itself

    private var paneBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(state.tintActive(on: scheme))
                Text(pane.title).font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
                Button("Done") { state.showSettings = false }
                    .controlSize(.small)
                    .help("Back to the streams (⌘,)")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Text(pane.subtitle)
                .font(.caption)
                .foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.top, 2)

            pane.content
                // The form paints its own ground, which would otherwise cover the theme wash.
                .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The sections, in the order they appear. Unchanged from the popover, and from what the README
/// calls them.
enum SettingsPane: String, CaseIterable, Identifiable {
    case sources, playout, send, foldDown, discovery, output, loudness, theme, view, log, acknowledgements

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sources:   return "Sources"
        case .playout:   return "Playout"
        case .send:      return "Send"
        case .foldDown:  return "Fold-down"
        case .discovery: return "Discovery"
        case .output:    return "Output"
        case .loudness:  return "Loudness"
        case .theme:     return "Theme"
        case .view:      return "View"
        case .log:       return "Log"
        case .acknowledgements: return "Credits"
        }
    }

    var symbol: String {
        switch self {
        case .sources:   return "list.bullet.below.rectangle"
        case .playout:   return "timer"
        case .send:      return "arrow.up.forward.circle"
        case .foldDown:  return "arrow.triangle.merge"
        case .discovery: return "antenna.radiowaves.left.and.right"
        case .output:    return "speaker.wave.2"
        case .loudness:  return "waveform"
        case .theme:     return "paintpalette"
        case .view:      return "macwindow"
        case .log:       return "list.bullet.rectangle"
        case .acknowledgements: return "text.book.closed"
        }
    }

    /// One line saying what the pane is for, so the name in the sidebar does not have to carry
    /// it — and so the compact window, which shows icons only, still says where it is.
    var subtitle: String {
        switch self {
        case .sources:   return "Every kind of stream the Grabber can play, and how each arrives."
        case .playout:   return "How much buffer sits between the network and the output, and when a quiet stream stops."
        case .send:      return "This Grabber's own Send: its stream, resuming, and auto-stop."
        case .foldDown:  return "What happens to 5.1 and 7.1 streams on a stereo monitor."
        case .discovery: return "Which announcements the app listens for."
        case .output:    return "The device the monitor bus plays out to."
        case .loudness:  return "LUFS readings and the targets they are judged against."
        case .theme:     return "Light, dark or the system's, and an optional colour scheme on top."
        case .view:      return "Window layout, stream list density and meter refresh rate."
        case .log:       return "What the app did, and why: requests, results and changes."
        case .acknowledgements: return "Trademarks, and the specifications the app was written from."
        }
    }

    @MainActor @ViewBuilder
    var content: some View {
        switch self {
        case .sources:   ScrollView { SourcesGuide(compact: true).padding(20) }
        case .playout:   PlayoutPane()
        case .send:      SendPane()
        case .foldDown:  FoldDownPane()
        case .discovery: DiscoveryPane()
        case .output:    OutputPane()
        case .loudness:  LoudnessPane()
        case .theme:     ThemePane()
        case .view:      ViewPane()
        case .log:       LogSettingsPane()
        case .acknowledgements: Form { Acknowledgements() }.formStyle(.grouped)
        }
    }
}

// MARK: - Panes

private struct PlayoutPane: View {
    @Environment(AppState.self) var state

    var body: some View {
        Form {
            Section {
                LabeledContent("Buffer, PTP streams") {
                    HStack(spacing: 8) {
                        ResettableSlider(value: Bindable(state).latencyMs, range: 5...80, step: 1,
                                         defaultValue: AppState.defaultLatencyMs, tint: state.tintActive,
                                         controlSize: .regular)
                            .frame(height: 22)
                        Text("\(Int(state.latencyMs)) ms")
                            .monospacedDigit()
                            .frame(width: 46, alignment: .trailing)
                    }
                }
                // Which streams each buffer is for, said where it is set.
                Text("AES67, RAVENNA and Dante in AES67 mode — streams that follow a PTP clock.")
                    .font(.caption).foregroundStyle(Color.mutedLabel)
                // Its own setting for every stream without a shared clock (the `.lan` latency
                // class): VBAN, Scream, and RTP that names no PTP clock. Those usually come over
                // Wi-Fi or a VPN. Always shown: plain RTP can arrive with nothing turned
                // on for it.
                do {
                    LabeledContent("Buffer, streams without PTP") {
                        HStack(spacing: 8) {
                            ResettableSlider(value: Bindable(state).vbanLatencyMs, range: 5...80, step: 1,
                                             defaultValue: AppState.defaultVBANLatencyMs, tint: state.tintActive,
                                             controlSize: .regular)
                                .frame(height: 22)
                            Text("\(Int(state.vbanLatencyMs)) ms")
                                .monospacedDigit()
                                .frame(width: 46, alignment: .trailing)
                        }
                    }
                    .help(tooltip("The buffer for streams with no shared clock: VBAN, Scream, and RTP "
                                + "from senders such as PipeWire, VLC or GStreamer that name no PTP "
                                + "clock. They usually arrive over Wi-Fi or a VPN, where packets bunch "
                                + "up more than on a wired network. 20 ms "
                                + "was clean over Wi-Fi in testing; below about 16 ms, underruns start.",
                                  now: "\(Int(state.vbanLatencyMs)) ms"))
                    Text("VBAN (Network Audio Sender, Voicemeeter), Scream, and RTP without PTP "
                       + "(PipeWire, VLC, GStreamer).")
                        .font(.caption).foregroundStyle(Color.mutedLabel)
                }
                // Streams from another location, across the internet: their own,
                // fixed; the connection test beside it suggests a figure.
                LabeledContent("Buffer, streams from another location") {
                    HStack(spacing: 8) {
                        ResettableSlider(value: Bindable(state).remoteLatencyMs, range: AppState.remoteBufferRange, step: 5,
                                         defaultValue: AppState.defaultRemoteLatencyMs, tint: state.tintActive,
                                         controlSize: .regular)
                            .frame(height: 22)
                        Text("\(Int(state.remoteLatencyMs)) ms")
                            .monospacedDigit()
                            .frame(width: 46, alignment: .trailing)
                    }
                }
                .help(tooltip("Streams marked REMOTE or VPN cross the internet, where packets arrive far less evenly "
                            + "than on a local network, so they get a larger buffer of their own. It stays at "
                            + "this figure: Test the connection suggests one, and changes nothing unless you "
                            + "press Use.",
                              now: "\(Int(state.remoteLatencyMs)) ms"))
                Text("Streams marked REMOTE or VPN (across the internet). 60 ms to start.")
                    .font(.caption).foregroundStyle(Color.mutedLabel)
                ConnectionTestRow()
                LabeledContent("Device buffer (frames)") {
                    Picker("", selection: Binding(
                        get: { Int(state.outputBufferFrames) },
                        set: { state.setOutputBufferFrames(UInt32($0)) })) {
                        // `verbatim`, or the interpolation runs through a localized key and
                        // 1024 arrives on screen as "1 024".
                        ForEach([64, 128, 256, 512, 1024], id: \.self) { size in
                            Text(verbatim: "\(size)").tag(size)
                        }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 230)
                }
            } footer: {
                Text(LocalizedStringKey("Each buffer is a **total**, and the output device's "
                                      + "own buffer is spent first. **Device buffer** applies to "
                                      + "everything played. Internet radio keeps its own "
                                      + "few-second buffer, which is not set here."))
                    .font(.caption2).foregroundStyle(Color.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Auto-stop: off, a joined stream stays joined however long it is quiet,
            // and plays again when it returns — as it does after the app is reopened.
            Section {
                Toggle("Stop streams that go quiet", isOn: Bindable(state).autoStopStreams)
                LabeledContent("After") {
                    Picker("", selection: Bindable(state).autoStopStreamsMinutes) {
                        ForEach(AppState.autoStopChoices, id: \.self) { m in
                            Text(verbatim: AppState.minutesText(m)).tag(m)
                        }
                    }
                    .labelsHidden().frame(maxWidth: 120)
                }
                .disabled(!state.autoStopStreams)
            } header: {
                Text("Auto-stop")
            } footer: {
                Text("Off, a stream you play stays joined until you stop it, however long it is quiet, "
                   + "and plays again the moment it returns; streams playing when the app quits are "
                   + "joined again when it opens and they are found. On, each playing stream is "
                   + "stopped once it has had no audio for the time chosen — its row then says "
                   + "Timed out. Sending has its own, under Send.")
                    .font(.caption2).foregroundStyle(Color.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Budget") {
                // Polled: the figures move, and publishing them would drag the window.
                MeterTimeline(fps: 2, paused: !state.metersActive) {
                    Text(state.latencyBudget)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color.mutedLabel)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // **A minimum, not a fixed height.** 52 points was enough for the figures on a
                // wide pane and clipped them mid-sentence on a narrow one, where the same text
                // wraps to twice the lines. A fixed frame around a timeline is what keeps it from
                // dragging the layout — that matters at 30 fps on the window's hot
                // path, not at 2 fps inside a settings pane whose line count changes rarely.
                .frame(minHeight: 52, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
            }

            Explainer(title: "How to tune the buffer",
                      text: "A device at 512 frames uses 10.7 ms of the total before anything is "
                          + "left to absorb network jitter. Dropping the device to 128 frames is "
                          + "usually the cheapest way to lower end-to-end latency — mind that it "
                          + "is a shared setting, so other apps using this device get it too."
                          + "\n\nThen lower the buffer until underruns start moving and back off "
                          + "a notch. **Arrival jitter** is the honest guide: the buffer has to "
                          + "cover the worst figure, and if that is large the cause is upstream — "
                          + "the sender's packet pacing or the switch — not this Mac.")
        }
        .formStyle(.grouped)
    }
}

/// Settings → Send: the Send's own settings, shared with Network Audio Sender's.
private struct SendPane: View {
    @Environment(AppState.self) var state

    var body: some View {
        if let send = state.send {
            GrabberSendSettings(send: send)
        } else {
            Form { Text("Send is not available here.").foregroundStyle(Color.mutedLabel) }
                .formStyle(.grouped)
        }
    }
}

/// **Test the connection**: listens to one playing remote
/// stream for 30 s and suggests a buffer. The buffer itself is left alone unless Use is pressed.
struct ConnectionTestRow: View {
    @Environment(AppState.self) var state
    @State private var chosen: String?

    var body: some View {
        let remote = state.playingRemoteStreams
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if remote.count > 1 {
                    Picker("", selection: Binding(get: { chosen ?? remote.first?.id }, set: { chosen = $0 })) {
                        ForEach(remote, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden().frame(maxWidth: 180)
                }
                Button(runningName != nil ? "Testing…" : "Test the connection") {
                    if let id = chosen ?? remote.first?.id { state.testConnection(id) }
                }
                .disabled(remote.isEmpty || runningName != nil)
                if remote.isEmpty {
                    Text("Play a stream marked REMOTE or VPN to test it.").font(.caption).foregroundStyle(Color.mutedLabel)
                }
            }
            switch state.connectionTest {
            case .running(let name, let until):
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(verbatim: "Listening to “\(name)” — \(max(0, Int(until.timeIntervalSince(context.date)))) s left. Nothing changes while it runs.")
                        .font(.caption).foregroundStyle(Color.mutedLabel)
                }
            case .done(let r):
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: String(format: "“%@”: packets arrived within %.0f ms of even (worst %.0f ms)", r.streamName, r.spreadMs, r.worstMs)
                         + (r.lostPercent >= 0.1 ? String(format: ", %.1f %% lost", r.lostPercent) : ", none lost") + ".")
                        .font(.caption)
                    HStack(spacing: 8) {
                        Text(verbatim: "Suggested: \(Int(r.suggestedMs)) ms").font(.caption.weight(.semibold))
                        Button("Use \(Int(r.suggestedMs)) ms") { state.useSuggestedBuffer() }
                            .controlSize(.small)
                            .disabled(Int(state.remoteLatencyMs) == Int(r.suggestedMs))
                        Button("Dismiss") { state.clearConnectionTest() }.controlSize(.small)
                    }
                    if r.lostPercent >= 1 {
                        Text("Packets are being lost, which no buffer can fix: the connection itself is the limit.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            case .failed(let why):
                Text(why).font(.caption).foregroundStyle(.orange)
            case .idle:
                Text("Listens to a remote stream for 30 s and suggests a buffer — the spread of arrival times plus a margin. "
                     + "It changes nothing: press Use to take the suggestion, or set the slider yourself.")
                    .font(.caption).foregroundStyle(Color.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var runningName: String? {
        if case .running(let name, _) = state.connectionTest { return name }
        return nil
    }
}

private struct FoldDownPane: View {
    @Environment(AppState.self) var state

    var body: some View {
        Form {
            Section {
                LabeledContent("Channel order") {
                    Picker("", selection: Bindable(state).channelOrder) {
                        ForEach(ChannelOrder.allCases) { order in
                            Text(order.menuLabel(channels: 6)).tag(order)
                        }
                    }
                    .labelsHidden()
                }
                LabeledContent("Downmix trim") {
                    Picker("", selection: Bindable(state).downmixTrimDB) {
                        Text("0 dB").tag(0.0)
                        Text("−3 dB").tag(-3.0)
                        Text("−6 dB").tag(-6.0)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 180)
                }
                Toggle("Include LFE in the fold-down (−10 dB)", isOn: Bindable(state).includeLFE)
                Toggle("Fold quad, 5.1 and 7.1 streams down automatically",
                       isOn: Bindable(state).autoFoldSurround)
            } footer: {
                Text("On by default, because monitoring on headphones usually means wanting the "
                   + "whole bed. Each stream then remembers what you last set it to, so a "
                   + "discrete multichannel feed only needs putting back on Ch 1/2 once — from "
                   + "its own menu in the list.")
                    .font(.caption2).foregroundStyle(Color.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Explainer(title: "Channel order is assumed, not detected",
                      text: "**SMPTE** reads 5.1 as L R C LFE Ls Rs and 7.1 as L R C LFE Lss "
                          + "Rss Lrs Rrs. **ITU/DTS** puts the surrounds before the centre and "
                          + "LFE: L R Ls Rs C LFE. AES67 and Dante carry no channel-order "
                          + "metadata at all, so this is an assumption either way — which is "
                          + "why it is a setting rather than a fact.\n\nThis is the default "
                          + "for every stream. A single stream can be set differently from its "
                          + "own menu in the list, because the order belongs to the sender: two "
                          + "devices on one network can disagree. The order decides the "
                          + "fold-down gains, the channel labels, which channel is excluded as "
                          + "LFE, and which carry the +1.5 dB loudness weighting.")
        }
        .formStyle(.grouped)
    }
}

private struct DiscoveryPane: View {
    @Environment(AppState.self) var state

    var body: some View {
        Form {
            Section {
                Toggle("SAP announcements", isOn: Bindable(state).sapEnabled)
                Toggle("RAVENNA (Bonjour + RTSP)", isOn: Bindable(state).ravennaEnabled)
                Toggle("Dante devices (AES67 mode)", isOn: Bindable(state).danteEnabled)
                Toggle("VBAN (UDP \(String(VBAN.port)))", isOn: Bindable(state).vbanEnabled)
                Toggle(isOn: Bindable(state).screamEnabled) {
                    HStack(spacing: 6) { Text("Scream (UDP \(String(Scream.port)))"); BetaBadge() }
                }
                .help("Scream is a free virtual sound card for Windows that sends the PC's audio "
                    + "over the network. Each PC sending it appears in the list by itself.")
                Toggle(isOn: Bindable(state).plainRTPEnabled) {
                    HStack(spacing: 6) { Text("RTP without PTP"); BetaBadge() }
                }
                .help("RTP streams that follow no PTP clock — PipeWire, PulseAudio, VLC, GStreamer — "
                    + "announced over SAP or pasted as SDP. AES67 streams are not affected either way.")
                Toggle(isOn: Bindable(state).webStreamsEnabled) {
                    HStack(spacing: 6) { Text("Internet streams"); BetaBadge() }
                }
                .help("Icecast, SHOUTcast and plain HTTP radio streams, added by their web address "
                    + "with the + button. Nothing is fetched until you play one.")
                Toggle("Keep streams added from SDP", isOn: Bindable(state).keepManualStreams)
                    .help("A stream you pasted the SDP of is never announced, so once stopped it "
                        + "leaves the list after two quiet minutes, like any stream that stops "
                        + "announcing. On: it stays until you remove it (right-click → Remove from "
                        + "the list). Not kept after the app quits.")
                if !state.ignoredStreams.isEmpty {
                    LabeledContent("Ignored streams") {
                        HStack(spacing: 8) {
                            Text(verbatim: "\(state.ignoredStreams.count) remembered")
                                .foregroundStyle(Color.mutedLabel)
                            Button("Show all again") { state.ignoredStreams = [] }
                        }
                    }
                    .help("Streams moved to Ignored (right-click a stream → Ignore this stream). "
                        + "They are listed folded at the foot of the stream list while they are on "
                        + "the network; this brings every one of them back, including any not "
                        + "announcing right now.")
                }
            }

            if state.vbanEnabled { VBANSetupSection(); SenderLinkSection() }

            if !state.danteDevices.isEmpty {
                Section {
                    // Which devices are actually publishing matters more than which exist: a
                    // device can be healthy on the Dante side and still send us nothing.
                    ForEach(state.danteDevices) { device in
                        let publishing = state.danteIsPublishing(device)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(publishing ? Color.sourceDante : Color.secondary.opacity(0.4))
                                .frame(width: 5, height: 5)
                            Text(device.name).font(.caption)
                            if let a = device.address {
                                Text(verbatim: a)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(Color.mutedLabel)
                            }
                            Spacer(minLength: 0)
                            Chip(text: publishing ? "AES67" : "no flow",
                                 tint: publishing ? .sourceDante : .secondary)
                        }
                    }
                } header: {
                    Text("Dante devices")
                } footer: {
                    Text("\"no flow\" means the device is reachable but publishing no AES67 "
                       + "stream this app can receive.")
                        .font(.caption2).foregroundStyle(Color.mutedLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Explainer(title: "Why a Dante device can appear and still send nothing",
                      text: "Dante audio reaches this app only when a device is in **AES67 mode** "
                          + "and someone has created an AES67 multicast flow for it in Dante "
                          + "Controller. **Dante Virtual Soundcard and Dante Via cannot do AES67 "
                          + "at all** — route them through a hardware Dante device, or use a "
                          + "RAVENNA driver instead.")

            Explainer(title: "What turning VBAN on opens up",
                      text: "VBAN (Voicemeeter, VBAN apps on phones) has **no authentication**, and "
                          + "is off until switched on here. On, the app listens on UDP 6980 on "
                          + "**every** interface, VPNs such as Tailscale included, and lists any "
                          + "VBAN stream sent to this Mac. Nothing is decoded until you join a "
                          + "stream; at most 32 are listed, 8 from any one sender, and 4 new ones a "
                          + "second admitted, so a flood of made-up streams cannot swamp the list "
                          + "or lock other senders out. A stream appears "
                          + "while its packets arrive and leaves 15 s after they stop.")
        }
        .formStyle(.grouped)
    }
}

/// Everything a VBAN sender needs, since VBAN has no discovery of its own: the sender is pointed
/// at the receiver, not the other way round. So this lists every address this Mac can be reached
/// on and the port, each one copyable, and says which to use. Nothing else needs setting on this
/// side — whatever arrives on the port is listed as a stream.
private struct VBANSetupSection: View {
    @Environment(AppState.self) var state
    @State private var copied: String?

    var body: some View {
        // Read when the pane is drawn, not cached: a VPN connecting or a new DHCP lease
        // changes the answer.
        let addresses = state.vbanAddresses
        Section {
            if let error = state.vbanError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if addresses.isEmpty {
                Text("This Mac has no network address right now.")
                    .font(.caption).foregroundStyle(Color.mutedLabel)
            }
            ForEach(addresses, id: \.address) { address in
                row(address.address, label: "\(address.kindLabel) · \(address.name)",
                    what: "this address")
                if let broadcast = address.broadcast {
                    row(broadcast, label: "Broadcast · \(address.name)",
                        what: "this network's broadcast address")
                }
            }
            row(String(VBAN.port), label: "Port", what: "the port")
        } header: {
            Text("Send VBAN to this Mac")
        } footer: {
            Text("In the sender — in Voicemeeter, an outgoing stream in its VBAN window — set the "
               + "IP address to the one on the same network as the sender, and the port to "
               + "\(String(VBAN.port)). A broadcast address reaches every receiver on that "
               + "network at once, but also sends the audio to every device on it, so prefer the "
               + "Mac's own address where one receiver will do. A VPN address works for a sender "
               + "elsewhere on the same VPN. Nothing else is set here: every stream that arrives "
               + "is listed with the others.")
                .font(.caption2).foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ value: String, label: String, what: String) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: value)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
            Text(verbatim: label)
                .font(.caption2).foregroundStyle(Color.mutedLabel)
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copied = value
            } label: {
                Image(systemName: copied == value ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help(tooltip("Copy \(what) to the clipboard.",
                          now: copied == value ? "copied" : value))
        }
    }
}

/// Network Audio Sender's side of VBAN (stage 3): what this Grabber calls itself to a Sender,
/// and Senders added by address for wherever their offer cannot be heard.
private struct SenderLinkSection: View {
    @Environment(AppState.self) var state
    @State private var nameDraft = ""
    @State private var address = ""
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        Section {
            LabeledContent("This Grabber's name") {
                // Title empty and the hint as a prompt: in a grouped Form a TextField's title is
                // drawn as a second label beside the field, which put this Mac's name on screen.
                TextField("", text: $nameDraft, prompt: Text(AppState.receiverName("")))
                    .labelsHidden()
                    .plainEntry()
                    .multilineTextAlignment(.trailing)
                    .focused($nameFocused)
                    .onSubmit { state.vbanReceiverName = nameDraft }
                    .onChange(of: nameFocused) { _, focused in if !focused { state.vbanReceiverName = nameDraft } }
                    .onAppear { nameDraft = state.vbanReceiverName }
                    .frame(maxWidth: 220)
            }
            .help(tooltip("What a Network Audio Sender shows against this Grabber while it listens. "
                        + "Up to 16 plain characters; blank uses this Mac's name.",
                          now: AppState.receiverName(state.vbanReceiverName)))
            LabeledContent("Add a Sender by address") {
                HStack(spacing: 6) {
                    TextField("", text: $address, prompt: Text(verbatim: "192.0.2.20"))
                        .labelsHidden()
                        .plainEntry()
                        .frame(maxWidth: 170)
                        .onSubmit(add)
                    Button(RemoteAddresses.isRemote(RemoteAddresses.host(address)) ? "Add anyway" : "Add", action: add)
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if RemoteAddresses.isRemote(RemoteAddresses.host(address)) {
                RemoteWarning(receivingEnd: false)
            }
            ForEach(state.vbanManualSenders, id: \.self) { key in
                let sending = state.vbanSenderStates[key] ?? false
                HStack(spacing: 8) {
                    Circle().fill(sending ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 6, height: 6)
                    Text(verbatim: key).font(.system(size: 12, design: .monospaced))
                    Text(sending ? "sending here" : "waiting for it to answer")
                        .font(.caption2).foregroundStyle(Color.mutedLabel)
                    Spacer(minLength: 0)
                    Button { state.removeManualSender(key) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("Stop asking \(key) for its stream, and remove it.")
                }
            }
        } header: {
            Text("Network Audio Sender")
        } footer: {
            Text("A Network Audio Sender that offers its stream appears in the list by itself: press "
               + "play and it sends to this Mac only. Add one by address where its offer cannot "
               + "reach, such as over a VPN; its port is \(String(VBANControl.controlPort)) unless "
               + "you add another. An added Sender sends here for as long as it is in this list.")
                .font(.caption2).foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        Explainer(title: "Which way to connect",
                  text: "**Network Audio Sender, same network:** it appears in the list by itself. "
                      + "Press play; if its user asks before a new Grabber listens, the row says "
                      + "*asking…* until they allow it.\n\n**Network Audio Sender over a VPN:** add it "
                      + "by address above. It has to be offering, and may ask its user too.\n\n"
                      + "**Voicemeeter or any other VBAN sender:** point it at an address under *Send "
                      + "VBAN to this Mac*, port \(String(VBAN.port)).\n\n**AES67, RAVENNA, Dante in "
                      + "AES67 mode:** nothing to set here; streams appear by themselves.")
    }

    private func add() {
        error = state.addManualSender(address)
        if error == nil { address = "" }
    }
}

private struct LogSettingsPane: View {
    @Environment(AppState.self) var state
    var body: some View {
        VStack(spacing: 0) {
            ActivityLogView(log: state.activity).padding(14)
            // Where the app's data lives, and leaving.
            Form { RemoveAllSettings() }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .frame(height: 150)
        }
    }
}

private struct OutputPane: View {
    @Environment(AppState.self) var state

    var body: some View {
        Form {
            Section {
                LabeledContent("Device") {
                    if AudioOutput.hostMode {
                        Text(state.outputDeviceName).lineLimit(1).truncationMode(.middle)
                    } else {
                        OutputDevicePicker()
                    }
                }
                // The chosen device unplugged: said here, where it was chosen.
                if state.outputFallback {
                    Label("\(state.outputDeviceChosenName) isn't connected. Playing on the system default "
                          + "(\(state.outputDeviceName)) until it's back.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("Output bus") {
                    Picker("", selection: Binding(get: { state.busChannels },
                                                  set: { state.setBusWidth($0) })) {
                        ForEach(state.busWidthOptions, id: \.self) { width in
                            Text(state.busWidthLabel(width)).tag(width)
                        }
                    }
                    .labelsHidden()
                    .disabled(state.busWidthOptions.count < 2)
                }
                LabeledContent("Sample rate") {
                    // A **picker of the device's own rates**, not a one-way button to 48 kHz.
                    // The old control could take a device off 44.1 and offered no way back,
                    // which matters more than usual because this is the *device's* setting:
                    // every app on the Mac sees it.
                    Picker("", selection: Binding(get: { state.outputRate },
                                                  set: { state.setOutputSampleRate($0) })) {
                        ForEach(state.outputSampleRates, id: \.self) { rate in
                            Text(verbatim: String(format: "%.4g kHz", rate / 1000)).tag(rate)
                        }
                        // The running rate always appears, even if the device stops offering
                        // it, so the menu never shows a blank selection.
                        if !state.outputSampleRates.contains(state.outputRate) {
                            Text(verbatim: String(format: "%.4g kHz", state.outputRate / 1000))
                                .tag(state.outputRate)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .foregroundStyle(state.outputRate == 48000 ? Color.primary : .orange)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if !AudioOutput.hostMode {
                        Text(LocalizedStringKey("**System default** follows whatever the Mac plays through "
                           + "(Control Centre or System Settings → Sound). A named device stays chosen "
                           + "however the Mac's own setting changes. To play on several devices at once, "
                           + "make a Multi-Output Device in Audio MIDI Setup and choose it here."))
                        Button("Open Audio MIDI Setup") { state.openAudioMIDISetup() }
                            .buttonStyle(.link).font(.caption2)
                    }
                    Text("The output bus is how many of the device's channels the app plays "
                       + "out of. Streams that fit go out channel for channel; wider ones fold "
                       + "to stereo on the first pair. The choice is remembered per device, so "
                       + "headphones and a monitor rig each keep their own.")
                    if state.outputRate != 48000 {
                        Text("AES67 is 48 kHz throughout. At any other device rate a "
                           + "sample-rate conversion sits in the monitor path.")
                    }
                }
                .font(.caption2).foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Headphone safety limiter", isOn: Bindable(state).safetyLimiter)
                    .help("Apple's peak limiter on the end of the chain, to catch a hot stream")
            } footer: {
                Text("Apple's peak limiter, last in the chain. It is there to catch a stream that "
                   + "arrives far hotter than expected, not to be mixed into.")
                    .font(.caption2).foregroundStyle(Color.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

private struct LoudnessPane: View {
    @Environment(AppState.self) var state

    var body: some View {
        Form {
            Section {
                Toggle("Show loudness readings", isOn: Bindable(state).showLoudness)
                // Here, next to the readings it controls (it used to be under View).
                LabeledContent("Pinned loudness") {
                    Picker("", selection: Bindable(state).pinnedLoudness) {
                        ForEach(LoudnessPin.allCases) { pin in
                            Text(pin.label).tag(pin)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                    // Nothing to pin when the readings are switched off. A live control for
                    // something that cannot happen is worse than no control.
                    .disabled(!state.showLoudness)
                }
                .opacity(state.showLoudness ? 1 : 0.45)
                LabeledContent("Window") {
                    HStack(spacing: 6) {
                        TextField("", value: Bindable(state).lufsWindowSeconds, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .monospacedDigit()
                            .frame(width: 56)
                        Text("seconds").font(.caption).foregroundStyle(Color.mutedLabel)
                        Spacer(minLength: 0)
                    }
                }
            }

            Section {
                LabeledContent("Targets") {
                    HStack(spacing: 6) {
                        targetField("S", Bindable(state).targetShortTerm)
                        targetField("W", Bindable(state).targetWindow)
                        targetField("I", Bindable(state).targetIntegrated)
                        Text("LUFS").font(.caption).foregroundStyle(Color.mutedLabel)
                        Spacer(minLength: 0)
                    }
                }
                LabeledContent("Presets") {
                    HStack(spacing: 6) {
                        Button("−23 (R 128)") { state.setLoudnessTargets(-23) }
                            .controlSize(.small)
                        Button("−14 (streaming)") { state.setLoudnessTargets(-14) }
                            .controlSize(.small)
                        Spacer(minLength: 0)
                    }
                }
            } footer: {
                Text("**S** short-term, **W** the window, **I** integrated.")
                    .font(.caption2).foregroundStyle(Color.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // It said what short-term was and left the other two to be inferred from a
            // clause. Three readings, three sentences, each saying what it is *for* — the
            // span alone does not tell you which one to look at.
            Explainer(title: "What the three readings measure",
                      text: "Short-term (S) is a fixed 3-second window. It moves with the "
                          + "material, so it is the one to mix against.\n\n"
                          + "Window (W) is the span set above — a minute by default — gated "
                          + "the way integrated is. It answers how loud the recent past has "
                          + "been, without waiting for a whole programme.\n\n"
                          + "Integrated (I) runs from the last reset until you reset it again "
                          + "(⇧⌘L). It is the figure a delivery specification means.\n\n"
                          + "All three are measured on the summed bus ahead of master level, "
                          + "DIM and MONO, so the monitor controls cannot move a reading.\n\n"
                          + "Pinned loudness is the reading you judge by, made readable across a "
                          + "room. In the full window it leads the readings beside the output "
                          + "meters, larger than the others; in the compact window it sits beside "
                          + "the peak figure, at the same size. It changes nothing about what is "
                          + "measured.")
        }
        .formStyle(.grouped)
    }

    /// One loudness target, labelled with the reading it belongs to.
    private func targetField(_ label: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 3) {
            Text(verbatim: label)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Color.mutedLabel)
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .frame(width: 48)
        }
    }
}

private struct ThemePane: View {
    @Environment(AppState.self) var state

    var body: some View {
        Form {
            Section {
                // Light, dark or the system's, beside the colours they shade — it used to live in View,
                // apart from them, as the Sender has it.
                AppearanceControl(appearance: Bindable(state).appearance, skin: state.skin)
                ColourSchemeControls(theme: Binding(
                    get: { ThemeChoice(enabled: state.themeEnabled, primaryHex: state.themePrimaryHex,
                                       secondaryHex: state.themeSecondaryHex) },
                    set: { state.themeEnabled = $0.enabled
                           state.themePrimaryHex = $0.primaryHex
                           state.themeSecondaryHex = $0.secondaryHex }))
            }

            Explainer(title: "What the two colours reach, and what stays fixed",
                      text: "**Window** washes every surface, so the list, the toolbar and the "
                          + "signal panel take the hue instead of white and off-white — the panel "
                          + "still sits a shade apart, because the shading is applied over the "
                          + "tint rather than replaced by it. **Active** is anything you have "
                          + "switched on: a stream you are listening to, its stop button, ACTIVE, "
                          + "the panel toggle, MONO and the sliders.\n\nLeft alone on purpose: "
                          + "meter green/amber/red (the colour *is* the level), the "
                          + "RAVENNA/Dante/SAP tints (they identify the transport), solo yellow "
                          + "(it has to stay distinct from Active) and mute red. Light and dark "
                          + "still decide the shading — this tints it, it does not replace it.")
        }
        .formStyle(.grouped)
    }
}

private struct ViewPane: View {
    @Environment(AppState.self) var state

    var body: some View {
        Form {
            Section {
                LabeledContent("Window") {
                    Picker("", selection: Bindable(state).viewMode) {
                        ForEach(ViewMode.allCases) { mode in Text(mode.label).tag(mode) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 210)
                }
                LabeledContent("Stream list") {
                    Picker("", selection: Bindable(state).detailLevel) {
                        ForEach(DetailLevel.allCases) { level in Text(level.label).tag(level) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 210)
                }
                Explainer(title: "What the two densities show",
                          text: "Simple is name, source, channels, where it goes, its level "
                              + "and its trim. Detailed adds the arrival figures the receiver "
                              + "already keeps — jitter, worst jitter, buffer, low water, "
                              + "drift, lost packets, underruns — as a column in the list and "
                              + "a block under the stream you have open.")
                Toggle("Show dry/wet on inserts", isOn: Bindable(state).showInsertMix)
                // Sidebar or row: the row is narrower, for a small window.
                // Not offered in the Audio Unit, which always uses the row.
                if !AudioOutput.hostMode {
                    LabeledContent("Stream filter") {
                        Picker("", selection: Bindable(state).sourceFilterPlacementSetting) {
                            ForEach(SourceFilterPlacement.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 260)
                    }
                    .help("Where the full window's stream filter sits: a sidebar on the left, or a "
                        + "row above the list, which leaves the window narrower.")
                }
                Toggle("Show level history", isOn: Bindable(state).showLevelHistory)
                    .help("The last 30 seconds of the output under the meters. A red mark is a "
                        + "moment when a stream's audio stopped arriving or its buffer ran out — "
                        + "a dropout you may have heard. Costs next to nothing; turn it off here.")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The dry/wet slider is hidden by default — it is the widest control in "
                       + "an insert row and the least reached for, and Δ answers what it is "
                       + "usually opened for. Hiding it does not change any balance already set.")
                    Text(LocalizedStringKey("Any slider in the app returns to its default on a **double-click** — "
                       + "monitor level to unity, a stream's trim to 0 dB, a dry/wet to fully "
                       + "wet, the buffer to 15 ms."))
                }
                .font(.caption2).foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                LabeledContent("Meter refresh") {
                    HStack(spacing: 6) {
                        Picker("", selection: Bindable(state).meterHz) {
                            Text("20").tag(20)
                            Text("30").tag(30)
                            Text("60").tag(60)
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 140)
                        Text("fps").font(.caption).foregroundStyle(Color.mutedLabel)
                        Spacer(minLength: 0)
                    }
                }
            } footer: {
                Text("The app's largest cost by a wide margin — 60 fps runs about three times the "
                   + "CPU of 30.")
                    .font(.caption2).foregroundStyle(Color.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Explainer(title: "Why the refresh rate costs so much",
                      text: "Every meter redraw makes the window compose a frame, so the rate "
                          + "matters far more than what is being drawn: on one 8-channel stream "
                          + "with the panel open, **60 fps costs about 15 % of a core against "
                          + "4 % at 30**. 30 is the default because that is where the curve "
                          + "flattens and the bars still read as continuous.")
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shared

