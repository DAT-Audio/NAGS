import Foundation
import Observation

/// A stream we know about.
///
/// Deliberately holds nothing that changes on network traffic. `lastSeen` used to live here, and
/// because `streams` is `@Published`, stamping it on every announcement re-evaluated the whole
/// window several times a second — with ten senders announcing, that was most of the app's CPU
/// It lives in `lastSeenAt` now, unpublished, because nothing displays it.
public struct DiscoveredStream: Identifiable {
    public var description: StreamDescription
    public var id: String { description.id }
}

/// Glanceable per-stream state: the receive dot, and the two counters that mean something is
/// wrong. **Published**, so it must only change when one of these actually changes.
/// How much of the stream list is on show. See `AppState.detailLevel`.
public enum DetailLevel: String, CaseIterable, Identifiable {
    case simple, detailed
    public var id: String { rawValue }
    public var label: String { self == .simple ? "Simple" : "Detailed" }
}

public struct StreamHealth: Equatable {
    public var receiving = false
    public var lost: UInt64 = 0
    public var underruns: UInt64 = 0
    /// When the count last went up, as seen by the poller (so to within its interval). Lets
    /// buffer tuning be judged on data rather than by ear.
    public var lastUnderrun: Date?
    public init(receiving: Bool = false, lost: UInt64 = 0, underruns: UInt64 = 0, lastUnderrun: Date? = nil) {
        self.receiving = receiving; self.lost = lost; self.underruns = underruns; self.lastUnderrun = lastUnderrun
    }
}

/// The figures behind a row's disclosure. **Polled, never published.** `packets` climbs a
/// thousand times a second, so publishing it dragged the entire window's attribute graph along
/// with it four times a second.
public struct StreamFigures {
    public var packets: UInt64 = 0
    public var bufferMs: Double = 0
    public var driftPPM: Double = 0
    public var peak: Float = 0
    /// Smoothed packet arrival jitter and the worst single deviation, in milliseconds.
    public var jitterMs: Double = 0
    public var worstJitterMs: Double = 0
    /// The lowest the buffer got since priming — how much headroom was actually used.
    public var minBufferMs: Double = 0
    public init(packets: UInt64 = 0, bufferMs: Double = 0, driftPPM: Double = 0, peak: Float = 0,
                jitterMs: Double = 0, worstJitterMs: Double = 0, minBufferMs: Double = 0) {
        self.packets = packets; self.bufferMs = bufferMs; self.driftPPM = driftPPM; self.peak = peak
        self.jitterMs = jitterMs; self.worstJitterMs = worstJitterMs; self.minBufferMs = minBufferMs
    }
}

/// Injected by the off-screen preview harness so the meters have something to draw.
/// Always nil in normal operation.
public struct PreviewMeters {
    public var outputL: Float = 0
    public var outputR: Float = 0
    public var outputHold: Float = 0
    public var outputReadout: Float = 0
    public var channelPeaks: [String: [Float]] = [:]
    public var figures: [String: StreamFigures] = [:]
    public var integrated: Double = -.infinity
    public var shortTerm: Double = -.infinity
    public var windowed: Double = -.infinity
    public var momentary: Double = -.infinity
    public var blocksMeasured = 0
    public init(outputL: Float = 0, outputR: Float = 0, outputHold: Float = 0, outputReadout: Float = 0,
                channelPeaks: [String: [Float]] = [:], figures: [String: StreamFigures] = [:],
                integrated: Double = -.infinity, shortTerm: Double = -.infinity,
                windowed: Double = -.infinity, momentary: Double = -.infinity, blocksMeasured: Int = 0) {
        self.outputL = outputL; self.outputR = outputR; self.outputHold = outputHold
        self.outputReadout = outputReadout; self.channelPeaks = channelPeaks; self.figures = figures
        self.integrated = integrated; self.shortTerm = shortTerm; self.windowed = windowed
        self.momentary = momentary; self.blocksMeasured = blocksMeasured
    }
}

/// Which window the app is showing. The full window is the working surface; the compact one
/// is a narrow strip of the monitor controls and whatever is playing, for leaving on screen.
public enum ViewMode: String, CaseIterable, Identifiable {
    case full, compact
    public var id: String { rawValue }
    public var label: String { self == .full ? "Full" : "Compact" }
    public var other: ViewMode { self == .full ? .compact : .full }
}

/// Which loudness reading the compact window pins beside its peak figure.
public enum LoudnessPin: String, CaseIterable, Identifiable {
    case none, shortTerm, window, integrated

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .none:       return "None"
        case .shortTerm:  return "Short-term"
        case .window:     return "Window"
        case .integrated: return "Integrated"
        }
    }

    /// The badge under the pinned figure, matching the loudness block's own names.
    public var badge: String {
        switch self {
        case .none:       return ""
        case .shortTerm:  return "LUFS-S"
        case .window:     return "LUFS-W"
        case .integrated: return "LUFS-I"
        }
    }
}

/// Everything the Grabber does — discovery, joining, mixing, buffers, VBAN and Remote links,
/// auto-stop, the meters' figures, the tick — with nothing of a platform's own. Each app subclasses it: on the Mac, `AppState` adds the
/// look, the windows, the inserts, the Send, internet streams and the hooks below. Was
/// `AppState` itself, so the views read the same members as before.
@Observable
open class GrabberEngine {
    // Discovery
    public var streams: [DiscoveredStream] = []
    public var subscribed: Set<String> = []
    /// Per-stream health. Its counters climb whenever a stream loses packets or underruns, so a
    /// view body must not read it — one lossy stream re-evaluated every row four times a second
    /// Bodies read `receivingIDs`; the figures poll `health` inside `FiguresBeat`.
    public var health: [String: StreamHealth] = [:] {
        didSet {
            let now = Set(health.lazy.filter { $0.value.receiving }.map(\.key))
            if now != receivingIDs { receivingIDs = now }
        }
    }
    /// The streams audio is arriving on: changes only when one starts or stops.
    public private(set) var receivingIDs: Set<String> = []
    public func isReceiving(_ id: String) -> Bool { receivingIDs.contains(id) }
    public var danteDevices: [DanteDevice] = []

    // Browsing / filtering
    public var searchText = ""
    public var showActiveOnly = false
    public var favourites: Set<String> = [] {
        didSet { defaults.set(Array(favourites), forKey: "favourites") }
    }
    public var soloed: String? { didSet { applyMuteStates() } }

    // Settings
    public var interfaces: [NetInterface] = []
    public var selectedInterface: String {
        didSet {
            guard oldValue != selectedInterface else { return }
            defaults.set(selectedInterface, forKey: "interface")
            restartDiscovery()
            restartAllReceivers()
        }
    }
    /// The playout buffer for AES67 / RAVENNA / Dante streams, which normally arrive over a
    /// wired network.
    public var latencyMs: Double {
        didSet {
            defaults.set(latencyMs, forKey: "latencyMs")
            receivers.values.filter { $0.stream.latencyClass == .realTime && !isRemote($0.stream) }.forEach { $0.setLatency(ms: latencyMs) }
            onHostLatencyChange?()
        }
    }
    /// VBAN's own, since VBAN usually arrives over Wi-Fi or a VPN. Testing ran
    /// clean at 18–22 ms over Wi-Fi and started to underrun at 16, hence 20 by default.
    public var vbanLatencyMs: Double {
        didSet {
            defaults.set(vbanLatencyMs, forKey: "vbanLatencyMs")
            receivers.values.filter { $0.stream.latencyClass == .lan && !isRemote($0.stream) }.forEach { $0.setLatency(ms: vbanLatencyMs) }
            onHostLatencyChange?()
        }
    }
    public static let defaultLatencyMs: Double = 15
    public static let defaultVBANLatencyMs: Double = 20

    /// The saved VBAN buffer. Before it existed, VBAN used the one shared buffer setting, so an
    /// install that had set that keeps the same value for VBAN; only a fresh one gets 20 ms.
    public static func storedVBANLatency(in defaults: UserDefaults) -> Double {
        defaults.object(forKey: "vbanLatencyMs") as? Double
            ?? defaults.object(forKey: "latencyMs") as? Double
            ?? defaultVBANLatencyMs
    }

    // MARK: Remote streams' buffer
    //
    // A stream from another location crosses the internet, where packets arrive far less evenly
    // than on a LAN. It has a buffer of its own — fixed, 60 ms to start (between VBAN's own
    // "Medium" and its 100 ms "Very Slow") — and **Test the connection** measures a playing remote
    // stream for 30 s and suggests a figure, applied only if the user presses Use. The tester is kept apart from the setting, which always says what it is.

    public var remoteLatencyMs: Double { didSet { persist("remoteLatencyMs", remoteLatencyMs); applyRemoteBuffers() } }
    public static let defaultRemoteLatencyMs: Double = 60
    public static let remoteBufferRange: ClosedRange<Double> = 20...250

    /// Across the internet, for the buffer and the test: in another location, or over a VPN.
    public func isRemote(_ stream: StreamDescription) -> Bool {
        stream.source != .web
            && (RemoteAddresses.isRemote(stream.originAddress) || RemoteAddresses.isVPN(stream.originAddress))
    }

    /// The buffer this stream plays out against: its class's, or the remote one.
    public func latency(for stream: StreamDescription) -> Double {
        isRemote(stream) ? remoteLatencyMs : latency(for: stream.latencyClass)
    }

    private func applyRemoteBuffers() {
        for r in receivers.values where isRemote(r.stream) { r.setLatency(ms: remoteLatencyMs) }
        onHostLatencyChange?()
    }

    /// Remote streams playing now, for the test to choose from.
    public var playingRemoteStreams: [StreamDescription] {
        receivers.values.map(\.stream).filter(isRemote).sorted { $0.name < $1.name }
    }

    public struct ConnectionTestResult: Equatable {
        public let streamName: String
        public let spreadMs: Double
        public let worstMs: Double
        public let lostPercent: Double
        public let suggestedMs: Double
        public init(streamName: String, spreadMs: Double, worstMs: Double, lostPercent: Double, suggestedMs: Double) {
            self.streamName = streamName; self.spreadMs = spreadMs; self.worstMs = worstMs
            self.lostPercent = lostPercent; self.suggestedMs = suggestedMs
        }
    }
    public enum ConnectionTest: Equatable {
        case idle, running(streamName: String, until: Date), done(ConnectionTestResult), failed(String)
    }
    public private(set) var connectionTest: ConnectionTest = .idle
    public static let connectionTestSeconds: TimeInterval = 30

    /// Listens to one playing remote stream for 30 s, and suggests a buffer. Changes nothing.
    public func testConnection(_ id: String) {
        guard let r = receivers[id] else { return }
        r.beginArrivalTest()
        connectionTest = .running(streamName: r.stream.name, until: Date().addingTimeInterval(Self.connectionTestSeconds))
        append(log: "Testing the connection of “\(r.stream.name)” for \(Int(Self.connectionTestSeconds)) s — listening only.", .request)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectionTestSeconds) { [weak self, weak r] in
            guard let self, let r else { self?.connectionTest = .failed("The stream stopped before the test ended."); return }
            guard let t = r.endArrivalTest() else {
                self.connectionTest = .failed("Too little arrived to judge: is the stream playing?")
                return
            }
            // The spread, a margin, and one packet (a buffer is filled a packet at a time),
            // rounded up to 5 ms, within the setting's range.
            let raw = t.spreadMs + 10 + t.packetMs
            let suggested = min(Self.remoteBufferRange.upperBound,
                                max(Self.remoteBufferRange.lowerBound, (raw / 5).rounded(.up) * 5))
            let lost = t.packets + t.lost > 0 ? Double(t.lost) / Double(t.packets + t.lost) * 100 : 0
            let result = ConnectionTestResult(streamName: r.stream.name, spreadMs: t.spreadMs, worstMs: t.worstMs,
                                              lostPercent: lost, suggestedMs: suggested)
            self.connectionTest = .done(result)
            self.append(log: String(format: "Connection test of “%@”: packets arrived within %.0f ms of even (worst %.0f), "
                                    + "%.1f %% lost. Suggested buffer %.0f ms.", r.stream.name, t.spreadMs, t.worstMs, lost, suggested), .done)
        }
    }

    public func useSuggestedBuffer() {
        guard case .done(let r) = connectionTest else { return }
        remoteLatencyMs = r.suggestedMs
        append(log: "Remote buffer set to \(Int(r.suggestedMs)) ms, from the connection test — by you.", .done)
    }

    public func clearConnectionTest() { connectionTest = .idle }
    /// RENDER HARNESS only.
    public func setPreviewConnectionTest(_ t: ConnectionTest) { connectionTest = t }

    /// The buffer a stream plays out against.
    /// By the source's latency class: AES67's buffer for PTP-locked streams, the VBAN buffer for
    /// every local-network stream without a shared clock.
    public func latency(for latencyClass: LatencyClass) -> Double {
        switch latencyClass {
        case .realTime: return latencyMs
        case .lan:      return vbanLatencyMs
        case .buffered: return Self.bufferedLatencyMs
        }
    }

    /// Seconds, not milliseconds: a buffered stream is listened to, and the network it comes
    /// over is the internet. Set properly when the first buffered protocol arrives (D4).
    public static let bufferedLatencyMs = 2000.0
    public var sapEnabled: Bool { didSet { persist("sapEnabled", sapEnabled); scheduleDiscoveryRestart() } }
    public var ravennaEnabled: Bool { didSet { persist("ravennaEnabled", ravennaEnabled); scheduleDiscoveryRestart() } }
    public var danteEnabled: Bool { didSet { persist("danteEnabled", danteEnabled); scheduleDiscoveryRestart() } }
    /// Why VBAN is on but not listening — the port was taken, most likely. Nil while it is
    /// listening or switched off. Shown in Settings, where someone setting up a sender looks.
    public private(set) var vbanError: String?

    /// Where a VBAN sender should be pointed: every address this Mac has, VPNs included, read
    /// from the machine each time it is asked. The render harness substitutes made-up ones,
    /// because Settings displays them.
    public var vbanAddresses: [NetInterface] { vbanAddressOverride ?? Interfaces.receiveAddresses() }
    public var vbanAddressOverride: [NetInterface]?

    /// Off unless asked for: on, the app opens UDP 6980 to anything on any interface.
    public var vbanEnabled: Bool {
        didSet {
            guard oldValue != vbanEnabled else { return }
            persist("vbanEnabled", vbanEnabled)
            if !vbanEnabled { vban.unsubscribeAll(); dropVBANStreams() }
            scheduleDiscoveryRestart { [weak self] in
                if self?.vbanEnabled == true { self?.resumeManualSenders() }
            }
        }
    }
    /// Scream (a Windows virtual sound card, `Scream`): off by default, like Dante — it opens
    /// UDP 4010 and joins a multicast group, which nobody should find this app doing unasked.
    public var screamEnabled: Bool {
        didSet {
            guard oldValue != screamEnabled else { return }
            persist("screamEnabled", screamEnabled)
            if !screamEnabled { dropStreams(from: .scream, because: "Scream was turned off") }
            scheduleDiscoveryRestart()
        }
    }
    /// RTP streams that name no PTP clock — PipeWire, PulseAudio, VLC, GStreamer. **Beta and
    /// off by default** (untested on real senders): with it off, such
    /// announcements are not listed. AES67 streams all name their clock, so they are unaffected.
    public var plainRTPEnabled: Bool {
        didSet {
            guard oldValue != plainRTPEnabled else { return }
            persist("plainRTPEnabled", plainRTPEnabled)
            if !plainRTPEnabled {
                for stream in streams where Self.isPlainRTP(stream.description) {
                    unsubscribe(stream.id, reason: "RTP without PTP was turned off")
                    lastSeenAt[stream.id] = nil
                }
                streams.removeAll { Self.isPlainRTP($0.description) }
            }
        }
    }

    /// A beta receiver's switch: off unless it was switched on.
    public static func storedBeta(_ key: String, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? false
    }

    public static func isPlainRTP(_ d: StreamDescription) -> Bool {
        [.sap, .ravenna, .dante, .manual].contains(d.source) && d.latencyClass == .lan
    }

    /// Internet streams added by address. **Beta and off by default**, as above: with it
    /// off the add sheet offers only SDP and saved stations are not listed (they are kept).
    public var webStreamsEnabled: Bool {
        didSet {
            guard oldValue != webStreamsEnabled else { return }
            persist("webStreamsEnabled", webStreamsEnabled)
            if webStreamsEnabled { restoreWebStreams() }
            else { dropStreams(from: .web, because: "internet streams were turned off") }
        }
    }

    /// What this Grabber calls itself to a Network Audio Sender, which shows it against the
    /// listener. The Mac's own name by default, cut to VBAN's 16 plain characters.
    public var vbanReceiverName: String {
        didSet {
            persist("vbanReceiverName", vbanReceiverName)
            vban.receiverName = Self.receiverName(vbanReceiverName)
            receiverNameChanged(Self.receiverName(vbanReceiverName))
        }
    }
    /// This Grabber's identity to Senders, kept with its settings: a Sender that allowed it lets it
    /// in whichever of this Mac's addresses it asks from. Random, nothing about the Mac.
    private var grabberInstance: [UInt8] {
        if let data = defaults.data(forKey: "grabberInstance"), data.count == VBANControl.instanceBytes {
            return [UInt8](data)
        }
        let made = (0..<VBANControl.instanceBytes).map { _ in UInt8.random(in: 0...255) }
        defaults.set(Data(made), forKey: "grabberInstance")
        return made
    }

    /// This machine's name, for the default receiver name: given by the platform.
    nonisolated(unsafe) public static var computerName: () -> String = { "" }

    public static func receiverName(_ text: String) -> String {
        let name = VBAN.wireName(text)
        if !name.isEmpty { return name }
        let computer = computerName()
        return VBAN.wireName(computer).isEmpty ? "Grabber" : VBAN.wireName(computer)
    }
    /// Senders added by address ("ip:port"), for a VPN or anywhere a beacon cannot reach.
    public private(set) var vbanManualSenders: [String] = []
    /// Their state as last seen, for Settings: whether each one is sending here yet.
    public private(set) var vbanSenderStates: [String: Bool] = [:]
    /// Streams whose Sender is asking its user, or was told no, by stream ID.
    public private(set) var vbanApprovals: [String: VBANListener.Approval] = [:]
    public var includeLFE: Bool { didSet { persist("includeLFE", includeLFE); reapplyMixes() } }
    public var autoFoldSurround: Bool { didSet { persist("autoFoldSurround", autoFoldSurround) } }
    public var downmixTrimDB: Double { didSet { persist("downmixTrimDB", downmixTrimDB); reapplyMixes() } }

    /// The channel order assumed for streams that have not been told otherwise.
    ///
    /// SMPTE by default, and the default is what nearly everything should stay on: broadcast and
    /// game audio both use it. The option exists because **nothing in an AES67 or Dante stream
    /// declares its channel order**, so any assumption is occasionally wrong, and being wrong
    /// about it silently is the worst of the options.
    public var channelOrder: ChannelOrder {
        didSet { persist("channelOrder", channelOrder.rawValue); reapplyMixes() }
    }
    /// How much of the stream list is on show.
    ///
    /// **One switch, two states.** The figures behind it are all measured already and cost
    /// nothing to display, but a monitor tool whose first job is "find a stream and hear it"
    /// should not open on a page of packet counters. A preference per column is how Settings
    /// became a wall the first time.
    ///
    /// Replaces `compactRows`, which hid the address line under every name: both densities hide
    /// it now, because the same address twelve times is noise and the one that matters is on
    /// the stream you have open.
    public var detailLevel: DetailLevel { didSet { persist("detailLevel", detailLevel.rawValue) } }

    public var detailed: Bool { detailLevel == .detailed }

    /// What this stream is doing to reach the bus, in words: the fold or the pair, the channel
    /// order it assumes, or — while one is engaged — the channel solo that overrides both.
    ///
    /// Shared, because the detail block draws it and the panel's tooltip quotes it, and a
    /// caption that says two different things in two places is worse than no caption.
    public func mixCaption(for stream: StreamDescription,
                    ignoringChannelSolo: Bool = false) -> String {
        let soloed = ignoringChannelSolo ? [] : soloedChannels(stream.id).sorted()
        if !soloed.isEmpty {
            let names = channelLabels(for: stream, folded: true)
            let listed = soloed.map { $0 < names.count ? names[$0] : "\($0 + 1)" }
            return "Solo " + listed.joined(separator: " ")
        }
        let order = channelOrder(for: stream.id).name
        let mode = mixMode(for: stream.id)
        switch mode {
        case .downmix, .passthrough:
            return "\(Downmix.label(for: mode, channels: stream.channels)) · \(order)"
        default:
            return Downmix.label(for: mode, channels: stream.channels)
        }
    }

    /// Whether a stream's arrival jitter is worth colouring.
    ///
    /// Against the buffer rather than a fixed figure: 0.4 ms of jitter is nothing behind a 15 ms
    /// playout buffer and serious behind 2 ms. A quarter of the target is the point where the
    /// buffer is doing real work rather than idling, which is what the colour is for.
    public func jitterIsNotable(_ figures: StreamFigures, for stream: StreamDescription) -> Bool {
        let buffer = latency(for: stream)
        return buffer > 0 && figures.worstJitterMs > buffer * 0.25
    }

    /// Keep a stream added from pasted SDP in the list while it is stopped, instead of letting
    /// it go after two quiet minutes as an announced stream does — nothing re-announces it, so
    /// otherwise it has to be pasted again. Off by default.
    public var keepManualStreams: Bool { didSet { persist("keepManualStreams", keepManualStreams) } }

    /// Streams moved out of the list, by id, and remembered across launches: they sit folded under "Ignored" at the foot of the list, and
    /// "Show in list" brings one back. Nothing about receiving changes: an ignored stream is
    /// still heard announcing, it is only not listed with the others.
    public var ignoredStreams: Set<String> {
        didSet { defaults.set(ignoredStreams.sorted(), forKey: "ignoredStreams") }
    }
    /// Whether the Ignored section is unfolded. Not remembered: it is a glance, not a setting.
    public var ignoredOpen = false

    /// The ignored streams that are on the network now, for the folded section.
    public var ignoredPresent: [DiscoveredStream] { streams.filter { ignoredStreams.contains($0.id) } }

    public func ignore(_ id: String) {
        guard let stream = streams.first(where: { $0.id == id }) else { return }
        unsubscribe(id, reason: "it was moved to Ignored")
        openStreamIDs.remove(id)
        ignoredStreams.insert(id)
        append(log: "Ignoring “\(stream.description.name)”: it is listed under Ignored.")
    }

    public func unignore(_ id: String) {
        guard ignoredStreams.remove(id) != nil else { return }
        if let stream = streams.first(where: { $0.id == id }) {
            append(log: "“\(stream.description.name)” is back in the list.")
        }
    }

    // MARK: Gone
    //
    // A playing stream is never dropped from the list for being quiet: a drop-out must not take
    // its row away. But one whose sender has really left — no audio for `goneAfter`, and no
    // announcement either — moves to a folded "Gone" section under the list. It stays joined, so
    // it plays again the moment it returns. Left gone for `goneStopAfter` it is stopped and leaves
    // the list. Streams added by hand (a pasted SDP, internet radio) are never stopped this way:
    // they were added on purpose, so they wait under Gone until stopped.

    /// Playing streams whose sender has gone. Changes only when one goes or comes back.
    public private(set) var goneIDs: Set<String> = []
    @ObservationIgnored private var goneSince: [String: Date] = [:]
    /// Whether the Gone section is unfolded. Open by default: these were playing.
    public var goneOpen = true
    public static let goneAfter: TimeInterval = 30
    public static let goneStopAfter: TimeInterval = 300

    /// The gone streams, for the section under the list (ignored ones stay under Ignored).
    public var gonePresent: [DiscoveredStream] {
        streams.filter { goneIDs.contains($0.id) && !ignoredStreams.contains($0.id) }
    }
    public func isGone(_ id: String) -> Bool { goneIDs.contains(id) }
    /// RENDER HARNESS only: shows these streams as gone.
    public func setPreviewGone(_ ids: Set<String>) { goneIDs = ids }
    /// How long a stream has been gone, for its row.
    public func goneFor(_ id: String) -> TimeInterval? { goneSince[id].map { Date().timeIntervalSince($0) } }

    /// Stops a gone stream and takes it off the list; it is listed again if it comes back. One
    /// added by hand and kept (Settings → Discovery) stays listed, stopped.
    public func stopGone(_ id: String) { stopGone(id, automatic: false) }

    /// Every gone stream, stopped and cleared.
    public func clearGone() {
        let ids = goneIDs
        for id in ids { stopGone(id, automatic: false) }
    }

    private func stopGone(_ id: String, automatic: Bool) {
        let source = streams.first { $0.id == id }?.description.source
        unsubscribe(id, reason: automatic
            ? "it had been gone for \(Self.minutesText(Int(Self.goneStopAfter / 60))), so it was stopped"
            : "it had gone, and was cleared")
        goneSince[id] = nil
        goneIDs.remove(id)
        let kept = source == .web || (source == .manual && keepManualStreams)
        if !kept {
            streams.removeAll { $0.id == id }
            lastSeenAt[id] = nil
            health[id] = nil
            openStreamIDs.remove(id)
        }
    }

    /// Whether a playing stream has gone: no audio for `goneAfter`, and nothing announcing it for as
    /// long as its kind would take to be dropped unplayed (`announceLimit` for SAP, RAVENNA, Dante
    /// and pasted SDP, which may announce only every 30–60 s; VBAN and Scream announce themselves
    /// with their packets). Internet streams reconnect on their own, so are never gone. Pure.
    public static func isGone(source: DiscoverySource, quiet: TimeInterval, unheard: TimeInterval,
                              announceLimit: TimeInterval) -> Bool {
        guard source != .web else { return false }
        let limit = (source == .vban || source == .scream) ? goneAfter : announceLimit
        return quiet >= goneAfter && unheard >= limit
    }

    /// Once a tick: which playing streams have gone, which are back, and which have been gone long
    /// enough to stop. A Sender still asking its user is waiting, not gone; an internet stream
    /// has its own reconnecting.
    private func updateGone(_ now: Date) {
        var gone = Set<String>()
        for (id, r) in receivers where vbanApprovals[id] == nil && !r.isReceiving {
            let source = r.stream.source
            let quiet = now.timeIntervalSince(quietSince[id] ?? now)
            // VBAN and Scream are "announced" by their own packets; SAP, RAVENNA and Dante may
            // announce only every 30–60 s, so their silence counts once they would have been
            // dropped from the list unplayed.
            let unheard = now.timeIntervalSince(lastSeenAt[id] ?? .distantPast)
            if Self.isGone(source: source, quiet: quiet, unheard: unheard, announceLimit: staleAfter) { gone.insert(id) }
        }
        for id in gone where goneSince[id] == nil {
            goneSince[id] = now
            if let name = receivers[id]?.stream.name {
                append(log: "“\(name)” has gone: no audio and no announcement for a while. It is under Gone, "
                     + "still joined, and plays again if it comes back.", .warning)
            }
        }
        for id in Array(goneSince.keys) where !gone.contains(id) {
            goneSince[id] = nil
            if let r = receivers[id], r.isReceiving { append(log: "“\(r.stream.name)” is back.", .done) }
        }
        if gone != goneIDs { goneIDs = gone }
        let due = goneSince.filter { now.timeIntervalSince($0.value) >= Self.goneStopAfter }.map(\.key)
        for id in due {
            let source = receivers[id]?.stream.source
            if source == .manual { continue }
            stopGone(id, automatic: true)
        }
    }

    /// The source sidebar's choice: every kind of stream (nil, the default) or one. Remembered,
    /// so the list opens as it was left.
    public var sourceFilter: DiscoverySource? { didSet { persist("sourceFilter", sourceFilter?.rawValue ?? "all") } }
    // MARK: Auto-stop
    //
    // Nothing stops on its own by default: a stream stays joined, and a send keeps sending, for
    // as long as it is left — days, if need be — and a joined stream that comes back plays again.
    // On, each playing stream is stopped once *it* has had no audio for the time chosen, and
    // says so on its row until it is played again.

    public var autoStopStreams: Bool { didSet { persist("autoStopStreams", autoStopStreams) } }
    public var autoStopStreamsMinutes: Int { didSet { persist("autoStopStreamsMinutes", autoStopStreamsMinutes) } }
    public static let autoStopChoices = [1, 5, 15, 30, 60, 120, 480, 1440]
    public static func minutesText(_ m: Int) -> String {
        m < 60 ? "\(m) min" : m % 60 == 0 ? "\(m / 60) h" : "\(m) min"
    }
    public struct AutoStop: Equatable { let at: Date; let minutes: Int }
    /// Streams auto-stop stopped, until played again (or the app quits): the row says so.
    public private(set) var autoStopped: [String: AutoStop] = [:]
    /// When each playing stream last went without audio.
    @ObservationIgnored private var quietSince: [String: Date] = [:]
    /// What the row's tooltip says about one: what happened, and where the setting is.
    public func autoStopNote(_ id: String) -> String? {
        guard let stop = autoStopped[id] else { return nil }
        let time = stop.at.formatted(date: .omitted, time: .shortened)
        return "Stopped at \(time) after \(Self.minutesText(stop.minutes)) with no audio, by "
            + "Settings → Playout → Auto-stop. Press play to join it again."
    }
    /// RENDER HARNESS only: a stream shown as auto-stopped.
    public func setPreviewAutoStop(_ id: String, minutes: Int) { autoStopped[id] = AutoStop(at: Date(), minutes: minutes) }
    /// Forget a stopped stream's note (it stays in the list while the note is shown).
    public func clearAutoStop(_ id: String) { autoStopped[id] = nil }

    /// The spare port last logged for VBAN sharing, so the note is said once, not at every
    /// discovery restart.
    @ObservationIgnored private var vbanSharingLogged: Int?
    @ObservationIgnored private var screamSharingLogged = false
    /// The port VBAN listens on: 6980, or the spare one while sharing it. For the self-test.
    public var vbanListenPort: Int { vban.sharingPort ?? VBAN.port }
    #if os(Windows)
    /// VBAN audio to leave out of the list, as "ip:port" (`VBANListener.ignoredSources`).
    public var vbanIgnoredSources: Set<String> {
        get { vban.ignoredSources }
        set { if vban.ignoredSources != newValue { vban.ignoredSources = newValue } }
    }
    #endif
    /// For the self-test's summary.
    public var vbanSharingNote: String? {
        vban.sharingPort.map { "sharing UDP \(VBAN.port) with another app; offers joined over port \($0)" }
    }

    /// How many listed streams (ignored ones aside) there are of each kind.
    public var sourceCounts: [DiscoverySource: Int] {
        var counts: [DiscoverySource: Int] = [:]
        for s in streams where !ignoredStreams.contains(s.id) { counts[s.description.source, default: 0] += 1 }
        return counts
    }
    // Loudness (ITU-R BS.1770-4 / EBU R 128). Targets are per reading because they are used
    // for different things: an integrated target is a deliverable, a short-term one is a
    // mixing guide rail.
    public var lufsWindowSeconds: Int {
        didSet {
            // Clamp first and come back round, so an out-of-range value typed into Settings is
            // never the one that gets persisted or handed to the meter.
            let clamped = min(LoudnessMeter.maxWindowSeconds, max(1, lufsWindowSeconds))
            if clamped != lufsWindowSeconds {
                lufsWindowSeconds = clamped
                return
            }
            persist("lufsWindowSeconds", lufsWindowSeconds)
            output.loudness.windowSeconds = lufsWindowSeconds
        }
    }
    public var targetIntegrated: Double { didSet { persist("targetIntegrated", targetIntegrated) } }
    public var targetShortTerm: Double { didSet { persist("targetShortTerm", targetShortTerm) } }
    public var targetWindow: Double { didSet { persist("targetWindow", targetWindow) } }
    public var showLoudness: Bool { didSet { persist("showLoudness", showLoudness) } }

    // Monitor controls
    public var masterVolume: Double {
        didSet {
            persist("masterVolume", masterVolume)
            output.masterGain = Float(masterVolume)
        }
    }
    public var dimmed = false {
        didSet {
            output.dimmed = dimmed
            // The maximum was captured at the other monitor level, so it is not comparable
            // with anything that follows. Starting it again is more honest than leaving a
            // figure standing that the programme has to beat before the readout means
            // anything — which is what read as "the dBFS is sluggish after a dim".
            output.clearPeakMax()
        }
    }
    public var monoFold = false { didSet { output.monoFold = monoFold } }
    public var safetyLimiter: Bool {
        didSet {
            persist("safetyLimiter", safetyLimiter)
            output.safetyLimiter = safetyLimiter
        }
    }

    // Output
    public var outputDeviceName = "—"
    public var outputRate: Double = 48000
    public var outputChannels = 2
    public var outputRunning = false
    public var clipped = false

    /// Whether anything is being listened to. The meter views stop redrawing when it is false,
    /// which takes idle CPU from about 12 % down to the low single digits.
    public var metersActive = false

    /// Meter levels are deliberately **not** `@Published`. Publishing them re-rendered the whole
    /// window on every update, so they were throttled to a few hertz and looked sluggish. The
    /// meter views now poll these live through a `TimelineView`, which redraws only themselves.
    public var previewMeters: PreviewMeters?
    public var outputPeakL: Float { previewMeters?.outputL ?? output.peakL }
    public var outputPeakR: Float { previewMeters?.outputR ?? output.peakR }

    /// Envelope for one channel of the monitor bus. The preview harness only synthesises a
    /// stereo pair, so a wider bus renders its extra channels quiet rather than not at all.
    public func outputPeak(_ channel: Int) -> Float {
        if let preview = previewMeters {
            return channel == 0 ? preview.outputL : (channel == 1 ? preview.outputR : 0)
        }
        return output.peak(channel)
    }

    /// How wide the monitor bus is, and what its channels are called.
    public var busChannels = 2

    /// The width chosen for each output device, keyed by its persistent UID.
    ///
    /// Per device rather than global, which is what makes the default low-stakes: pick 7.1 once
    /// on a monitor rig and it is 7.1 there forever, while headphones stay stereo because they
    /// are a different device with their own answer. The same move as the per-stream mix mode.
    private var savedBusWidths: [String: Int] {
        get { defaults.dictionary(forKey: "busWidths") as? [String: Int] ?? [:] }
        set { defaults.set(newValue, forKey: "busWidths") }
    }

    /// Widths worth offering on this device: stereo, the SMPTE layouts it can carry, and its
    /// full width when that is something else again. A 16-output interface is rarely a
    /// 16-speaker room, so the device maximum is one option among several rather than the only
    /// alternative to stereo.
    public var busWidthOptions: [Int] {
        let device = max(2, outputChannels)
        var widths = [2, 4, 6, 8].filter { $0 <= device }
        if !widths.contains(device) { widths.append(device) }
        return widths
    }

    public func busWidthLabel(_ channels: Int) -> String {
        switch channels {
        case 2: return "Stereo (fold down)"
        case 4: return "4.0"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channels) ch"
        }
    }

    /// Sets the width of the monitor bus and remembers it for this device.
    public func setBusWidth(_ channels: Int) {
        // Remembered *first*, deliberately. Restarting the engine fires `onStatusChange`, which
        // lands in `applyRememberedBusWidth` while this call is still on the stack — and if the
        // preference still said the old width, that would helpfully undo the change being made.
        savedBusWidths[output.deviceUID] = channels
        let applied = output.setBusChannels(channels)
        busChannels = output.busChannels
        if applied != channels {
            append(log: "Output bus: \(busWidthLabel(channels)) asked for, but "
                 + "\(outputDeviceName) offers \(outputChannels) channels — using "
                 + "\(busWidthLabel(applied)).")
        } else if applied > 2 {
            append(log: "Output bus: \(busWidthLabel(applied)) — streams that fit now play out "
                 + "channel for channel, and fold-down no longer applies to them.")
        } else {
            append(log: "Output bus: stereo. Wider streams fold down again.")
        }
        revisitMixModes()
    }

    /// Re-derives each stream's mix mode after the bus changes width.
    ///
    /// A choice the user made by hand is kept if it still makes sense on the new bus, because
    /// it was deliberate; anything else follows the default for the new width. Without this, a
    /// 7.1 bed stays folded to stereo on a bus that could carry it, and a pass-through stays
    /// selected on a bus that has gone back to two channels.
    private func revisitMixModes() {
        for (id, receiver) in receivers {
            let stream = receiver.stream
            if let chosen = savedMixMode(id),
               chosen.fits(channels: stream.channels), suits(chosen, stream) {
                receiver.setMix(chosen, includeLFE: includeLFE, trimDB: downmixTrimDB,
                                order: channelOrder(for: id), soloed: soloedChannels(id))
                continue
            }
            receiver.setMix(defaultMixMode(for: stream), includeLFE: includeLFE,
                            trimDB: downmixTrimDB, order: channelOrder(for: id),
                            soloed: soloedChannels(id))
        }
        mixRevision &+= 1
    }

    /// Whether a mode still means what it meant before the bus changed.
    private func suits(_ mode: MixMode, _ stream: StreamDescription) -> Bool {
        switch mode {
        case .passthrough: return busChannels > 2
        case .downmix, .pair, .mono: return true
        }
    }

    public var busChannelLabels: [String] {
        SMPTELayout.forChannelCount(busChannels)?.channelNames
            ?? (1...max(1, busChannels)).map { String($0) }
    }
    public var outputPeakHold: Float { previewMeters?.outputHold ?? output.peakHold }

    /// Highest output level since the last reset. What the master figure now shows.
    public var outputPeakMax: Float { previewMeters?.outputReadout ?? output.peakMax }


    /// Loudness readings, in LUFS, or `-.infinity` before there is anything to report. Polled
    /// rather than published for the same reason as the peak meters.
    public var loudnessIntegrated: Double { previewMeters?.integrated ?? output.loudness.integrated }
    public var loudnessShortTerm: Double { previewMeters?.shortTerm ?? output.loudness.shortTerm }
    public var loudnessWindowed: Double { previewMeters?.windowed ?? output.loudness.windowed }
    public var loudnessMomentary: Double { previewMeters?.momentary ?? output.loudness.momentary }

    /// Complete 400 ms gating blocks since the last reset. The integrated reading is greyed
    /// out below about three seconds' worth, where it means very little.
    public var loudnessBlocks: Int { previewMeters?.blocksMeasured ?? output.loudness.blocksMeasured }

    /// Points all three loudness targets at one figure, for the two cases that come up most:
    /// −23 LUFS for EBU R 128 delivery, −14 for the streaming platforms.
    public func setLoudnessTargets(_ lufs: Double) {
        targetShortTerm = lufs
        targetWindow = lufs
        targetIntegrated = lufs
    }

    /// Starts the integrated and windowed measurements again. Bound to ⇧⌘L.
    public func resetLoudness() {
        output.loudness.reset()
        append(log: "Loudness reset.")
    }

    /// The diagnostic figures for one stream, read straight off the receiver. Polled by the
    /// expanded row at a few hertz, like the meters, and for the same reason.
    public func figures(_ id: String) -> StreamFigures? {
        if let preview = previewMeters { return preview.figures[id] }
        guard let r = receivers[id] else { return nil }
        let rate = Double(r.stream.sampleRate)
        let minBuffer = r.minBufferFrames.isFinite ? r.minBufferFrames / rate * 1000 : 0
        return StreamFigures(packets: r.packetsReceived,
                             bufferMs: r.ring.availableFrames / rate * 1000,
                             driftPPM: (r.ratio / (rate / max(1, outputRate)) - 1.0) * 1_000_000,
                             peak: r.signalPeak,
                             jitterMs: r.jitterMs,
                             worstJitterMs: r.worstJitterMs,
                             minBufferMs: minBuffer)
    }

    /// Level of one input channel of one stream, 0…1.
    public func channelPeak(_ streamID: String, _ index: Int) -> Float {
        if let preview = previewMeters {
            let peaks = preview.channelPeaks[streamID] ?? []
            return index < peaks.count ? peaks[index] : 0
        }
        return receiver(for: streamID)?.channelPeak(index) ?? 0
    }

    /// The streams whose detail is open under their rows, and highlighted in the panel. A set
    /// of open rows is how two streams are compared.
    ///
    /// On the state rather than in the view because two places need it, and published because
    /// it changes when someone clicks — not continuously. Never persisted: what you were looking at last session is not a
    /// preference.
    public var openStreamIDs: Set<String> = []

    public func isOpen(_ id: String) -> Bool { openStreamIDs.contains(id) }

    /// Opens a row, or closes it if it is open.
    public func toggleOpen(_ id: String) {
        if openStreamIDs.contains(id) { openStreamIDs.remove(id) } else { openStreamIDs.insert(id) }
    }

    // Diagnostics
    /// Streams whose first audio has been logged since they were joined.
    private var announcedReceiving: Set<String> = []
    /// What the app did and why, kept between launches (Settings → Log).
    public let activity: ActivityLog
    /// Injectable so the off-screen preview harness cannot write into the real app's
    /// preferences — it was leaving its synthetic favourites behind.
    public let defaults: UserDefaults
    private let sap = SAPListener()
    private let ravenna: StreamBrowser?
    private let dante: DeviceBrowser?
    private let vban = VBANListener()
    @ObservationIgnored private var vbanPreferredAddress: String?
    private let scream = ScreamListener()
    /// The monitor bus (the platform's: `AudioOutput` on the Mac).
    public let output: MonitorOutput
    /// In a DAW, as a plugin: no Send, no inserts, no main-thread watchdog.
    public let hostMode: Bool
    public private(set) var receivers: [String: StreamReceiver] = [:]
    /// Whether any stream is playing.
    public var isPlayingAny: Bool { !receivers.isEmpty }
    @ObservationIgnored private var timer: Timer?
    private var subscribedAt: [String: Date] = [:]
    private var warnedSilent: Set<String> = []

    /// When each stream was last announced. Drives staleness pruning and nothing else, so it is
    /// kept out of `streams` — see `DiscoveredStream`.
    public var lastSeenAt: [String: Date] = [:]

    // How often this object publishes. Every publish re-evaluates every view in the window, so
    // this is the single most useful number in the app for explaining CPU. Kept permanently
    // to catch any publish that fires on network traffic.
    private var started = false
    /// Whether `start()` has run: a Grabber plugin waits to be used first (`PluginBridge`).
    public var isStarted: Bool { started }

    /// Streams that were being listened to when the app last quit. They are rejoined as they
    /// are rediscovered, then dropped from the list, so a restart picks up where you left off
    /// without re-joining something you have since deselected.
    private var pendingRejoin: Set<String> = []
    private var discoveryStartedAt: Date?
    private var warnedLocalNetwork = false

    /// Streams that stop announcing are dropped after this long, unless we are listening to them.
    private let staleAfter: TimeInterval = 120

    /// `hostOutput`: a Grabber plugin hands in its own, made before the engine (its render thread
    /// holds it from the start). `keepsLog`: in a DAW, only one Receiver keeps the log file.
    /// `output`: the platform's monitor bus. `logFile`: where the log is kept, or nil for one in
    /// memory only. `ravenna`, `dante`: the platform's Bonjour browsers, if it has them.
    public init(defaults: UserDefaults, output: MonitorOutput, hostMode: Bool, logFile: URL?,
                ravenna: StreamBrowser?, dante: DeviceBrowser?) {
        self.output = output
        self.hostMode = hostMode
        self.ravenna = ravenna
        self.dante = dante
        activity = ActivityLog(appName: "Network Audio Grabber", file: logFile)
        self.defaults = defaults
        let ifaces = Interfaces.listIPv4()
        interfaces = ifaces
        let saved = defaults.string(forKey: "interface")
        selectedInterface = ifaces.first(where: { $0.name == saved })?.name ?? ifaces.first?.name ?? ""

        latencyMs = defaults.object(forKey: "latencyMs") as? Double ?? Self.defaultLatencyMs
        vbanLatencyMs = Self.storedVBANLatency(in: defaults)
        masterVolume = defaults.object(forKey: "masterVolume") as? Double ?? 1.0
        sapEnabled = defaults.object(forKey: "sapEnabled") as? Bool ?? true
        ravennaEnabled = defaults.object(forKey: "ravennaEnabled") as? Bool ?? true
        // On by default: with it off, the same AES67 streams were labelled SAP on one
        // machine and Dante on another. A choice already saved is kept.
        danteEnabled = defaults.object(forKey: "danteEnabled") as? Bool ?? true
        // On for a new install: a Sender's "Findable by Grabbers" is the
        // easy way in, and it was invisible until VBAN was found and switched on. Listening is
        // passive — streams are listed, nothing plays until play is pressed — and flood-limited.
        vbanEnabled = defaults.object(forKey: "vbanEnabled") as? Bool ?? true
        screamEnabled = defaults.object(forKey: "screamEnabled") as? Bool ?? false
        plainRTPEnabled = Self.storedBeta("plainRTPEnabled", in: defaults)
        webStreamsEnabled = Self.storedBeta("webStreamsEnabled", in: defaults)
        vbanReceiverName = defaults.string(forKey: "vbanReceiverName") ?? ""
        // Links from before the link was encrypted (no secret) can't be used: said once, dropped,
        // and their Sender-by-address entries with them.
        let savedLinks = defaults.stringArray(forKey: "remoteLinks") ?? []
        let savedSecrets = defaults.dictionary(forKey: "remoteLinkSecrets") as? [String: String] ?? [:]
        let usable = savedLinks.filter { savedSecrets[$0] != nil }
        if usable.count != savedLinks.count {
            defaults.set(usable, forKey: "remoteLinks")
            let gone = Set(savedLinks).subtracting(usable)
            let senders = (defaults.stringArray(forKey: "vbanManualSenders") ?? []).filter { !gone.contains($0) }
            defaults.set(senders, forKey: "vbanManualSenders")
        }
        remoteLinks = usable
        remoteLinkSecrets = savedSecrets
        droppedOldLinks = savedLinks.count - usable.count
        vbanManualSenders = defaults.stringArray(forKey: "vbanManualSenders") ?? []
        includeLFE = defaults.object(forKey: "includeLFE") as? Bool ?? false
        // Default on since the per-stream choice is remembered (see `rememberMixMode`): a wrong
        // first guess now costs one menu click rather than recurring every session.
        autoFoldSurround = defaults.object(forKey: "autoFoldSurround") as? Bool ?? true
        downmixTrimDB = defaults.object(forKey: "downmixTrimDB") as? Double ?? -3
        channelOrder = (defaults.string(forKey: "channelOrder")
            .flatMap(ChannelOrder.init(rawValue:))) ?? .smpte
        safetyLimiter = defaults.object(forKey: "safetyLimiter") as? Bool ?? false
        detailLevel = DetailLevel(rawValue: defaults.string(forKey: "detailLevel") ?? "")
            ?? .simple
        // Off unless chosen, the same rule as the beta switches.
        keepManualStreams = Self.storedBeta("keepManualStreams", in: defaults)
        ignoredStreams = Set(defaults.stringArray(forKey: "ignoredStreams") ?? [])
        sourceFilter = defaults.string(forKey: "sourceFilter").flatMap(DiscoverySource.init(rawValue:))
        remoteLatencyMs = defaults.object(forKey: "remoteLatencyMs") as? Double ?? Self.defaultRemoteLatencyMs
        autoStopStreams = defaults.bool(forKey: "autoStopStreams")
        autoStopStreamsMinutes = defaults.object(forKey: "autoStopStreamsMinutes") as? Int ?? 15
        lufsWindowSeconds = defaults.object(forKey: "lufsWindowSeconds") as? Int ?? 60
        // −23 LUFS is the EBU R 128 delivery target and the most widely useful default; the
        // streaming world's −14 is one edit away in Settings.
        targetIntegrated = defaults.object(forKey: "targetIntegrated") as? Double ?? -23
        targetShortTerm = defaults.object(forKey: "targetShortTerm") as? Double ?? -23
        targetWindow = defaults.object(forKey: "targetWindow") as? Double ?? -23
        showLoudness = defaults.object(forKey: "showLoudness") as? Bool ?? true
        favourites = Set(defaults.stringArray(forKey: "favourites") ?? [])
        pendingRejoin = Set(defaults.stringArray(forKey: "listening") ?? [])

        output.masterGain = Float(masterVolume)
        output.safetyLimiter = safetyLimiter
        output.loudness.windowSeconds = lufsWindowSeconds
        output.onStatusChange = { [weak self] in self?.refreshOutputStatus() }
        output.onError = { [weak self] msg in
            DispatchQueue.main.async { self?.append(log: msg, .failed) }
        }

        sap.onAnnouncement = { [weak self] sdp, deletion in
            DispatchQueue.main.async { self?.ingest(sdp, source: .sap, deletion: deletion) }
        }
        sap.onError = { [weak self] msg in
            DispatchQueue.main.async { self?.append(log: msg, .failed) }
        }
        (ravenna as? LeavingStreamBrowser)?.onGone = { [weak self] sdp in
            // A playing one stays (it is told apart under Gone); the rest leave the list now.
            DispatchQueue.main.async { self?.ingest(sdp, source: .ravenna, deletion: true) }
        }
        ravenna?.onSDP = { [weak self] sdp in
            DispatchQueue.main.async { self?.ingest(sdp, source: .ravenna, deletion: false) }
        }
        ravenna?.onError = { [weak self] msg in
            DispatchQueue.main.async { self?.append(log: msg, .failed) }
        }
        dante?.onDevicesChanged = { [weak self] devices in
            DispatchQueue.main.async { self?.updateDanteDevices(devices) }
        }
        dante?.onError = { [weak self] msg in
            DispatchQueue.main.async { self?.append(log: msg, .failed) }
        }
        vban.onError = { [weak self] msg in
            DispatchQueue.main.async { self?.append(log: msg, .failed) }
        }
    }

    public func persist(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }

    // MARK: - Lifecycle

    public func start() {
        guard !started else { return }
        started = true
        append(log: "Opened Network Audio Grabber" + (appVersion().isEmpty ? "." : " \(appVersion())."))
        if droppedOldLinks > 0 {
            append(log: "\(droppedOldLinks) Remote link\(droppedOldLinks == 1 ? " was" : "s were") made before links were "
                 + "encrypted and can't be used now: swap new codes with the other end.", .note)
        }
        if let err = output.start() { append(log: err, .failed) }
        refreshOutputStatus()
        // The platform's own: on the Mac, quitting, the Send, the watchdog and the insert scan.
        platformStart()
        vban.receiverName = Self.receiverName(vbanReceiverName)
        vban.receiverInstance = grabberInstance
        vban.ignoresOwnSend = !hostMode
        vban.onLog = { [weak self] kind, text in self?.append(log: text, kind) }
        restartDiscovery()
        if vbanEnabled { resumeManualSenders() }
        restoreWebStreams()
        // Only the numeric figures come through here now; meters are polled by their own views.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    public func shutdown() {
        guard started else { return }
        started = false
        platformShutdown()
        timer?.invalidate()
        sap.stop()
        ravenna?.stop()
        dante?.stop()
        let playing = receivers.count
        append(log: playing == 0 ? "Quit." : "Quit: stopped \(playing) stream\(playing == 1 ? "" : "s").", playing == 0 ? .note : .stopped)
        activity.save()
        vban.unsubscribeAll()       // before the socket closes, so each Sender hears it
        vban.stop()
        scream.stop()
        receivers.values.forEach { $0.stop() }
        receivers.removeAll()
        output.setReceivers([])
        output.stop()
    }

    public func rescanInterfaces() {
        interfaces = Interfaces.listIPv4()
        if !interfaces.contains(where: { $0.name == selectedInterface }) {
            selectedInterface = interfaces.first?.name ?? ""
        }
    }

    /// Clears the discovered list; anything still announcing reappears within seconds.
    public func refreshDiscovery() {
        streams.removeAll { !subscribed.contains($0.id) }
        restartDiscovery()
    }

    public var interfaceAddress: String {
        interfaces.first(where: { $0.name == selectedInterface })?.address ?? "0.0.0.0"
    }

    /// The Wi-Fi interface already warned about, so a restart of discovery does not say it again.
    @ObservationIgnored private var warnedWiFi: String?
    /// Gaps already logged per stream (`StreamReceiver.gaps`).
    @ObservationIgnored private var gapsLogged: [String: Int] = [:]
    /// Keeps App Nap off while a stream plays (`BusyAssertion`).
    @ObservationIgnored private var discoveryRestartPending = false
    @ObservationIgnored private var afterDiscoveryRestart: [() -> Void] = []

    /// A discovery switch in Settings restarts every browser and socket, and doing that inside
    /// the switch's own update held the main thread while the switch was animating, which made
    /// it look sluggish. So it waits one turn of the main queue, and several
    /// switches flipped together cost one restart.
    private func scheduleDiscoveryRestart(then after: (() -> Void)? = nil) {
        if let after { afterDiscoveryRestart.append(after) }
        guard !discoveryRestartPending else { return }
        discoveryRestartPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            discoveryRestartPending = false
            restartDiscovery()
            let queued = afterDiscoveryRestart
            afterDiscoveryRestart = []
            queued.forEach { $0() }
        }
    }

    private func restartDiscovery() {
        guard started else { return }
        sap.stop()
        ravenna?.stop()
        dante?.stop()
        vban.stop()
        scream.stop()
        if !vbanEnabled, vbanError != nil { vbanError = nil }
        guard !selectedInterface.isEmpty else {
            append(log: "No usable network interface found.", .failed)
            return
        }
        discoveryStartedAt = Date()
        warnedLocalNetwork = false
        var mechanisms: [String] = []
        if sapEnabled { sap.start(interfaceAddress: interfaceAddress); mechanisms.append("SAP") }
        if ravennaEnabled, let ravenna { ravenna.start(); mechanisms.append("RAVENNA") }
        if danteEnabled, let dante { dante.start(); mechanisms.append("Dante") }
        if vbanEnabled {
            let err = vban.start()
            if vbanError != err { vbanError = err }
            if let err { append(log: err, .failed) } else { mechanisms.append("VBAN") }
            // Said once when sharing starts, not at every discovery restart.
            let sharing = err == nil ? vban.sharingPort : nil
            let wasSharing = vbanSharingLogged != nil
            vbanSharingLogged = sharing
            if let spare = sharing, !wasSharing {
                // Another copy has 6980 — the app, or a Grabber plugin in a DAW.
                append(log: "VBAN: UDP \(VBAN.port) is in use by another app (the Grabber app, or a Grabber "
                     + "plugin in a DAW?), so this one shares it: Senders offering on the network are found and "
                     + "joined as usual (over port \(spare)); a stream sent straight to this Mac's port "
                     + "\(VBAN.port) goes to the other one.", .note)
            }
        }
        if screamEnabled {
            if let err = scream.start(interfaceAddress: interfaceAddress) {
                append(log: err, .failed)
            } else {
                mechanisms.append("Scream")
                if scream.sharing, !screamSharingLogged {
                    append(log: "Scream: UDP \(Scream.port) is in use by another app (the Grabber app, or a "
                         + "Grabber plugin in a DAW?), so this one shares it: multicast Scream is heard as usual; "
                         + "Scream sent straight to this Mac goes to the other one.", .note)
                }
            }
            screamSharingLogged = scream.sharing
        }
        if mechanisms.isEmpty {
            append(log: "All discovery is switched off — turn one on in Settings, or add an SDP by hand.", .warning)
        } else {
            append(log: "Discovery: \(mechanisms.joined(separator: " + ")) on \(selectedInterface) (\(interfaceAddress)).")
        }

        // Wi-Fi will work, and it is worth saying once what is different about it, because the
        // failure modes look like app faults.
        if Interfaces.isWiFi(selectedInterface), warnedWiFi != selectedInterface {
            warnedWiFi = selectedInterface
            append(log: "\(selectedInterface) is Wi-Fi. AES67 is multicast, and an access point "
                 + "may not forward it at all, may rate-limit it to the slowest associated "
                 + "client, or may flood it to everyone — so a stream can be discovered and "
                 + "still deliver nothing. Arrival jitter is also far higher than on a switch, "
                 + "so expect to need a much larger buffer; watch the jitter and underrun "
                 + "figures rather than guessing.", .warning)
        }
    }

    // MARK: - Discovery intake

    public func ingest(_ sdp: String, source: DiscoverySource, deletion: Bool) {
        guard let desc = SDPParser.parse(sdp, source: source) else { return }
        ingest(desc, deletion: deletion)
    }

    /// Discovery intake for a stream already described. SDP-announced streams arrive through
    /// the overload above; a transport that describes its streams some other way calls this.
    public func ingest(_ description: StreamDescription, deletion: Bool) {
        var desc = description
        let source = desc.source

        if deletion {
            guard !subscribed.contains(desc.id) else { return }
            streams.removeAll { $0.id == desc.id }
            health[desc.id] = nil
            lastSeenAt[desc.id] = nil
            return
        }
        // The beta receivers, off unless switched on (Settings → Discovery).
        if Self.isPlainRTP(desc), !plainRTPEnabled { return }
        if source == .web, !webStreamsEnabled { return }

        if source == .sap && Self.sdpSaysDante(desc.rawSDP) {
            desc.source = .dante
        }

        lastSeenAt[desc.id] = Date()
        if let index = streams.firstIndex(where: { $0.id == desc.id }) {
            // Keep the more specific label rather than the most recent one.
            if desc.source.precedence < streams[index].description.source.precedence {
                desc.source = streams[index].description.source
            }
            if streams[index].description != desc { streams[index].description = desc }
        } else {
            streams.append(DiscoveredStream(description: desc))
            sortStreams()
            if !ignoredStreams.contains(desc.id) {
                append(log: "Found \(desc.name) — \(desc.groupAddress):\(desc.port) (\(desc.formatSummary)) via \(desc.source.label)")
            }
            if pendingRejoin.remove(desc.id) != nil {
                subscribe(desc)
            }
        }
    }

    private func sortStreams() {
        streams.sort {
            let fa = favourites.contains($0.id), fb = favourites.contains($1.id)
            if fa != fb { return fa }
            return $0.description.name.localizedCaseInsensitiveCompare($1.description.name) == .orderedAscending
        }
    }

    /// Adds a stream from a pasted SDP block. Returns an error message on failure.
    public func addManualSDP(_ text: String) -> String? {
        guard let desc = SDPParser.parse(text, source: .manual) else {
            return "That SDP has no readable L16/L24/L32 audio media line."
        }
        if Self.isPlainRTP(desc), !plainRTPEnabled {
            return "That stream names no PTP clock, so it is plain RTP (PipeWire, VLC and the like). "
                + "Turn on RTP without PTP in Settings → Discovery to play it — it is in beta."
        }
        ingest(text, source: .manual, deletion: false)
        if desc.sampleRate != 48000 {
            append(log: "\(desc.name) reports \(desc.sampleRate) Hz, not 48 kHz — it will be rate-converted.")
        }
        return nil
    }

    /// The current track of each playing internet stream, from its ICY metadata; the tick fills it.
    public var nowPlaying: [String: String] = [:]

    // MARK: - VBAN

    private var vbanRefusedLogged: UInt64 = 0
    private var vbanRefusedLoggedAt = Date.distantPast
    private var vbanRebuiltAt: [String: Date] = [:]

    /// Samples the listener's table on the tick. VBAN has no announcements, so this is what
    /// discovery is: a stream is listed while its packets arrive and leaves when they stop.
    ///
    /// `ingest` only mutates `streams` when a description actually differs, so a steady set of
    /// senders publishes nothing here, however many packets they send.
    private func syncVBAN() {
        // Which of a Sender's addresses to list it under: the one on this Grabber's network.
        let mine = interfaces.first { $0.name == selectedInterface }?.address
        if mine != vbanPreferredAddress { vbanPreferredAddress = mine; vban.preferredAddress = mine }
        let (entries, refused, renames) = vban.snapshot()
        for rename in renames { carryOver(rename) }
        for entry in entries {
            let desc = entry.description
            if let current = receivers[desc.id], !sameFormat(current.stream, desc) {
                // The ring is sized by channel count when a receiver is built, so a new format
                // needs a new receiver. At most every two seconds per stream, so a sender that
                // flaps — or someone forging its packets — cannot keep the audio path rebuilding.
                if now(since: vbanRebuiltAt[desc.id]) > 2 {
                    vbanRebuiltAt[desc.id] = Date()
                    unsubscribe(desc.id, leaveSender: false, reason: nil)
                    ingest(desc, deletion: false)
                    subscribe(desc, announce: false)
                    append(log: "\(desc.name) changed format to \(desc.formatSummary); rejoined.")
                }
            } else {
                ingest(desc, deletion: false)
            }
            // The packet time, not the tick time, so a sender that has gone quiet ages out.
            lastSeenAt[desc.id] = Date(timeIntervalSinceReferenceDate: entry.lastSeen)
        }
        // Say once a minute, not per packet, that new streams are being turned away: either the
        // network really has this many, or something is making them up.
        if refused > vbanRefusedLogged, now(since: vbanRefusedLoggedAt) > 60 {
            append(log: "VBAN: turned away \(refused - vbanRefusedLogged) packet(s) from unknown "
                 + "streams. At most \(VBANListener.maxStreams) VBAN streams are listed, "
                 + "\(VBANListener.maxStreamsPerSender) from any one sender, and "
                 + "\(VBANListener.newStreamsPerSecond) new ones a second are admitted.", .warning)
            vbanRefusedLogged = refused
            vbanRefusedLoggedAt = Date()
        }
    }

    /// A VBAN stream changed its name (`VBANListener.renamed`): it is the same stream, so what
    /// the user set on it follows — favourite, joined, mix mode, channel order — and the old
    /// name leaves the list at once instead of lingering for 15 seconds.
    private func carryOver(_ rename: VBANListener.Rename) {
        let old = rename.from, new = rename.to
        let oldName = streams.first { $0.id == old }?.description.name
        if favourites.contains(old) {
            favourites.remove(old)
            favourites.insert(new)
        }
        if let mode = receivers[old]?.mixMode ?? savedMixMode(old) { rememberMixMode(new, mode) }
        if let order = savedChannelOrders[old] {
            var all = savedChannelOrders
            all[new] = order
            savedChannelOrders = all
        }
        let wasOpen = openStreamIDs.contains(old)
        if subscribed.contains(old) {
            // A rename keeps the Sender's link, now for the new name; a move to another address
            // leaves the old one, so the Sender doesn't send twice.
            if !rename.moved { vban.follow(from: old, to: new) }
            unsubscribe(old, leaveSender: rename.moved, reason: nil)   // said below: not the user stopping it
            // Joined again under the new name: now, if it is already listed (its beacon can
            // arrive before the rename is recognised — a test where the
            // stream stopped instead), otherwise when `ingest` lists it, a moment from now.
            if let listed = streams.first(where: { $0.id == new })?.description {
                subscribe(listed, announce: false)
            } else {
                pendingRejoin.insert(new)
            }
        }
        streams.removeAll { $0.id == old }
        lastSeenAt[old] = nil
        health[old] = nil
        if wasOpen { openStreamIDs.remove(old); openStreamIDs.insert(new) }
        let newName = new.split(separator: "/", maxSplits: 1).last.map(String.init) ?? new
        if rename.moved {
            let address = { (id: String) in id.dropFirst(5).split(separator: "/").first.map(String.init) ?? "" }
            append(log: "\(oldName ?? newName): now received from \(address(new)), this Grabber's network; "
                 + "stopped receiving it from \(address(old)), so it plays once.")
        } else {
            append(log: "\(oldName ?? "A VBAN stream") is now called \(newName).")
        }
    }

    private func sameFormat(_ a: StreamDescription, _ b: StreamDescription) -> Bool {
        a.sampleRate == b.sampleRate && a.channels == b.channels && a.encoding == b.encoding
    }

    private func now(since date: Date?) -> TimeInterval {
        date.map { Date().timeIntervalSince($0) } ?? .infinity
    }

    /// VBAN switched off: leave its streams and take them off the list.
    // MARK: - Senders added by address

    /// Adds a Network Audio Sender by address (`host` or `host:port`, port 6981 by default) and
    /// asks it for its stream. Returns an error to show, or nil.
    public func addManualSender(_ text: String) -> String? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard let host = parts.first.map(String.init), ipv4Value(host).map({ $0 != 0 }) == true else {
            return "Type the Sender's IPv4 address, such as 192.0.2.20, or 192.0.2.20:6981."
        }
        let port = parts.count > 1 ? Int(parts[1]) : VBANControl.controlPort
        guard let port, (1...65535).contains(port), parts.count <= 2 else {
            return "The port is a number from 1 to 65535; the Sender's is \(VBANControl.controlPort)."
        }
        let key = "\(host):\(port)"
        guard !vbanManualSenders.contains(key) else { return "\(key) is already in the list." }
        vbanManualSenders.append(key)
        persist("vbanManualSenders", vbanManualSenders)
        if vbanEnabled { vban.addManual(ip: host, port: port, crypto: linkCrypto(for: key)) }
        append(log: "Asking the Sender at \(key) for its stream (added by address).", .request)
        return nil
    }

    // MARK: Remote link
    //
    // The receiving end: its code comes from the VBAN socket (the router's mapping for it); the
    // sending end's code, pasted here, is added as a Sender by address — the ordinary handshake,
    // which the sending end has opened its router to. Nothing to open on either router.

    public private(set) var remoteCode: RemoteCode?
    public private(set) var remoteCodeError: String?
    public private(set) var makingRemoteCode = false
    @ObservationIgnored private var mappingTimer: Timer?
    /// "address:port" of each sending end linked (each also a Sender added by address).
    public private(set) var remoteLinks: [String] = []
    public private(set) var remoteCodeMadeAt: Date?

    /// Each link as the guide lists it: the Sender's stream name once heard, and whether its
    /// handshake is done.
    public var remoteLinkInfo: [RemoteLinkInfo] {
        remoteLinks.map { key in
            let ip = String(key.split(separator: ":").first ?? "")
            let name = streams.first { $0.description.source == .vban && $0.description.originAddress == ip }?.description.name
            return RemoteLinkInfo(key: key, name: name, connected: vbanSenderStates[key] == true)
        }
    }

    /// RENDER HARNESS only: a made-up code, as if made, and made-up links.
    public func setPreviewRemoteCode(_ code: RemoteCode) { remoteCode = code; remoteCodeMadeAt = Date().addingTimeInterval(-4 * 60) }
    public func setPreviewRemoteLinks(_ links: [String]) { remoteLinks = links }

    public func makeRemoteCode() {
        remoteCodeError = nil
        // A Remote link is VBAN: asking for a code is asking for it to be on.
        if !vbanEnabled { vbanEnabled = true }
        makingRemoteCode = true
        vban.makeRemoteCode { [weak self] code in
            guard let self else { return }
            self.makingRemoteCode = false
            guard let code else {
                self.remoteCodeError = "No answer from the address server: this network may block it, or this Mac is offline."
                return
            }
            self.remoteCode = RemoteCode(role: code.role, address: code.address, port: code.port, secret: self.remoteSecret)
            self.remoteCodeMadeAt = Date()
            self.append(log: "Made this Grabber's Remote link code (receiving).", .done)
            self.remoteCodeError = RemoteLinkInfo.linkedBehindSameRouter(self.remoteLinks, own: code)
            // Keep the router's mapping alive for 15 minutes while the code is passed on.
            self.mappingTimer?.invalidate()
            let until = Date().addingTimeInterval(15 * 60)
            self.mappingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] t in
                guard let self, Date() < until else { t.invalidate(); return }
                self.vban.refreshRemoteMapping()
            }
        }
    }

    /// Links the sending end whose code was pasted: asks it for its stream. Nil, or what was wrong.
    public func linkRemote(_ text: String) -> String? {
        guard let code = RemoteCode(text: text) else { return RemoteCode.problem(with: text) }
        guard code.role == .sending else {
            return "That code is from a receiving end. Paste the code from the Sender (or the Grabber's Send) at the other end."
        }
        if code.address == remoteCode?.address { return RemoteLinkInfo.sameRouter }
        let key = "\(code.address):\(code.port)"
        guard !remoteLinks.contains(key) else { return "That end is already linked." }
        // The secret first, so the Sender-by-address it becomes is sealed from its first packet.
        remoteLinkSecrets[key] = RemoteSeal.hex(code.secret)
        persist("remoteLinkSecrets", remoteLinkSecrets)
        if let error = addManualSender(key) {
            remoteLinkSecrets[key] = nil
            persist("remoteLinkSecrets", remoteLinkSecrets)
            return error
        }
        remoteLinks.append(key)
        persist("remoteLinks", remoteLinks)
        append(log: "Remote link: asking the Sender at the other end for its stream.", .request)
        return nil
    }

    /// Ends the link: stops asking that Sender, and forgets it.
    // MARK: Remote link encryption (`RemoteSeal`)

    /// This end's secret, in every code it makes: made once and kept, so a new code doesn't
    /// break a link already made. "Remove all settings" forgets it.
    public var remoteSecret: [UInt8] {
        if let text = defaults.string(forKey: "remoteSecret"), let secret = RemoteSeal.secret(fromHex: text) { return secret }
        let made = RemoteSeal.newSecret()
        defaults.set(RemoteSeal.hex(made), forKey: "remoteSecret")
        return made
    }
    /// Each linked Sender's secret, from its code, by "address:port".
    @ObservationIgnored private var remoteLinkSecrets: [String: String] = [:]
    /// Each link's sealer and opener for this run, made once.
    @ObservationIgnored private var linkCryptos: [String: LinkCrypto] = [:]
    @ObservationIgnored private var droppedOldLinks = 0

    /// A Remote link's encryption, or nil for a Sender added by address (never encrypted).
    private func linkCrypto(for key: String) -> LinkCrypto? {
        if let made = linkCryptos[key] { return made }
        guard let peer = remoteLinkSecrets[key].flatMap(RemoteSeal.secret(fromHex:)) else { return nil }
        let made = LinkCrypto(own: remoteSecret, peer: peer, sendingEnd: false)
        linkCryptos[key] = made
        return made
    }

    /// Whether this stream comes over an encrypted Remote link, for its badge.
    public func isEncryptedLink(_ stream: StreamDescription) -> Bool {
        stream.source == .vban && remoteLinks.contains { $0.hasPrefix(stream.originAddress + ":") }
    }

    public func unlinkRemote(_ key: String) {
        remoteLinks.removeAll { $0 == key }
        persist("remoteLinks", remoteLinks)
        removeManualSender(key)                 // its goodbye still sealed
        remoteLinkSecrets[key] = nil
        persist("remoteLinkSecrets", remoteLinkSecrets)
        linkCryptos[key] = nil
    }

    public func removeManualSender(_ key: String) {
        vbanManualSenders.removeAll { $0 == key }
        persist("vbanManualSenders", vbanManualSenders)
        let parts = key.split(separator: ":")
        if parts.count == 2, let port = Int(parts[1]) { vban.removeManual(ip: String(parts[0]), port: port) }
    }

    /// Whether a Network Audio Sender offered this stream, rather than it being pushed here.
    public func isOfferedVBAN(_ id: String) -> Bool { previewOffered.contains(id) || vban.isOffered(id) }
    /// Streams the render harness shows as offered.
    public var previewOffered: Set<String> = []

    /// For the render harness: added Senders shown as answering or not, without asking any.
    public func setPreviewSenderStates(_ states: [String: Bool], approvals: [String: VBANListener.Approval] = [:]) {
        vbanSenderStates = states
        vbanApprovals = approvals
    }

    private func resumeManualSenders() {
        for key in vbanManualSenders {
            let parts = key.split(separator: ":")
            if parts.count == 2, let port = Int(parts[1]) { vban.addManual(ip: String(parts[0]), port: port, crypto: linkCrypto(for: key)) }
        }
    }

    private func dropVBANStreams() { dropStreams(from: .vban, because: "VBAN was turned off") }

    /// A discovery mechanism was switched off: what it found leaves the list, and anything of it
    /// playing stops, saying why.
    private func dropStreams(from source: DiscoverySource, because reason: String) {
        for stream in streams where stream.description.source == source {
            unsubscribe(stream.id, reason: reason)
            lastSeenAt[stream.id] = nil
        }
        streams.removeAll { $0.description.source == source }
    }

    /// Scream senders heard lately, into the list; a format change rebuilds a joined stream, at
    /// most every two seconds, as VBAN's does.
    private func syncScream() {
        for entry in scream.snapshot() {
            let desc = entry.description
            if let current = receivers[desc.id], !sameFormat(current.stream, desc) {
                if now(since: vbanRebuiltAt[desc.id]) > 2 {
                    vbanRebuiltAt[desc.id] = Date()
                    unsubscribe(desc.id, leaveSender: false, reason: nil)
                    ingest(desc, deletion: false)
                    subscribe(desc, announce: false)
                    append(log: "\(desc.name) changed format to \(desc.formatSummary); rejoined.")
                }
            } else {
                ingest(desc, deletion: false)
            }
            lastSeenAt[desc.id] = Date(timeIntervalSinceReferenceDate: entry.lastSeen)
        }
    }

    // MARK: - Dante

    private var loggedDanteCount = 0

    private func updateDanteDevices(_ devices: [DanteDevice]) {
        
        // Guarded: the browser re-reports its whole list whenever any device resolves, and an
        // unconditional assignment to a `@Published` array is another whole-window update for
        // nothing.
        if danteDevices != devices { danteDevices = devices }
        // Log whenever the count grows, not only on the first sighting — devices trickle in
        // over several seconds and "found 1 device(s)" was stale the moment it was written.
        if devices.count > loggedDanteCount {
            loggedDanteCount = devices.count
            append(log: "Dante: \(devices.count) device(s) — \(devices.map(\.name).joined(separator: ", ")).")
        } else if devices.isEmpty {
            loggedDanteCount = 0
        }
    }

    /// Whether this Dante device is actually publishing an AES67 flow we can receive. A device
    /// can be perfectly healthy on the Dante control plane and still publish nothing — Dante
    /// Virtual Soundcard and Dante Via cannot produce AES67 flows at all, and hardware needs
    /// AES67 mode enabled plus a multicast flow created for it.
    public func danteIsPublishing(_ device: DanteDevice) -> Bool {
        guard let address = device.address else { return false }
        return streams.contains { $0.description.originAddress == address && $0.description.source == .dante }
    }

    /// Whether an announcement comes from Dante: Dante puts `a=keywds:Dante` in every AES67 SDP it
    /// sends. The sender's address being a Dante device is not enough: a PC running
    /// Dante software can also send AES67 from another maker's driver, and its streams were
    /// labelled Dante.
    public static func sdpSaysDante(_ sdp: String) -> Bool {
        sdp.split(whereSeparator: \.isNewline).contains { line in
            let l = line.trimmingCharacters(in: .whitespaces).lowercased()
            return l.hasPrefix("a=keywds:") && l.contains("dante")
        }
    }

    /// True when Dante gear is on the network but none of it is publishing AES67 flows.
    public var danteNeedsAES67: Bool {
        danteEnabled && !danteDevices.isEmpty && !streams.contains { $0.description.source == .dante }
    }

    // MARK: - Subscribing

    public func isSubscribed(_ id: String) -> Bool { subscribed.contains(id) }

    public func toggle(_ stream: StreamDescription) {
        if subscribed.contains(stream.id) { unsubscribe(stream.id) } else { subscribe(stream) }
    }

    /// The one place a protocol's receiver is chosen: a new protocol adds a case here
    /// and to `DiscoverySource`, and everything else — buffering, meters, mixing, the list — is
    /// `StreamReceiver`'s.
    private func makeReceiver(for stream: StreamDescription) -> StreamReceiver {
        let latency = latency(for: stream)
        switch stream.source {
        case .vban:
            return VBANReceiver(stream: stream, latencyMs: latency, listener: vban)
        case .scream:
            return ScreamReceiver(stream: stream, latencyMs: latency, listener: scream)
        case .sap, .ravenna, .dante, .manual:
            return RTPReceiver(stream: stream, latencyMs: latency)
        case .web:
            return makeWebReceiver(for: stream, latencyMs: latency)
        }
    }

    /// `announce: false` for a rebuild of a stream already playing (a format or device change),
    /// which is not a new request.
    /// Why the last attempt to join a stream failed, in words for its row: the
    /// fault shown on the thing that failed, not only in the log. Cleared by a join that works.
    public var joinFailures: [String: String] = [:]

    /// The socket's own error, said as what to do about it.
    public static func plainJoinFailure(_ error: String, port: Int) -> String {
        let e = error.lowercased()
        if e.contains("address already in use") {
            return "Port \(port) is in use by another app on this Mac."
        }
        if e.contains("can't assign requested address") || e.contains("cannot assign requested address") {
            return "This Mac has no address on the chosen network. Pick the network in the menu at the top."
        }
        if e.contains("network is unreachable") || e.contains("no route") {
            return "The chosen network is not connected."
        }
        if e.contains("permission denied") || e.contains("operation not permitted") {
            return "macOS refused the network access. Allow Local Network for this app in Privacy & Security."
        }
        return "Could not open the network connection (\(error))."
    }

    private func subscribe(_ stream: StreamDescription, announce: Bool = true) {
        guard receivers[stream.id] == nil else { return }
        let receiver = makeReceiver(for: stream)
        // A stream a Network Audio Sender offered only flows once asked for.
        if stream.source == .vban { vban.subscribe(streamID: stream.id) }
        // Before the taps are built, not after: a pass-through is defined by how wide the bus
        // is, and `setReceivers` further down would set it too late to matter.
        receiver.busChannels = busChannels
        receiver.setMix(defaultMixMode(for: stream), includeLFE: includeLFE,
                        trimDB: downmixTrimDB, order: channelOrder(for: stream.id))
        if let err = receiver.start(interfaceAddress: interfaceAddress) {
            append(log: "Could not join “\(stream.name)” — \(logDescription(stream)): \(err)", .failed)
            joinFailures[stream.id] = Self.plainJoinFailure(err, port: stream.port)
            return
        }
        joinFailures[stream.id] = nil
        receivers[stream.id] = receiver
        subscribedAt[stream.id] = Date()
        autoStopped[stream.id] = nil
        quietSince[stream.id] = nil
        warnedSilent.remove(stream.id)
        subscribed.insert(stream.id)
        // Joining opens it, wherever the join came from — including the rejoin at launch,
        // which otherwise left two streams playing and the detail pane describing none of
        // them. Only when nothing is open, so a rejoin at launch does not open every row.
        if openStreamIDs.isEmpty { openStreamIDs.insert(stream.id) }
        rememberListening()
        applyMuteStates()
        output.setReceivers(Array(receivers.values))
        onHostLatencyChange?()
        if announce { append(log: "Joining “\(stream.name)” — \(logDescription(stream)).", .request) }
    }

    /// How a stream opens: what it was last set to, else a fold-down if it has a layout that
    /// folds, else its first pair.
    ///
    /// Nothing in an AES67 SDP distinguishes a 7.1 bed from eight discrete feeds, so the
    /// automatic choice is a guess either way. It is made in favour of folding because the
    /// monitoring case this app is for is hearing the whole programme on headphones, and
    /// because the guess is now made **once per stream** rather than every session.
    ///
    /// `foldsDown` rather than a list of layouts, so this and the stream's own mix menu agree by
    /// construction: quad was previously offered a `4.0 → 2.0` in the menu but left out of the
    /// automatic rule, which made auto-fold mean different things at different channel counts.
    private func defaultMixMode(for stream: StreamDescription) -> MixMode {
        // What this stream was last set to wins over any default — including a deliberate
        // `Ch 1/2` on a stream that *would* fold, which is the discrete-feeds case and the
        // whole reason the choice is worth remembering.
        //
        // Validated against the channel count that actually arrived: a stream can be
        // re-announced narrower than it was, and restoring `pair:6` onto it would leave the
        // menu naming channels that do not exist.
        if let remembered = savedMixMode(stream.id),
           remembered.fits(channels: stream.channels),
           suits(remembered, stream) {
            return remembered
        }
        // A bus wide enough to carry the stream plays it channel for channel: there is nothing
        // to fold, and folding would be throwing away the separation the bus exists for.
        if busChannels >= stream.channels, busChannels > 2 { return .passthrough }
        guard autoFoldSurround,
              let layout = SMPTELayout.forChannelCount(stream.channels),
              layout.foldsDown else { return .pair(0) }
        return .downmix
    }

    /// `leaveSender: false` when the stream is only being rebuilt (a format change, a device
    /// change), so a Network Audio Sender is not told to stop and then asked again.
    /// `reason` says why in the log ("you stopped it" by default); nil logs nothing, for a rebuild.
    public func unsubscribe(_ id: String, leaveSender: Bool = true, reason: String? = "you stopped it") {
        guard let receiver = receivers.removeValue(forKey: id) else { return }
        announcedReceiving.remove(id)
        if leaveSender, receiver.stream.source == .vban { vban.unsubscribe(streamID: id) }
        subscribed.remove(id)
        rememberListening()
        subscribedAt[id] = nil
        quietSince[id] = nil
        goneSince[id] = nil
        if goneIDs.contains(id) { goneIDs.remove(id) }
        warnedSilent.remove(id)
        channelSolo[id] = nil
        health[id] = nil
        if soloed == id { soloed = nil }
        output.setReceivers(Array(receivers.values))
        onHostLatencyChange?()
        receiver.stop()
        health[id] = nil
        if let reason { append(log: "Stopped “\(receiver.stream.name)” — \(reason).", .stopped) }
    }

    /// The Grabber plugin's latency, for the host: the buffer the playing streams
    /// play out against — the longest of them — or the PTP buffer when nothing plays. The DAW
    /// uses it to line the network up with the rest of the project.
    public var hostLatencySeconds: Double {
        let buffers = receivers.values.map { latency(for: $0.stream) }
        return (buffers.max() ?? latencyMs) / 1000
    }
    /// Called when it may have changed (a stream joins or leaves, a buffer moves).
    @ObservationIgnored public var onHostLatencyChange: (() -> Void)?

    // MARK: A DAW project's copy (the Grabber plugins)

    /// What a project keeps for the Receiver: what was playing, how each stream was folded and
    /// ordered, and the monitor level. Everything else — look, buffers, discovery — stays the
    /// plugin's own, the same in every project.
    public func projectState() -> [String: Any] {
        var out: [String: Any] = ["listening": Array(subscribed.union(pendingRejoin)),
                                  "masterVolume": masterVolume]
        for key in ["mixModes", "channelOrders"] { if let v = defaults.object(forKey: key) { out[key] = v } }
        return out
    }

    /// Opens a project's copy: its streams play (each as soon as it is found), and anything
    /// else playing stops.
    public func restoreProjectState(_ project: [String: Any]) {
        for key in ["mixModes", "channelOrders"] { if let v = project[key] { defaults.set(v, forKey: key) } }
        if let v = project["masterVolume"] as? Double { masterVolume = v }
        let wanted = Set(project["listening"] as? [String] ?? [])
        for id in subscribed where !wanted.contains(id) { unsubscribe(id, reason: "not playing in this project") }
        pendingRejoin = wanted.subtracting(subscribed)
        for stream in streams where pendingRejoin.contains(stream.id) {
            pendingRejoin.remove(stream.id)
            subscribe(stream.description)
        }
        rememberListening()
        append(log: "Opened the project's streams: \(wanted.count) to play.", .note)
    }

    private func rememberListening() {
        // Union with what is still pending: rejoining one of two saved streams must not throw
        // the other away just because it has not been announced yet.
        defaults.set(Array(subscribed.union(pendingRejoin)), forKey: "listening")
    }

    public func unsubscribeAll(leaveSender: Bool = true, reason: String? = "Stop all") {
        for id in Array(receivers.keys) { unsubscribe(id, leaveSender: leaveSender, reason: reason) }
    }

    private func restartAllReceivers() {
        let active = receivers.values.map(\.stream)
        unsubscribeAll(leaveSender: false, reason: nil)
        active.forEach { subscribe($0, announce: false) }
    }

    // MARK: - Per-stream controls

    public func receiver(for id: String) -> StreamReceiver? { receivers[id] }

    /// Bumped whenever a receiver's mix, order or gain changes. Those live on the receiver, which
    /// is not observable, so the getters below read this to make the views that show them
    /// refresh — and only those views.
    public private(set) var mixRevision = 0

    public func mixMode(for id: String) -> MixMode {
        _ = mixRevision
        return receivers[id]?.mixMode ?? previewMixModes[id] ?? .pair(0)
    }

    /// The render harness has no receivers, so without this every stream in its shots read
    /// `Ch 1/2` and a 7.1 bed never showed the fold it gets in use. Filled only by the harness.
    public var previewMixModes: [String: MixMode] = [:]


    /// What each listed stream would be set to on joining, for the render harness.
    public func previewDefaultMixes() {
        previewMixModes = Dictionary(uniqueKeysWithValues:
            streams.map { ($0.id, defaultMixMode(for: $0.description)) })
        mixRevision &+= 1
    }

    /// How each stream was last listened to, keyed by `group:port` — stable across sessions,
    /// and the same identity `listening` uses.
    ///
    /// Persisted because the app rejoins what you were listening to at launch, so without this
    /// every restart put a 7.1 bed back on its first pair. Channel *solo* is deliberately not
    /// remembered (see Outstanding): a solo is something you do while listening, whereas the
    /// mix mode is how a stream is wired.
    private var savedMixModes: [String: String] {
        get { defaults.dictionary(forKey: "mixModes") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "mixModes") }
    }

    /// Remembered **per stream and per bus width.**
    ///
    /// A mode means different things on different buses: `Ch 1/2` on a stereo bus is the whole
    /// of what the bus can carry, while the same choice on a 16-channel bus is a deliberate
    /// restriction to the front pair. Keyed by width, a choice made when the bus was stereo
    /// cannot silently outrank a bus that has since been widened — which it did, and which made
    /// a 7.1 stream look as though multichannel output was not working at all.
    private func mixModeKey(_ id: String) -> String { "\(id)@\(busChannels)" }

    private func rememberMixMode(_ id: String, _ mode: MixMode) {
        var all = savedMixModes
        all[mixModeKey(id)] = mode.token
        savedMixModes = all
    }

    /// Channel order chosen for individual streams, keyed by `group:port`.
    ///
    /// Per stream because the order is a property of the *sender*, not of this app or the
    /// monitor rig — two devices on one network can perfectly well disagree, and only the
    /// person who knows the senders can say which is which.
    private var savedChannelOrders: [String: String] {
        get { defaults.dictionary(forKey: "channelOrders") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "channelOrders") }
    }

    /// The order in force for one stream: its own, else the global default.
    public func channelOrder(for id: String) -> ChannelOrder {
        savedChannelOrders[id].flatMap(ChannelOrder.init(rawValue:)) ?? channelOrder
    }

    /// Whether this stream has been given an order of its own.
    public func hasOwnChannelOrder(_ id: String) -> Bool { savedChannelOrders[id] != nil }

    public func setChannelOrder(_ id: String, _ order: ChannelOrder?) {
        var all = savedChannelOrders
        if let order { all[id] = order.rawValue } else { all[id] = nil }
        savedChannelOrders = all
        guard let receiver = receivers[id] else { return }
        receiver.setMix(receiver.mixMode, includeLFE: includeLFE, trimDB: downmixTrimDB,
                        order: channelOrder(for: id), soloed: soloedChannels(id))
        let name = receiver.stream.name
        append(log: order == nil
            ? "\(name): channel order follows the default (\(channelOrder.name))."
            : "\(name): channel order set to \(channelOrder(for: id).menuLabel(channels: receiver.stream.channels)).")
        mixRevision &+= 1
    }

    private func savedMixMode(_ id: String) -> MixMode? {
        if let token = savedMixModes[mixModeKey(id)] { return MixMode(token: token) }
        // Preferences written before the bus had a width were all written on a stereo bus.
        if busChannels == 2, let token = savedMixModes[id] { return MixMode(token: token) }
        return nil
    }

    public func setMixMode(_ id: String, _ mode: MixMode) {
        receivers[id]?.setMix(mode, includeLFE: includeLFE, trimDB: downmixTrimDB,
                              order: channelOrder(for: id), soloed: soloedChannels(id))
        rememberMixMode(id, mode)
        mixRevision &+= 1
    }

    private func reapplyMixes() {
        for (id, r) in receivers {
            r.setMix(r.mixMode, includeLFE: includeLFE, trimDB: downmixTrimDB,
                     order: channelOrder(for: r.stream.id),
                     soloed: soloedChannels(id))
        }
    }

    public func setGain(_ id: String, _ gain: Float) {
        receivers[id]?.gain = gain
        mixRevision &+= 1
    }

    public func gain(for id: String) -> Float { _ = mixRevision; return receivers[id]?.gain ?? 1 }

    public var userMuted: Set<String> = [] { didSet { applyMuteStates() } }

    public func isMuted(_ id: String) -> Bool { userMuted.contains(id) }

    public func toggleMute(_ id: String) {
        if userMuted.contains(id) { userMuted.remove(id) } else { userMuted.insert(id) }
    }

    public func toggleSolo(_ id: String) { soloed = (soloed == id) ? nil : id }

    // MARK: - Channel solo
    //
    // Which channels *within* one stream are being monitored. Not persisted, and cleared when a
    // stream is dropped: it is a thing you do while listening to something, like the stream
    // solo above, rather than a setting.

    private var channelSolo: [String: Set<Int>] = [:]

    public func soloedChannels(_ id: String) -> Set<Int> { channelSolo[id] ?? [] }

    public func isChannelSoloed(_ id: String, _ channel: Int) -> Bool {
        channelSolo[id]?.contains(channel) ?? false
    }

    /// Any channel solo at all on this stream — the row and the panel both change appearance.
    public func hasChannelSolo(_ id: String) -> Bool { !(channelSolo[id] ?? []).isEmpty }

    public func toggleChannelSolo(_ id: String, _ channel: Int) {
        // Bound-checked against the announced stream rather than the receiver: the channel
        // count is a property of the stream, and keying off the description keeps this usable
        // before a receiver exists (which is how the render harness reaches it).
        guard let channels = streams.first(where: { $0.id == id })?.description.channels,
              channel >= 0, channel < channels else { return }
        var set = channelSolo[id] ?? []
        if set.remove(channel) == nil { set.insert(channel) }
        setChannelSolo(id, set)
    }

    /// Solos every channel the fold-down would place on one side, so "monitor the rears" is one
    /// click rather than two. `names` are matched against the SMPTE names for the layout.
    public func soloChannels(_ id: String, named names: [String]) {
        guard let channels = streams.first(where: { $0.id == id })?.description.channels,
              let layout = SMPTELayout.forChannelCount(channels) else { return }
        let wanted = Set(names)
        var set: Set<Int> = []
        for (index, name) in layout.channelNames.enumerated() where wanted.contains(name) {
            set.insert(index)
        }
        // Toggle: asking for the group that is already soloed clears it.
        setChannelSolo(id, soloedChannels(id) == set ? [] : set)
    }

    public func clearChannelSolo(_ id: String) { setChannelSolo(id, []) }

    private func setChannelSolo(_ id: String, _ set: Set<Int>) {
        if set.isEmpty { channelSolo[id] = nil } else { channelSolo[id] = set }
        guard let receiver = receivers[id] else { return }
        receiver.setMix(receiver.mixMode, includeLFE: includeLFE, trimDB: downmixTrimDB,
                        order: channelOrder(for: id), soloed: set)
    }

    /// Effective mute = the user muted it, or something else is soloed.
    private func applyMuteStates() {
        for (id, r) in receivers {
            r.muted = userMuted.contains(id) || (soloed != nil && soloed != id)
        }
    }

    public func toggleFavourite(_ id: String) {
        if favourites.contains(id) { favourites.remove(id) } else { favourites.insert(id) }
        sortStreams()
    }

    // MARK: - Filtering

    public var visibleStreams: [DiscoveredStream] {
        streams.filter { stream in
            if ignoredStreams.contains(stream.id) { return false }
            if goneIDs.contains(stream.id) { return false }         // listed under Gone instead
            if let sourceFilter, stream.description.source != sourceFilter { return false }
            if showActiveOnly && !subscribed.contains(stream.id) { return false }
            guard !searchText.isEmpty else { return true }
            let d = stream.description
            return d.name.localizedCaseInsensitiveContains(searchText)
                || d.groupAddress.contains(searchText)
                || d.source.rawValue.localizedCaseInsensitiveContains(searchText)
                || d.source.label.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: - Output device

    public func refreshOutputStatus() {
        outputDeviceName = output.deviceName
        outputRate = output.deviceRate
        outputChannels = output.deviceChannels
        if busChannels != output.busChannels { busChannels = output.busChannels }
        applyRememberedBusWidth()
        refreshInsertStatus()
        outputRunning = output.running
    }

    /// Applies whatever width this output device was last set to, when the device changes
    /// under us. A rig that cannot carry the remembered width falls back to stereo and says so
    /// rather than reverting the choice, which would lose it for when that rig comes back.
    private func applyRememberedBusWidth() {
        let uid = output.deviceUID
        guard !uid.isEmpty else { return }
        let wanted = savedBusWidths[uid] ?? 2
        guard wanted != output.requestedBusChannels else { return }
        let applied = output.setBusChannels(wanted)
        busChannels = output.busChannels
        if wanted > 2 {
            append(log: applied == wanted
                ? "Output bus: \(busWidthLabel(applied)) — remembered for \(outputDeviceName)."
                : "Output bus: \(busWidthLabel(wanted)) is remembered for this device, but "
                + "\(outputDeviceName) offers \(outputChannels) channels — using "
                + "\(busWidthLabel(applied)).")
        }
        revisitMixModes()
    }

    /// The live engine's node graph, for `--selftest` to print. Structural detail only.
    public var audioGraphSummary: String { output.graphSummary }

    /// Where the playout latency actually goes. The user sets one number; the floor under it is
    /// the output device's buffer plus a couple of packets, and what is left over is the only
    /// part that absorbs network jitter.
    public var latencyBudget: String {
        let rate = max(1, outputRate)
        func ms(_ frames: Double) -> String { String(format: "%.1f ms", frames / rate * 1000) }
        let block = Double(output.renderBlockFrames)
        let device = Double(output.deviceBufferFrames)
        var lines = ["requested \(Int(latencyMs)) ms (VBAN \(Int(vbanLatencyMs)) ms)"
                   + "   device buffer \(Int(device)) frames (\(ms(device)))"
                   + "   render block \(Int(block)) frames (\(ms(block)))"]
        for (id, r) in receivers {
            let name = streams.first(where: { $0.id == id })?.description.name ?? id
            let packet = Double(r.stream.framesPerPacket)
            let target = r.playoutTargetFrames
            let floor = block + packet * 2
            let headroom = max(0, target - floor)
            lines.append("  \(name): ptime \(ms(packet)), target \(Int(target)) frames "
                       + "(\(ms(target))), floor \(Int(floor)) frames (\(ms(floor))), "
                       + "jitter headroom \(ms(headroom))")
            if let f = figures(id) {
                lines.append(String(format: "    arrival jitter %.2f ms (worst %.1f ms), "
                                  + "lowest buffer %.1f ms, drift %+.0f ppm",
                                    f.jitterMs, f.worstJitterMs, f.minBufferMs, f.driftPPM))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// How often the metering tap actually fires, and with what block size.
    public var meterTapSummary: String {
        guard output.tapFrames > 0 else { return "no callbacks yet" }
        return String(format: "%d frames, %.0f Hz (%.1f ms)",
                      output.tapFrames, output.tapHz,
                      output.tapHz > 0 ? 1000 / output.tapHz : 0)
    }

    /// The output device's own buffer size, in frames. This is the floor under the whole playout
    /// budget: a receiver cannot be asked for less than one render block plus a packet or two,
    /// so a device sitting at 512 frames spends 10.7 ms of the buffer setting before any
    /// of it absorbs network jitter.
    public var outputBufferFrames: UInt32 { output.deviceBufferFrames }

    @discardableResult
    public func setOutputBufferFrames(_ frames: UInt32) -> Bool {
        let ok = output.setDeviceBufferFrames(frames)
        append(log: ok ? "Output device buffer set to \(frames) frames."
                       : "Could not set the output device buffer to \(frames) frames.")
        if ok, let err = output.start() { append(log: err) }
        refreshOutputStatus()
        return ok
    }

    /// Rates this device offers. 48 kHz first in the menu if it is there, since it is the one
    /// AES67 uses, but everything the device supports is listed — including whatever it was on
    /// before the app suggested changing it.
    public var outputSampleRates: [Double] { output.deviceSampleRates }

    public func setOutputSampleRate(_ rate: Double) {
        guard output.setDeviceSampleRate(rate) else {
            append(log: "\(outputDeviceName) refused \(Int(rate)) Hz.")
            return
        }
        append(log: "\(outputDeviceName) set to \(Int(rate)) Hz. This is the device's own "
             + "setting, so every app on this Mac now sees it.")
        refreshOutputStatus()
    }

    public func clearClip() {
        output.clearClip()
        clipped = false
    }

    /// Channel labels for a stream: SMPTE names when it is being folded down and the channel
    /// count matches a known layout, otherwise plain numbers.
    public func channelLabels(for stream: StreamDescription, folded: Bool) -> [String] {
        // Names come from the order in force for this stream, so an ITU 5.1 stream labels its
        // third channel Ls rather than C. Unfolded streams stay numeric: a discrete feed has no
        // roles, and numbering is what its channels actually are.
        if folded {
            let roles = channelOrder(for: stream.id).roles(channels: stream.channels)
            if roles.count > 2 { return roles.map(\.label) }
        }
        return (1...max(1, stream.channels)).map(String.init)
    }

    // MARK: - Timer


    /// Counts ticks, for the once-a-second work.
    public private(set) var tickCount = 0

    private func tick() {
        tickCount &+= 1
        platformTickAlways()
        // **1 Hz when nothing plays**: with no receivers and the
        // meters settled, the list, the VBAN table, the readouts and the stale scan change at
        // most once a second, so three ticks in four do only what must stay prompt — the VBAN
        // handshake's timers. Joining a stream builds a receiver, which puts the tick back to 4 Hz.
        if receivers.isEmpty && !metersActive && tickCount % 4 != 0 {
            if vbanEnabled { vban.service() }
            return
        }
        // The platform's: on the Mac, the inserts' health, the readouts and the figures' beat.
        platformTick()
        if tickCount % 4 == 0 { refreshNowPlaying() }
        checkBonjourReachable()
        if screamEnabled { syncScream() }
        if vbanEnabled {
            syncVBAN()
            vban.service()
            let states = Dictionary(vban.subscriptionStates().filter(\.manual).map { ("\($0.ip):\($0.port)", $0.established) },
                                    uniquingKeysWith: { a, _ in a })
            if states != vbanSenderStates { vbanSenderStates = states }
            let approvals = vban.approvals()
            if approvals != vbanApprovals { vbanApprovals = approvals }
        }
        if clipped != output.clipped { clipped = output.clipped }
        // Still drawing after the last stream leaves, until the output meters have fallen to
        // nothing. A paused meter draws one last frame and keeps it, which left the
        // master bars frozen wherever "Stop all" caught them. Only ever extends a running state.
        // "Nothing" is −100 dBFS, not 0: the tap keeps measuring the silent bus and the
        // envelope settles on a residue around 1e-40, which would keep the meters awake forever.
        let floor: Float = 1e-5
        let falling = metersActive
            && ((0..<busChannels).contains { outputPeak($0) > floor } || outputPeakHold > floor)
        setBusy(!receivers.isEmpty)
        let active = !receivers.isEmpty || falling
        if metersActive != active { metersActive = active }
        let now = Date()
        // Mutating a array always notifies, so only touch it when something is
        // genuinely stale — otherwise every tick re-renders the whole list for nothing.
        let isStale: (DiscoveredStream) -> Bool = {
            // A stream auto-stop stopped stays while its row says so.
            guard !self.subscribed.contains($0.id), self.autoStopped[$0.id] == nil else { return false }
            let seen = self.lastSeenAt[$0.id] ?? now
            let limit: TimeInterval
            switch $0.description.source {
            case .vban:   limit = VBANListener.forgetAfter
            case .scream: limit = ScreamListener.forgetAfter
            case .web:    limit = .infinity          // added by hand, kept until removed
            case .manual: limit = self.keepManualStreams ? .infinity : self.staleAfter
            default:      limit = self.staleAfter
            }
            return now.timeIntervalSince(seen) > limit
        }
        if streams.contains(where: isStale) {
            for stream in streams where isStale(stream) { lastSeenAt[stream.id] = nil }
            streams.removeAll(where: isStale)
        }

        var updated: [String: StreamHealth] = [:]
        for (id, r) in receivers {
            // Waiting for a Sender's user to allow this Grabber is not silence: nothing is due
            // yet, and "pick another NIC" would send someone looking in the wrong place. The
            // four seconds start when the wait ends.
            if vbanApprovals[id] != nil { subscribedAt[id] = now }
            if r.packetsReceived == 0, !warnedSilent.contains(id),
               now.timeIntervalSince(subscribedAt[id] ?? now) > 4 {
                warnedSilent.insert(id)
                append(log: "No packets from \(r.stream.name) on \(selectedInterface). "
                     + "If the sender is on another NIC, pick it in the network menu.", .warning)
            }
            let before = health[id]
            if r.gaps > (gapsLogged[id] ?? 0) {
                gapsLogged[id] = r.gaps
                append(log: String(format: "“%@”: no audio arrived for %.1f s, then it resumed. The "
                                 + "sender paused or rebuilt its capture, or the network held the packets.",
                                   r.stream.name, r.lastGapMs / 1000), .warning)
            }
            if r.isReceiving, !announcedReceiving.contains(id) {
                announcedReceiving.insert(id)
                append(log: "Receiving “\(r.stream.name)” — \(r.stream.formatSummary).", .done)
            }
            // Auto-stop's clock: from the moment this stream last had audio (or was joined).
            if r.isReceiving { quietSince[id] = nil } else if quietSince[id] == nil { quietSince[id] = now }
            updated[id] = StreamHealth(receiving: r.isReceiving,
                                       lost: r.packetsLost,
                                       underruns: r.underruns,
                                       lastUnderrun: r.underruns > (before?.underruns ?? 0)
                                           ? now : before?.lastUnderrun)
        }
        // Only the glanceable state is published, and only when it moves. Everything that
        // climbs continuously is polled instead.
        if updated != health { health = updated }
        updateGone(now)
        if autoStopStreams {
            let limit = TimeInterval(autoStopStreamsMinutes * 60)
            for (id, since) in quietSince where now.timeIntervalSince(since) >= limit {
                let minutes = autoStopStreamsMinutes
                unsubscribe(id, reason: "no audio for \(Self.minutesText(minutes)), so auto-stop stopped it "
                                + "(Settings → Playout → Auto-stop)")
                autoStopped[id] = AutoStop(at: now, minutes: minutes)
            }
        }
        if outputRunning != output.running { outputRunning = output.running }
        if outputDeviceName != output.deviceName || outputRate != output.deviceRate {
            refreshOutputStatus()
        }
    }

    /// Bonjour browsing is gated by macOS Local Network privacy, and when it is denied the
    /// browsers still report `ready` and simply return nothing — while SAP multicast keeps
    /// working. That combination looks exactly like a bug in this app, so name it explicitly.
    private func checkBonjourReachable() {
        guard !warnedLocalNetwork, ravennaEnabled || danteEnabled,
              let since = discoveryStartedAt, Date().timeIntervalSince(since) > 20 else { return }
        let sawBonjour = streams.contains { $0.description.source == .ravenna } || !danteDevices.isEmpty
        guard !sawBonjour else {
            warnedLocalNetwork = true          // it works; stop checking
            return
        }
        warnedLocalNetwork = true
        append(log: "No Bonjour results after 20 s. If RAVENNA or Dante gear is on this network, "
             + "grant Network Audio Grabber access in System Settings → Privacy & Security → Local Network. "
             + "SAP keeps working when that is denied, so streams can still appear.", .warning)
    }

    // MARK: - Log

    public func append(log message: String, _ kind: ActivityLog.Kind = .note) {
        activity.add(kind, message)
    }

    /// How a stream is described in the log: its protocol and where it comes from.
    private func logDescription(_ s: StreamDescription) -> String {
        switch s.source {
        case .vban:
            return vban.isOffered(s.id) ? "VBAN from Network Audio Sender at \(s.originAddress)"
                                        : "VBAN from \(s.originAddress)"
        case .scream:
            return "Scream from \(s.originAddress)"
        case .web:
            return "internet stream at \(s.groupAddress)"
        default:
            return "\(s.source.label), group \(s.groupAddress):\(s.port)"
        }
    }

    // MARK: - What each platform adds (overridden by the Mac's `AppState`)

    /// At `start`, once the output runs.
    open func platformStart() {}
    /// At `shutdown`, first.
    open func platformShutdown() {}
    /// Every tick (4 Hz), before anything else.
    open func platformTickAlways() {}
    /// Every tick something plays or the meters move (else once a second).
    open func platformTick() {}
    /// When the output's status is refreshed: the platform's inserts.
    open func refreshInsertStatus() {}
    /// Internet streams: the platform decodes them.
    open func restoreWebStreams() {}
    open func refreshNowPlaying() {}
    open func makeWebReceiver(for stream: StreamDescription, latencyMs: Double) -> StreamReceiver {
        StreamReceiver(stream: stream, latencyMs: latencyMs)
    }
    /// The receiver name changed (the Mac's Send follows it).
    open func receiverNameChanged(_ name: String) {}
    /// Keep the system from napping the app while a stream plays.
    open func setBusy(_ busy: Bool) {}
    /// The app's version, for the log's first line.
    open func appVersion() -> String { "" }
}
