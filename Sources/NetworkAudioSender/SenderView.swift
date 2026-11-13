import SwiftUI
import AppKit

/// The Sender's one window: what is being captured, and where it is going.
///
/// Deliberately short on controls. Sending needs an address and nothing else — the port is
/// VBAN's own unless changed — so the window is the address field, the list of targets and a
/// pair of meters. Everything that is set once lives in Settings.
struct SenderView: View {
    @Environment(SenderState.self) var state
    @Environment(\.colorScheme) private var scheme
    @State private var connecting = false
    @State private var askingTrust = false
    /// The main column's natural height, so the window's floor is the content rather than a
    /// number: a fixed 460 fitted an empty Sender and nothing else, so a listener, a request or
    /// a target put a scroll bar in a window that had room to grow.
    @State private var contentHeight: CGFloat = 0

    /// Past this the column scrolls rather than the window outgrowing the screen.
    private var tallest: CGFloat { (NSScreen.main?.visibleFrame.height ?? 800) - 160 }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if state.showSettings {
                SenderSettings()
            } else {
                ScrollView {
                    // What is going out, as a headline; anyone asking, apart;
                    // everyone receiving, in one list; the inserts folded. The Grabber's compact
                    // window is the model — data first, words only where they earn it.
                    VStack(alignment: .leading, spacing: 0) {
                        // Shared with the Grabber's Send area.
                        SendControls()
                        Divider()
                        SenderInserts()
                        Divider()
                    }
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { contentHeight = g.size.height }
                            .onChange(of: g.size.height) { _, h in contentHeight = h }
                    })
                }
                .frame(minHeight: min(contentHeight, tallest))
                Divider()
                statusBar
            }
        }
        .frame(minWidth: 460, minHeight: 460)
        .background(WindowFloor(trigger: contentHeight))
        .sheet(isPresented: $connecting) { ConnectToGrabber().environment(state) }
        .trustNotice(isPresented: $askingTrust) { connecting = true }
        .onChange(of: state.connectGuideRequested) { _, asked in
            guard asked else { return }
            state.connectGuideRequested = false
            openConnectGuide()
        }
        .background(state.theme.surfaceWash(scheme))
        .preferredColorScheme(state.skin.style.appearance ?? state.appearance.colorScheme)
        .tint(state.theme.active(on: scheme))
        // Every switch in the scheme's colour: macOS 26 ignores `.tint` on its own.
        .toggleStyle(ThemedSwitchStyle(tint: state.theme.active(on: scheme)))
        .environment(\.skin, currentSkin)
    }

    /// Which networks the offer announces on: every local network, or any chosen set of them —
    /// a Mac can be on several at once. The Grabber's interface menu, for the Sender; "Send to"
    /// targets go wherever this Mac routes them.
    private var networkMenu: some View {
        let networks = state.networks
        let chosen = state.offerInterfaces
        let up = Set(networks.map(\.name))
        let missing = chosen.subtracting(up).sorted()
        let live = chosen.isEmpty || !chosen.isDisjoint(with: up)
        // One name; two as "en0 / en5"; more as "en0 / en5 / +2".
        let names = chosen.sorted()
        let title = chosen.isEmpty ? "All networks"
            : (names.count <= 2 ? names.joined(separator: " / ")
                                : names.prefix(2).joined(separator: " / ") + " / +\(names.count - 2)")
        return Menu {
            Button {
                state.offerInterfaces = []
            } label: {
                if chosen.isEmpty { Label("All networks", systemImage: "checkmark") } else { Text("All networks") }
            }
            Divider()
            ForEach(networks, id: \.name) { n in
                Button {
                    var next = chosen
                    if next.contains(n.name) { next.remove(n.name) } else { next.insert(n.name) }
                    state.offerInterfaces = next
                } label: {
                    let text = "\(n.name) — \(n.address)"
                    if chosen.contains(n.name) { Label(text, systemImage: "checkmark") } else { Text(text) }
                }
            }
            if !missing.isEmpty {
                Divider()
                ForEach(missing, id: \.self) { name in
                    Button { state.offerInterfaces.remove(name) } label: {
                        Label("\(name) — not connected", systemImage: "checkmark")
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(live ? Color.green : Color.orange).frame(width: 6, height: 6)
                Text(title).font(.system(size: 12, weight: .medium))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(tooltip("Where the offer to Grabbers is announced: every network this Mac is on, or "
                    + "the ones ticked — as many as you like. Addresses under Send to are reached "
                    + "whichever are chosen.",
                      now: chosen.isEmpty ? "All networks."
                         : (live ? "\(chosen.sorted().joined(separator: ", "))"
                                   + (missing.isEmpty ? "." : " (\(missing.joined(separator: ", ")) not connected).")
                                 : "None of the chosen networks is connected, so the offer is not announced.")))
    }

    /// The guide, after the notice that VBAN is not encrypted unless that was turned off.
    private func openConnectGuide() {
        if UserDefaults.standard.bool(forKey: TrustNotice.skipKey) { connecting = true } else { askingTrust = true }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            // No name here: the title bar carries it. The emblem says which app this is, as the
            // Grabber's header does.
            AppEmblem(.sender, size: 22, caption: .beside)
            Divider().frame(height: 18)
            networkMenu
            Divider().frame(height: 14)
            // What is being sent: the Source menu — system audio by default — and,
            // for system audio, the output device and its rate, as before.
            SourceMenu(compact: true)
            HStack(spacing: 5) {
                if state.outputRate > 0 && !state.sendSource.isInput {
                    Text(String(format: "%.4g kHz", Double(state.outputRate) / 1000))
                        .font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(state.outputRate == 48000 || state.outputRate == 44100
                                         ? Color.secondary : Color.orange)
                }
            }
            .help(tooltip("The output device this Mac is playing to, which is what the Sender "
                        + "captures, and the rate it runs at. Change it in macOS's Sound settings.",
                          now: state.outputDeviceName))
            Spacer(minLength: 6)
            Button { state.showSettings.toggle() } label: {
                Image(systemName: "gearshape").font(.system(size: 12))
                    .foregroundStyle(state.showSettings ? state.theme.active(on: scheme) : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(state.showSettings ? "Back to sending (⌘,)" : "Settings (⌘,)")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }


    // MARK: - What is being captured

    /// The stream, as the compact Grabber shows its output: the name large (click it, or the
    /// pencil, to rename), this Mac's address beside it for anyone connecting by hand, the
    /// level under it, and the format as one small line.
    // MARK: - Status

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.isActive ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            // Its own view: the bitrate in it changes while sending, and read here it
            // re-evaluated the whole window each time.
            SenderStatusText()
                .lineLimit(1)
            Spacer()
            // The same button, in the same place, as the Grabber's status bar: the steps for a
            // Grabber on this network, and the other ways to connect.
            Button(action: openConnectGuide) {
                Label("Connect…", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Steps for Network Audio Grabber on the same network, over VBAN — the one protocol the "
                + "Sender sends — and the other ways to connect.")
            if state.isActive {
                // Stops the offer too: "stop all" means nothing leaves this Mac.
                Button("Stop all") { state.stopAll() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private var currentSkin: Skin {
        let skin = state.skin
        if Skin.current != skin { Skin.current = skin }
        return skin
    }

    /// The Grabber's section heading, in sentence case.
    static let headingFont = Font.system(size: 12, weight: .semibold)

}

/// One target, a single line in the Grabber's stream-row idiom: favourite star, on/off, the
/// address, then the per-target options.
struct TargetRow: View {
    @Environment(\.skin) private var skin
    @Environment(SenderState.self) var state
    @Environment(\.colorScheme) private var scheme
    let target: SendTarget
    @State private var naming = false
    @State private var draftName = ""

    private var on: Bool { state.isSending(target.id) }

    var body: some View {
        HStack(spacing: 8) {
            Button { state.toggleSending(target.id) } label: {
                PlayStopIcon(active: on, tint: state.theme.active(on: scheme), size: 17)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .help(on ? "Stop sending to \(target.label)" : "Send to \(target.label)")
            .accessibilityLabel(on ? "Stop sending to \(target.label)" : "Send to \(target.label)")

            VStack(alignment: .leading, spacing: 0) {
                // Your own name wins; failing that, the name the Grabber at this address
                // reported; failing that, the address.
                let reported = state.reportedName(for: target.host)
                let shown = target.name ?? reported
                HStack(spacing: 4) {
                    Text(verbatim: shown ?? target.address)
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                        .help(target.name != nil ? "\(target.address). Double-click to rename."
                              : reported != nil ? "\(target.address), as the Grabber there names itself. "
                                                  + "Double-click to give it your own name."
                              : "Double-click to give this a name.")
                        .onTapGesture(count: 2) { beginNaming() }
                        .popover(isPresented: $naming, arrowEdge: .bottom) { namePopover }
                    if target.favourite {
                        Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(Color.yellow)
                            .help("Favourite: pinned to the top of the list.")
                    }
                    // Only when it is on, and then in the accent: it changes who receives, so it
                    // is worth seeing, and a faint pill on every row that is not broadcasting
                    // was noise.
                    // Another location, over the internet.
                    ConnectionBadge(address: target.host)
                    if target.broadcast {
                        Chip(text: "BCAST", tint: state.theme.active(on: scheme), filled: true)
                            .help("Broadcasting: every receiver on this address's network gets it.")
                    }
                }
                // The address under a name; where it is broadcasting, where it really goes.
                if target.broadcast, let destination = state.destination(of: target) {
                    Text(verbatim: "broadcast \(destination)")
                        .font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(Color.mutedLabel)
                } else if shown != nil {
                    Text(verbatim: target.address)
                        .font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(Color.mutedLabel)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if on, state.unreachableTargets.contains(target.id) {
                ReceiverStatus(text: "Unreachable", symbol: "exclamationmark.triangle.fill",
                               tint: skin.style.warning ?? .orange)
                    .help("This Mac cannot reach \(target.address): the network says the host is down "
                        + "or has no route. Still sending; it picks up as soon as the host is back."
                        + (state.autoStopSends
                           ? " Auto-stop stops it after \(SenderState.minutesText(state.autoStopSendsMinutes)) (\(state.settingsPath))."
                           : ""))
            } else if !on, let note = state.autoStopNote(target.id) {
                ReceiverStatus(text: "Timed out", symbol: "timer", tint: skin.style.warning ?? .orange)
                    .help(note)
            } else {
                ReceiverStatus(text: on ? "Sending" : "Stopped",
                               symbol: on ? "arrow.up.forward.circle" : "pause.circle",
                               tint: on ? Color.secondary : Color.mutedLabel)
            }

            PillToggle(title: "M",
                       isOn: Binding(get: { target.muted }, set: { _ in state.toggleMuted(target.id) }),
                       tint: skin.style.mute ?? .red,
                       help: tooltip("Mute: send silence, so the receiver keeps the stream listed.",
                                     now: target.muted ? "muted" : "sending audio"),
                       spokenName: "Mute")
                .frame(width: ReceiverStatus.muteWidth)

            Menu { menuItems } label: {
                Image(systemName: "ellipsis").font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(Color.mutedLabel)
            .frame(width: ReceiverStatus.moreWidth)
            .help("Broadcast, rename, favourite, remove")
            .accessibilityLabel("More for \(target.label)")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .contentShape(Rectangle())
        .contextMenu { menuItems }
    }

    /// Everything a target can have done to it besides play and mute, in one menu — the row's
    /// "…" and a right-click both open it.
    @ViewBuilder private var menuItems: some View {
        // Broadcasting is Broadcast… now; only an older target switched to it by
        // hand keeps a way back to its one address.
        if target.broadcast, target.networkSignature == nil {
            Button("Stop broadcasting") { state.toggleBroadcast(target.id) }
            Divider()
        }
        Button(target.name == nil ? "Name…" : "Rename…") { beginNaming() }
        if let reported = state.reportedName(for: target.host), reported != target.name {
            Button("Use reported name “\(reported)”") { state.rename(target.id, to: reported) }
        }
        Button("Copy address") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(target.address, forType: .string)
        }
        Button(target.favourite ? "Remove from favourites" : "Add to favourites") {
            state.toggleFavourite(target.id)
        }
        Divider()
        Button("Remove") { state.remove(target.id) }
    }

    private func beginNaming() {
        draftName = target.name ?? ""
        naming = true
    }

    private var namePopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: target.address)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.mutedLabel)
            TextField("Name, e.g. Studio PC", text: $draftName)
                .plainEntry()
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit { naming = false }
            Text("Shown only on this Mac. Leave blank to show the address.")
                .font(.system(size: 9))
                .foregroundStyle(Color.mutedLabel)
        }
        .padding(10)
        // However it closes (Return, a click away, Esc), what was typed is kept, as the stream
        // name field keeps its text when it loses focus.
        .onDisappear { state.rename(target.id, to: draftName) }
    }
}


/// A Grabber listening because it asked and was allowed: a row in the same columns as a target,
/// with the headphones where a target's star and play button sit.
struct ListenerRow: View {
    @Environment(SenderState.self) var state
    let listener: VBANOffer.Subscriber

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "headphones").font(.system(size: 12))
                .foregroundStyle(Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(verbatim: listener.name ?? listener.ip)
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                    ConnectionBadge(address: listener.ip, encrypted: state.remoteLinks.contains("\(listener.ip):\(listener.port)"))
                }
                if listener.name != nil {
                    Text(verbatim: listener.ip)
                        .font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(Color.mutedLabel)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ReceiverStatus(text: "Listening", symbol: "checkmark.circle", tint: .secondary)
            Color.clear.frame(width: ReceiverStatus.muteWidth, height: 1)
            Menu { menuItems } label: {
                Image(systemName: "ellipsis").font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(Color.mutedLabel)
            .frame(width: ReceiverStatus.moreWidth)
            .accessibilityLabel("More for \(listener.name ?? listener.ip)")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .contentShape(Rectangle())
        .contextMenu { menuItems }
        .help("Listening: \(listener.name.map { "\($0) at " } ?? "")\(listener.ip). "
            + "Name as that Grabber reports it. Allowed Grabbers are under Settings.")
    }

    @ViewBuilder private var menuItems: some View {
        Button("Copy address") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(listener.ip, forType: .string)
        }
        Divider()
        // Allowed Grabbers are remembered; this is the way to un-remember one from here.
        Button("Stop and forget this Grabber") { state.revoke(listener.ip) }
    }
}

/// How a receiver is getting the stream, as a word and a symbol — the Grabber's status column.
struct ReceiverStatus: View {
    /// The mute and "…" columns, so every row's status lands in the same place.
    static let muteWidth: CGFloat = 26
    static let moreWidth: CGFloat = 16
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11))
            .foregroundStyle(tint)
            .lineLimit(1)
            // "Unreachable" is the longest, with its symbol.
            .frame(width: 98, alignment: .leading)
    }
}

/// The stream name, committed **when editing ends** — Return, or leaving the field — not on
/// every keystroke. The name is on the wire the moment it changes, and typing "Mac Audio Test"
/// live sent "Mac Audio T", "Mac Audio Te"… each of which a receiver listed as a new stream.
struct StreamNameField: View {
    @Environment(SenderState.self) var state
    /// Opened to be edited (the name is a headline, and this appears in its place), so it
    /// takes the focus rather than giving it back.
    var autofocus = false
    /// Editing has ended, however — Return, Esc or a click away.
    var onDone: () -> Void = {}
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Mac Audio", text: $draft)
            .plainEntry()
            .focused($focused)
            .onSubmit(commit)
            .onExitCommand { draft = state.streamName; onDone() }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onAppear {
                draft = state.streamName
                if autofocus {
                    DispatchQueue.main.async { focused = true }
                    return
                }
                // The window would open with this field focused, as the first text field in it,
                // and macOS then starts its text services for it: a suggestion panel that sat
                // empty under the field for ~30 s was seen at launch. Nobody opens
                // the Sender to rename the stream, so give the focus back once it has been set.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = false }
            }
            .onChange(of: state.streamName) { _, name in if !focused { draft = name } }
            .help(tooltip("What receivers list this stream as — up to 16 plain characters. "
                          + "Takes effect on Return, or on leaving the field.",
                          now: VBAN.wireName(state.streamName)))
    }

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { draft = state.streamName; onDone(); return }
        if name != state.streamName { state.streamName = name }
        onDone()
    }
}

/// Grows the window to its content's minimum when that rises past the window's height. AppKit
/// applies a raised `contentMinSize` to later resizes only, never to the frame it holds, so
/// without this a new row would still arrive as a scroll bar. Never shrinks the window: the
/// size someone chose is theirs. The same rule as the Grabber's `WindowShaper`.
private struct WindowFloor: NSViewRepresentable {
    let trigger: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // Next turn of the main queue: SwiftUI sets the window's minimum from the content
        // after this update, not during it.
        DispatchQueue.main.async {
            guard let window = view.window, !window.inLiveResize else { return }
            let content = window.contentRect(forFrameRect: window.frame)
            let floor = window.contentMinSize.height
            guard content.height < floor - 1 else { return }
            var frame = window.frame
            let grow = floor - content.height
            frame.size.height += grow
            frame.origin.y -= grow                 // the top edge stays where it is
            if let screen = window.screen?.visibleFrame, frame.minY < screen.minY {
                frame.origin.y = screen.minY
            }
            window.setFrame(frame, display: true, animate: true)
        }
    }
}

/// "Sending to 2 targets and 2 listening · 256 kbit/s", in a view of its own so the figure
/// changing re-evaluates this line and nothing else.
private struct SenderStatusText: View {
    @Environment(SenderState.self) var state

    var body: some View {
        Text(statusText).font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
    }

    private var statusText: String {
        guard state.isActive else { return state.offering ? "Offering, nobody listening" : "Not sending" }
        let n = state.sending.count, l = state.listeners.count
        let rate = state.bitrateKbps >= 1000 ? String(format: "%.1f Mbit/s", state.bitrateKbps / 1000)
                                             : String(format: "%.0f kbit/s", state.bitrateKbps)
        var parts: [String] = []
        if n > 0 { parts.append("\(n) target\(n == 1 ? "" : "s")") }
        if l > 0 { parts.append("\(l) listening") }
        return "Sending to " + parts.joined(separator: " and ") + " · \(rate)"
    }

}

/// What is sent and who receives it: this Mac's stream (name, meter, notes), anyone asking, and
/// the receivers. The Sender's window is built round it, and so is the Grabber's Send area — the same view, so the two cannot drift apart. `twoColumn` puts the stream on the
/// left and the receivers beside it, for the Grabber's section along the bottom.
struct SendControls: View {
    @Environment(SenderState.self) var state
    var twoColumn = false
    @State private var renaming = false
    @State private var adding = false
    @State private var broadcasting = false

    var body: some View {
        if twoColumn {
            HStack(alignment: .top, spacing: 0) {
                source.frame(width: 320, alignment: .topLeading)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        requestList
                        receivers
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                source
                requestList
                Divider()
                receivers
            }
        }
    }

    @ViewBuilder private var requestList: some View {
        if !state.requests.isEmpty {
            VStack(spacing: 6) {
                ForEach(state.requests) { RequestRow(request: $0) }
            }
            .padding(.horizontal, 12).padding(.bottom, 10).padding(.top, twoColumn ? 8 : 0)
        }
    }

    private var source: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if renaming {
                    StreamNameField(autofocus: true, onDone: { renaming = false })
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 15))
                        .frame(maxWidth: 240)
                } else {
                    Button { renaming = true } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: VBAN.wireName(state.streamName).isEmpty ? "Mac Audio" : state.streamName)
                                .font(.system(size: 20, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "pencil").font(.system(size: 11))
                                .foregroundStyle(Color.mutedLabel)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tooltip("What receivers list this stream as — up to 16 plain characters. "
                                  + "Click to rename; it takes effect on Return.",
                                  now: VBAN.wireName(state.streamName)))
                }
                Spacer(minLength: 8)
                Text(formatDetail).font(.system(size: 10)).monospacedDigit()
                    .foregroundStyle(Color.mutedLabel)
                    .fixedSize()
            }
            // The Grabber's Send has no header of its own: its Source menu sits here.
            // The Sender's is in its header.
            if state.onDemand && !state.sendsTrack { SourceMenu() }
            // Where this Mac is, for a Grabber added by hand (over a VPN, say) and for any other
            // VBAN receiver: the one fact the guide's "manual" route needs.
            if !state.localAddresses.isEmpty {
                Text(verbatim: "This Mac: " + state.localAddresses.joined(separator: ", "))
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(Color.mutedLabel)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help("This Mac's address on each network it is on. A Grabber adds it by hand "
                        + "under Settings → Discovery (port \(VBANControl.controlPort)); Connect… "
                        + "has the steps.")
            }
            // One bar per channel captured: two on a stereo output, six or eight on a surround
            // one, labelled as the compact Grabber's output is.
            let channels = state.captureChannels
            let slot: CGFloat = channels <= 2 ? 11 : max(3, 44 / CGFloat(channels))
            HStack(spacing: 6) {
                if channels <= 2 {
                    VStack(spacing: 0) {
                        ForEach(["L", "R"], id: \.self) { name in
                            Text(verbatim: name)
                                .font(.system(size: 8, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.mutedLabel)
                                .frame(width: 13, height: slot)
                        }
                    }
                }
                MeterStrip(count: channels, orientation: .horizontal,
                           thickness: max(2, slot - 4), slot: slot,
                           length: 400, fps: 30, paused: !state.isActive,
                           level: { state.level($0) },
                           // Dots while nothing is being captured, so an idle Sender does not
                           // read as one sending silence.
                           noData: { [state] in !state.isActive })
                    .frame(maxWidth: .infinity)
                    .frame(height: slot * CGFloat(channels))
                    .id(channels)
            }
            .help(tooltip((state.sendsTrack ? "What is being sent — this track's audio, as it reaches the plugin."
                                             : "What is being sent — this Mac's audio, as captured.")
                          + " Green to −18 dBFS, amber to −6, red above.",
                          now: state.isActive ? (state.sendsTrack ? "sending" : "capturing")
                                              : (state.sendsTrack ? "not sending" : "not capturing")))
            if state.captureBlocked {
                HStack(alignment: .top, spacing: 8) {
                    Label("macOS has not let Network Audio Sender capture this Mac's audio yet. "
                          + "Allow it under Privacy & Security → Screen & System Audio Recording, "
                          + "in the System Audio Recording Only list, then stop and start sending.",
                          systemImage: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Settings") { state.openPrivacySettings() }
                        .controlSize(.small)
                }
            } else if let note = captureNote {
                Label(note.text, systemImage: note.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(note.warning ? Color.orange : Color.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
    }

    private var formatDetail: String {
        let bits = state.dataType == .int24 ? "24-bit" : "16-bit"
        if case .running(let rate, let channels) = state.captureStatus {
            let khz = String(format: "%.4g kHz", Double(rate) / 1000)
            return "\(bits) · \(khz) · \(channels == 2 ? "stereo" : "\(channels) ch")"
        }
        return bits
    }

    private var captureNote: (text: String, symbol: String, warning: Bool)? {
        switch state.captureStatus {
        case .failed(let message):
            return (message, "exclamationmark.triangle.fill", true)
        default:
            break
        }
        if let rate = state.unsupportedRate, state.sendsTrack {
            return ("The project is at \(rate) Hz, which VBAN cannot carry. Set the project to "
                    + "44.1 or 48 kHz.", "exclamationmark.triangle.fill", true)
        }
        if state.sendsTrack {
            // A DAW runs a plugin only while it plays or monitors the track; the Sender fills
            // the gaps with silence, so receivers stay connected meanwhile.
            return state.quietForAWhile
                ? ("The track has been silent for a while. Most DAWs only run a plugin while the "
                   + "track plays or is monitored; receivers stay connected meanwhile.", "info.circle", false)
                : nil
        }
        if let rate = state.unsupportedRate {
            return ("This Mac is running at \(rate) Hz, which VBAN cannot carry. Set the output "
                    + "device to 44.1 or 48 kHz in Audio MIDI Setup.", "exclamationmark.triangle.fill", true)
        }
        if state.quietForAWhile {
            return ("Another app is playing, but nothing is arriving here. Allow Network Audio Sender under "
                    + "System Settings → Privacy & Security → Screen & System Audio Recording.",
                    "info.circle", false)
        }
        if state.muteThisMac && state.isActive {
            return ("This Mac's speakers are muted while sending.", "speaker.slash", false)
        }
        return nil
    }

    // MARK: - Who receives it

    /// **One list of everyone the audio reaches.** The switch that makes this Mac
    /// findable sits in the heading it governs, and + adds a receiver by address — two routes to
    /// the same list, in one place, where they were two sections with a paragraph each.
    private var receivers: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Receivers").font(SenderView.headingFont).foregroundStyle(Color.mutedLabel)
                Spacer(minLength: 6)
                Toggle(isOn: Bindable(state).offering) {
                    Text("Findable by Grabbers").font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                }
                .controlSize(.mini)
                .fixedSize()
                .help(tooltip("Grabbers on this network list the stream, and it goes to each one "
                            + "that listens, and to nobody else. Anyone on the network can ask for "
                            + "it, so every listener is shown here.",
                              now: state.offering ? "findable" : "off"))
                // Everyone on a network at once, with nothing typed.
                Button("Broadcast…") { broadcasting = true }
                    .controlSize(.small)
                    .disabled(state.broadcastNetworks.isEmpty)
                    .help("Send to every VBAN receiver on a network at once — several Grabbers, Voicemeeter.")
                    .sheet(isPresented: $broadcasting) { BroadcastSheet().environment(state) }
                Button { adding = true } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.mutedLabel)
                .help("Add a receiver by address — another VBAN receiver such as Voicemeeter, or a "
                    + "Grabber this Mac cannot find on its own.")
                .accessibilityLabel("Add a receiver by address")
                .popover(isPresented: $adding, arrowEdge: .bottom) { addPopover }
            }
            .padding(.horizontal, 12).frame(height: 36)

            // Listeners first (they came to you), then your own targets, favourites at the top.
            let listeners = state.offering ? state.listeners : []
            let targets = state.targets.sorted { $0.favourite && !$1.favourite }
            if !listeners.isEmpty || !targets.isEmpty {
                VStack(spacing: 0) {
                    ForEach(listeners) { listener in
                        ListenerRow(listener: listener)
                        Divider().opacity(0.5).padding(.leading, 40)
                    }
                    ForEach(targets) { target in
                        TargetRow(target: target)
                        Divider().opacity(0.5).padding(.leading, 40)
                    }
                }
            } else {
                Text(state.offering
                     ? "Nobody is listening yet. Grabbers on this network now list “\(VBAN.wireName(state.streamName))”."
                     : "Nobody is receiving. Turn on Findable so Grabbers on this network can list "
                       + "this Mac, or add a receiver by address with +.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
    }

    /// The address entry, out of the window until it is wanted.
    private var addPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a receiver").font(.system(size: 12, weight: .semibold))
            HStack(spacing: 6) {
                TextField("Receiver IP address", text: Bindable(state).draftHost)
                    .plainEntry()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit(add)
                Text(":").foregroundStyle(Color.mutedLabel)
                TextField("Port", text: Bindable(state).draftPort)
                    .plainEntry()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                    .onSubmit(add)
                Button(remoteDraft ? "Add anyway" : "Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.draftHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error = state.draftError {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange)
            }
            // An address outside this Mac's networks: allowed, and said to be the advanced way.
            if remoteDraft {
                RemoteWarning(receivingEnd: false).frame(width: 300)
            }
            Text("For another VBAN receiver, such as Voicemeeter. A Grabber on this network needs "
               + "nothing typed: turn on Findable instead.")
                .font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 300, alignment: .leading)
        }
        .padding(12)
    }

    private func add() {
        state.addDraft()
        if state.draftError == nil { adding = false }
    }

    private var remoteDraft: Bool { RemoteAddresses.isRemote(RemoteAddresses.host(state.draftHost)) }

}


/// **Broadcast on this network**: every VBAN receiver on the chosen
/// network hears it. Kept on only on that same network.
struct BroadcastSheet: View {
    @Environment(SenderState.self) var state
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: String?
    @State private var keepOn = false

    var body: some View {
        let networks = state.broadcastNetworks
        // The first one not broadcast to yet, unless one is chosen (pressing it again said nothing when every network already was).
        let network = networks.first { $0.name == chosen }
            ?? networks.first { !state.isBroadcasting(on: $0) } ?? networks.first
        let wifi = network.map { NetworkIdentity.isWiFi($0.name) } ?? false
        let already = network.map(state.isBroadcasting(on:)) ?? false
        let allAlready = !networks.isEmpty && networks.allSatisfy(state.isBroadcasting(on:))
        VStack(alignment: .leading, spacing: 10) {
            Text("Broadcast on this network").font(.system(size: 13, weight: .semibold))
            Text("Every VBAN receiver on the network hears it — several Grabbers, Voicemeeter — with nothing to ask or type.")
                .font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
            if networks.count > 1 {
                HStack {
                    Text("Network").font(.system(size: 11))
                    Picker("", selection: Binding(get: { network?.name }, set: { chosen = $0 })) {
                        ForEach(networks, id: \.name) { n in
                            Text(verbatim: "\(n.name) — \(NetworkIdentity.isWiFi(n.name) ? "Wi-Fi" : "Wired") · \(n.address)"
                                 + (state.isBroadcasting(on: n) ? "  (broadcasting)" : ""))
                                .tag(Optional(n.name))
                        }
                    }
                    .labelsHidden().frame(width: 300)
                }
            } else if let network {
                Text(verbatim: "\(network.name) — \(wifi ? "Wi-Fi" : "Wired") · \(network.address)")
                    .font(.system(size: 11, design: .monospaced))
            }
            if already, let network {
                Label(allAlready && networks.count > 1
                      ? "Already broadcasting on every network this Mac is on. Stop one in the list of targets first."
                      : "Already broadcasting on \(network.name). It is in the list of targets, where it can be stopped.",
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label("Everyone on this network receives the audio. It is not encrypted, and stays on this network — broadcasts don't cross routers.",
                  systemImage: "info.circle")
                .font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
            if wifi {
                Label("Broadcasting on Wi-Fi slows the whole Wi-Fi down. Findable by Grabbers is mostly the better choice there.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Keep broadcasting when opened again", isOn: $keepOn)
                .toggleStyle(.checkbox).font(.system(size: 11))
                .help("Only on this same network: opened on another one, it stays off, and it stops if this Mac leaves the network.")
            Text("Only on this same network: opened elsewhere it stays off, and it stops if this Mac leaves it.")
                .font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Start broadcasting") {
                    if let network { state.startBroadcast(on: network, keepOn: keepOn) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(network == nil || already)
            }
        }
        .padding(16)
        .frame(width: 400)
    }
}
