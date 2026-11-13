import SwiftUI

/// The Sender inside the Grabber: the same `SenderState` and the
/// same `SendControls` as Network Audio Sender, behind a few public pieces the Grabber places —
/// a section along the bottom of its window, a Send tab in its Receive / Send window, a Send tab
/// in its compact window, and a small "Sending" pill.
///
/// **Costs nothing until used.** The state is made on demand (`onDemand`): no tick, no offer
/// thread and no capture until something is sent or offered, and all of it stops again when
/// nothing is. Its settings are its own (a separate suite), so the Grabber's Send and the Sender
/// app keep their own targets and names; its log lines go to the Grabber's log.
/// Main thread only, as `SenderState` is.
public final class GrabberSend {
    let state: SenderState

    /// `hostFeed`: in the Audio Unit, the track to send; nil in the app, which sends the Mac.
    /// `defaultName`: what it is called until renamed — the Grabber's own name, in the app.
    public init(suiteName: String, hostFeed: HostAudioFeed? = nil, defaultName: String? = nil) {
        state = SenderState(defaults: UserDefaults(suiteName: suiteName) ?? .standard, onDemand: true,
                            hostFeed: hostFeed, defaultName: defaultName)
        state.settingsPath = "Settings → Send → Auto-stop"
    }

    /// Adds a receiver by "address" or "address:port" and starts sending to it, as the Send
    /// area's + does. Nil, or what was wrong.
    public func addTarget(_ text: String) -> String? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        state.draftHost = parts.first.map(String.init) ?? ""
        state.draftPort = parts.count > 1 ? String(parts[1]) : String(VBAN.port)
        state.addDraft()
        return state.draftError
    }

    // MARK: Remote link, for the Grabber's guide

    public var remoteCode: RemoteCode? { state.remoteCode }
    public var remoteCodeError: String? { state.remoteCodeError }
    public var makingRemoteCode: Bool { state.makingRemoteCode }
    public func makeRemoteCode() { state.makeRemoteCode() }
    /// RENDER HARNESS only.
    public func setPreviewRemoteCode(_ code: RemoteCode) { state.setPreviewRemoteCode(code) }
    public func setPreviewRemoteLinks(_ links: [String]) { state.setPreviewRemoteLinks(links) }
    public func setPreviewLinksPaused(_ on: Bool) { state.setPreviewLinksPaused(on) }
    public func setPreviewDenied(ip: String, name: String) {
        state.setPreviewDenied([VBANOffer.Subscriber(ip: ip, port: 6980, name: name, cookie: [], lastSeen: 0)])
    }
    public func linkRemote(_ text: String) -> String? { state.linkRemote(text) }
    public var remoteLinks: [String] { state.remoteLinks }
    public var remoteLinkInfo: [RemoteLinkInfo] { state.remoteLinkInfo }
    public var remoteCodeMadeAt: Date? { state.remoteCodeMadeAt }
    public var remoteLinksPaused: Bool { state.remoteLinksPaused }
    public func resumeRemoteLinks() { state.resumeRemoteLinks() }
    public func unlinkRemote(_ key: String) { state.unlinkRemote(key) }

    /// The Grabber was renamed (or, in a DAW, the track): Send follows, unless it has a name of
    /// its own.
    public func grabberRenamed(_ name: String) { state.adoptDefaultName(name) }

    // MARK: A DAW project's copy (the Sender plugin)

    /// What a project keeps for one Sender: its whole setup, apart from the look.
    static let projectKeys = ["streamName", "dataType", "targets", "lastSending", "lastOffering",
                              "offerInstance", "passThrough", "autoStopSends", "autoStopSendsMinutes",
                              "resumeSending", "askBeforeListening", "allowedGrabbers", "offerInterfaces",
                              "reportedNames", "lastRate", "lastChannels"]
    /// What a new Sender starts from: the last one's setup, less what is its own.
    static let ownKeys: Set<String> = ["streamName", "lastSending", "lastOffering", "offerInstance"]

    /// This Sender's settings as a project stores them. Main thread.
    public func projectState() -> [String: Any] {
        var out: [String: Any] = [:]
        for key in Self.projectKeys { if let v = state.defaults.object(forKey: key) { out[key] = v } }
        return out
    }

    /// Fills an empty suite from `template` (a new Sender starts with the last one's receivers).
    public static func seed(suite: String, from template: String) {
        guard let d = UserDefaults(suiteName: suite), d.object(forKey: "targets") == nil,
              let t = UserDefaults(suiteName: template) else { return }
        for key in projectKeys where !ownKeys.contains(key) {
            if let v = t.object(forKey: key) { d.set(v, forKey: key) }
        }
    }

    /// Replaces a suite's settings with a project's copy, before a Sender is made from it.
    public static func load(_ project: [String: Any], into suite: String) {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        guard let d = UserDefaults(suiteName: suite) else { return }
        for key in projectKeys { if let v = project[key] { d.set(v, forKey: key) } }
    }

    /// Keeps this Sender's shared settings as the next new Sender's starting point.
    public func writeBack(to template: String) {
        guard let t = UserDefaults(suiteName: template) else { return }
        for key in Self.projectKeys where !Self.ownKeys.contains(key) {
            if let v = state.defaults.object(forKey: key) { t.set(v, forKey: key) } else { t.removeObject(forKey: key) }
        }
    }

    /// Sending a DAW track rather than this Mac's audio.
    public var sendsTrack: Bool { state.sendsTrack }

    /// Where Send's log lines go: the Grabber's own log.
    public var log: ((ActivityLog.Kind, String) -> Void)? {
        get { state.logSink }
        set { state.logSink = newValue }
    }

    /// Resumes what was being sent at quit if "Resume sending when opened" is on (off unless
    /// chosen); otherwise starts nothing.
    public func start() { state.start() }
    public func shutdown() { state.shutdown() }

    public var isActive: Bool { state.isActive }
    /// Targets being sent to plus Grabbers listening.
    public var receiverCount: Int { state.sending.count + state.listeners.count }
    /// False while sending into silence or while macOS is delivering nothing.
    public var healthy: Bool { !state.captureBlocked && !state.quietForAWhile }
    public var allMuted: Bool {
        get { state.allMuted }
        set { state.allMuted = newValue }
    }
    public func stopAll() { state.stopAll() }

    /// RENDER HARNESS only: made-up targets, listeners and levels, marked as sending without
    /// starting anything (as the Sender's own harness does). Documentation addresses only.
    public static func preview(suiteName: String, sending: Bool, track: Bool = false,
                               statuses: Bool = false) -> GrabberSend {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        let g = GrabberSend(suiteName: suiteName, hostFeed: track ? HostAudioFeed() : nil)
        let state = g.state
        state.applyTheme(ThemePreset.harness)
        state.streamName = track ? "Vox Bus" : "Edit Suite Mac"
        state.previewOutput = ("Studio Monitors", 48000)
        state.previewNetworks = [LocalNetwork(name: "en0", address: "192.0.2.30", netmask: "255.255.255.0",
                                              broadcast: "192.0.2.255")]
        state.previewAddresses = ["192.0.2.30"]
        state.previewLevels = sending ? [0.42, 0.30] : [0, 0]
        state.setPreviewInserts([nil, nil, nil])
        guard sending else { return g }
        state.targets = [
            SendTarget(host: "192.0.2.20", favourite: true, name: "Studio PC"),
            SendTarget(host: "192.0.2.31", favourite: true, muted: true),
            SendTarget(host: "198.51.100.7"),
        ]
        state.setPreviewSending([state.targets[0].id, state.targets[1].id])
        state.setPreviewListeners([
            .init(ip: "192.0.2.40", port: 6980, name: "Control Room", cookie: [], lastSeen: 0),
        ], reported: ["192.0.2.40": "Control Room"], requests: [])
        // Auto-stop's two states on the rows: one sending but unreachable, one it stopped.
        if statuses {
            // A receiver in another location (TEST-NET-3 reads as the internet in the harness).
            state.targets.append(SendTarget(host: "203.0.113.60", name: "Home Laptop"))
            state.setPreviewSending(state.sending.union([state.targets[3].id]))
            state.autoStopSends = true
            state.setPreviewReachability(unreachable: [state.targets[1].id], autoStopped: [state.targets[2].id])
        }
        return g
    }

    /// The tag this process's offer beacons carry, so the Grabber can leave its own Send out of
    /// its list. Set once, when the state is made.
    public static var offerInstance: [UInt8] { VBANOffer.processInstance }

    /// The Grabber's colour scheme, so the Send area matches the window it sits in.
    public func applyTheme(enabled: Bool, primary: String, secondary: String) {
        let t = ThemeChoice(enabled: enabled, primaryHex: primary, secondaryHex: secondary)
        if state.theme != t { state.theme = t }
    }
}

/// "● Sending · 2": only while sending. Green when audio is going out, amber when the Mac is
/// silent or macOS is delivering nothing.
public struct GrabberSendPill: View {
    let send: GrabberSend
    public init(send: GrabberSend) { self.send = send }

    public var body: some View {
        let state = send.state
        if state.isActive {
            let ok = !state.captureBlocked && !state.quietForAWhile
            HStack(spacing: 5) {
                Circle().fill(ok ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(verbatim: "Sending · \(state.sending.count + state.listeners.count)")
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(ok ? Color.primary : Color.orange)
            }
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .help(ok ? "Sending this Mac's audio. The Send area has the controls."
                     : "Sending, but nothing is arriving from this Mac's audio. The Send area says why.")
        }
    }
}

/// The header of the Send section: fold, what is sending, Findable, mute all, stop.
struct GrabberSendHeader: View {
    @Environment(SenderState.self) var state
    @Binding var open: Bool
    /// False in a tab, which is always open.
    var foldable = true

    var body: some View {
        HStack(spacing: 10) {
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    if foldable {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold)).frame(width: 8)
                    }
                    // In a tab the tab already says Send; the label is for the folding section.
                    if foldable { Text("Send").font(.system(size: 12, weight: .semibold)) }
                }
                .foregroundStyle(Color.mutedLabel)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!foldable)
            .help("This Mac's audio, sent to other receivers — another Grabber, Voicemeeter or any VBAN receiver.")
            if !open {
                Text(verbatim: summary).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(Color.mutedLabel)
            }
            Spacer(minLength: 6)
            // Open, the receivers' own header has it.
            if !open {
                Toggle(isOn: Bindable(state).offering) {
                    Text("Findable by Grabbers").font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                }
                .controlSize(.mini).fixedSize()
            }
            PillToggle(title: "MUTE ALL", isOn: Bindable(state).allMuted, tint: .red,
                       help: "Every receiver hears silence and stays connected. Each target's own mute is kept.",
                       spokenName: "Mute every send")
                .disabled(!state.isActive)
                .opacity(state.isActive ? 1 : 0.45)
            // "Stop" where "Stop sending" would not fit (the compact window).
            ViewThatFits {
                Button("Stop sending") { state.stopAll() }
                Button("Stop") { state.stopAll() }.help("Stop sending")
            }
            .controlSize(.small)
                .disabled(!state.isActive && !state.offering)
        }
    }

    private var summary: String {
        guard state.isActive else { return state.offering ? "Findable, nobody listening" : "Not sending" }
        let names = state.targets.filter { state.sending.contains($0.id) }.map(\.label)
            + state.listeners.map { $0.name ?? $0.ip }
        return "\(VBAN.wireName(state.streamName)) → " + names.joined(separator: ", ")
    }
}

/// The section along the bottom of the Grabber's full window: the header, and when open this Mac
/// on the left and the receivers beside it. The Grabber sets the open height (resizable).
public struct GrabberSendSection: View {
    let send: GrabberSend
    @Binding var open: Bool
    public init(send: GrabberSend, open: Binding<Bool>) { self.send = send; _open = open }

    public var body: some View {
        VStack(spacing: 0) {
            GrabberSendHeader(open: $open)
                .padding(.horizontal, 12).padding(.vertical, 6)
            if open {
                Divider().opacity(0.5)
                SendControls(twoColumn: true)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .environment(send.state)
    }
}

/// The Send tab of the Grabber's Receive / Send window, and of its compact window: the Sender's
/// own controls, in a column.
public struct GrabberSendTab: View {
    let send: GrabberSend
    var showsHeader = true
    public init(send: GrabberSend, showsHeader: Bool = true) { self.send = send; self.showsHeader = showsHeader }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                GrabberSendHeader(open: .constant(true), foldable: false)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                Divider().opacity(0.5)
            }
            ScrollView { SendControls() }
        }
        .environment(send.state)
    }
}
