import SwiftUI

/// The Receive / Send window: "Connect / Send…" on the list bar
/// opens it, non-modal, so the list stays usable beside it. Each tab says first which way the
/// audio goes — the one thing a first-time user could not tell from the old guide.
///
/// Not in the Audio Unit: there the guide stays a sheet (a host window has no scenes of its own).
struct ConnectSendWindow: View {
    static let id = "connect-send"
    @Environment(AppState.self) var state
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("", selection: $state.connectTab) {
                    Text("Receive").tag(0)
                    Text("Send").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                Spacer()
                QuickStartLink()
                if let send = state.send { GrabberSendPill(send: send) }
            }
            ConnectDirection(sending: state.connectTab == 1)
            // The one question first: here, the guide as it was; somewhere else, the
            // remote guide. The place to set up anything the app cannot find by itself.
            WhereQuestion(choice: $state.connectWhere, tint: state.tintActive)
            if state.connectWhere == 1 {
                ScrollView { RemoteGuide(sending: state.connectTab == 1) }
            } else if state.connectTab == 1, let send = state.send {
                GrabberSendTab(send: send)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
            } else {
                // The guide, full width in the same panel as the Send tab's.
                ScrollView { ConnectToSender(embedded: true) }
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
            }
        }
        .padding(16)
        .frame(minWidth: 460, idealWidth: 480, minHeight: 520, idealHeight: 600, alignment: .topLeading)
        .grabberLook(state)
        .background(state.surfaceWash(scheme))
    }
}

/// Which way the audio goes, said before anything else.
struct ConnectDirection: View {
    @Environment(AppState.self) var state
    let sending: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: sending ? "arrow.up.forward.circle.fill" : "arrow.down.backward.circle.fill")
                .font(.system(size: 22)).foregroundStyle(state.tintActive)
            VStack(alignment: .leading, spacing: 2) {
                Text(sending ? "Send this Mac's audio to other receivers"
                             : "Receive from Network Audio Sender on another Mac")
                    .font(.system(size: 13, weight: .semibold))
                Text(sending ? "For another Grabber, Voicemeeter or any VBAN receiver. Everything this Mac "
                               + "plays goes to the receivers you turn on, except what this Grabber plays."
                             : "For a Mac running Network Audio Sender. Its stream appears in this "
                               + "Grabber's list; AES67, RAVENNA and Dante need nothing here.")
                    .font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

/// The Send section along the bottom of the full window: a handle to size it against the stream
/// list (up to about 40% of the column), then the section itself. Folded, one line.
struct SendBottomSection: View {
    @Environment(AppState.self) var state
    let send: GrabberSend
    /// The height of the column it shares with the list, for the 40% ceiling.
    let columnHeight: CGFloat
    @State private var dragStart: Double?
    /// The height while dragging; saved to `sendHeight` (and the defaults) once, when it ends.
    @State private var dragging: Double?

    static let headerHeight: CGFloat = 36
    static let minimumOpen: CGFloat = 120

    private var ceiling: CGFloat { max(Self.minimumOpen, columnHeight * 0.4) }

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            handle
            GrabberSendSection(send: send, open: $state.sendOpen)
                .frame(height: state.sendOpen
                       ? min(max(CGFloat(dragging ?? state.sendHeight), Self.minimumOpen), ceiling)
                       : Self.headerHeight,
                       alignment: .top)
                .clipped()
        }
    }

    private var handle: some View {
        ZStack {
            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 7)
            Capsule().fill(Color.primary.opacity(0.25)).frame(width: 36, height: 3)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            guard state.sendOpen else { return }
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { drag in
                guard state.sendOpen else { return }
                let start = dragStart ?? min(max(state.sendHeight, Double(Self.minimumOpen)), Double(ceiling))
                dragStart = start
                dragging = min(max(start - drag.translation.height, Double(Self.minimumOpen)),
                               Double(ceiling))
            }
            .onEnded { _ in
                if let dragging { state.sendHeight = dragging }
                dragging = nil
                dragStart = nil
            })
        .help(state.sendOpen ? "Drag to make the Send area taller or shorter." : "")
        .accessibilityHidden(true)
    }
}

/// The "Sending · N" pill as a button: it takes you to the controls.
struct SendPillButton: View {
    let send: GrabberSend
    let action: () -> Void

    var body: some View {
        Button(action: action) { GrabberSendPill(send: send) }
            .buttonStyle(.plain)
    }
}

/// "● Receiving · 3", the Receive side's counterpart, for the compact window's Send tab: only
/// while something is playing; amber when one of them has a problem.
struct ReceivingPill: View {
    @Environment(AppState.self) var state
    let action: () -> Void

    var body: some View {
        let playing = state.subscribed.count
        if playing > 0 {
            let ok = state.subscribed.allSatisfy { state.isReceiving($0) }
            Button(action: action) {
                HStack(spacing: 5) {
                    Circle().fill(ok ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(verbatim: "Receiving · \(playing)")
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(ok ? Color.primary : Color.orange)
                }
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help(ok ? "Streams playing. Receive has them." : "A stream playing has no audio arriving. Receive says which.")
        }
    }
}

/// The connection guide as a sheet, for the Grabber plugin (a DAW gives no window to open):
/// where the other end is, then today's guide or the remote one — receiving only.
struct PluginConnectSheet: View {
    @Environment(AppState.self) var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Connect").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            WhereQuestion(choice: $state.connectWhere, tint: state.tintActive)
            ScrollView {
                if state.connectWhere == 1 {
                    RemoteGuide(sending: false)
                } else {
                    ConnectToSender(embedded: true)
                }
            }
        }
        .padding(18)
        .frame(width: 460, height: 620)
    }
}

extension View {
    /// The Grabber's colours and skin, for a window of its own (the main window sets these on
    /// `ContentView`).
    func grabberLook(_ state: AppState) -> some View {
        self
            .preferredColorScheme(state.skin.style.appearance ?? state.appearance.colorScheme)
            .tint(state.tintActive)
            .toggleStyle(ThemedSwitchStyle(tint: state.tintActive))
            .environment(\.skin, state.skin)
    }
}
