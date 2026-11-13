import Foundation
import Observation

/// Everything a Sender does — its stream, targets, who may listen, Remote links, broadcast,
/// auto-stop, and the capture's life — with nothing of a platform's own. Each app subclasses it for what only it has: on the Mac,
/// `SenderState` adds the look, the inserts and the hooks below. Was `SenderState` itself.
@Observable
open class SendEngine {
    // MARK: Stream

    public var streamName: String {
        didSet {
            persist("streamName", streamName); reconfigure()
            if oldValue != streamName { note(.note, "Stream renamed to “\(VBAN.wireName(streamName))”.") }
        }
    }
    /// A new default name, taken only while no name has been chosen — and still not saved as a
    /// choice, so the stream keeps following the Grabber's name until it is renamed here.
    public func adoptDefaultName(_ name: String) {
        guard defaults.string(forKey: "streamName") == nil else { return }
        let wire = VBAN.wireName(name)
        guard !wire.isEmpty, wire != streamName else { return }
        streamName = wire
        defaults.removeObject(forKey: "streamName")
    }
    public var dataType: VBAN.DataType {
        didSet {
            persist("dataType", Int(dataType.rawValue)); reconfigure()
            if oldValue != dataType { note(.note, "Quality set to \(dataType == .int24 ? "24" : "16")-bit.") }
        }
    }
    /// Silence the Mac's own speakers while sending, so the audio goes only to the network.
    public var muteThisMac: Bool {
        didSet { persist("muteThisMac", muteThisMac); restartCaptureIfRunning() }
    }
    /// Mix to stereo rather than send the output device's own channel count.
    public var stereoOnly: Bool {
        didSet { persist("stereoOnly", stereoOnly); restartCaptureIfRunning() }
    }
    /// Start sending again, on opening, to whatever was being sent to at quit.
    public var resumeSending: Bool { didSet { persist("resumeSending", resumeSending) } }

    // MARK: Auto-stop
    //
    // Off by default: a target is sent to until stopped. On, a target this Mac cannot reach —
    // the network reports the host down or unreachable — for the time chosen is stopped, and its
    // row says so. (A reachable address nobody listens on cannot be told apart over UDP; a
    // listening Grabber that goes away is already dropped after 15 s.)
    public var autoStopSends: Bool { didSet { persist("autoStopSends", autoStopSends) } }
    public var autoStopSendsMinutes: Int { didSet { persist("autoStopSendsMinutes", autoStopSendsMinutes) } }
    public static let autoStopChoices = [1, 5, 15, 30, 60, 120, 480, 1440]
    public static func minutesText(_ m: Int) -> String { m < 60 ? "\(m) min" : "\(m / 60) h" }
    /// Where the setting is, for the row's tooltip: the Sender's own Settings, or the Grabber's.
    public var settingsPath = "Settings → Auto-stop"
    /// Targets being sent to that this Mac cannot reach right now.
    public private(set) var unreachableTargets: Set<UUID> = []
    /// Targets auto-stop stopped, and when: the row says so until sent to again.
    public private(set) var autoStoppedTargets: [UUID: (at: Date, minutes: Int)] = [:]
    /// RENDER HARNESS only: targets shown as unreachable or auto-stopped.
    public func setPreviewReachability(unreachable: Set<UUID>, autoStopped stopped: [UUID]) {
        unreachableTargets = unreachable
        for id in stopped { autoStoppedTargets[id] = (Date(), autoStopSendsMinutes) }
    }
    public func autoStopNote(_ id: UUID) -> String? {
        guard let stop = autoStoppedTargets[id] else { return nil }
        let time = stop.at.formatted(date: .omitted, time: .shortened)
        return "Stopped at \(time): \(thisMachine) could not reach it for \(Self.minutesText(stop.minutes)), "
            + "and auto-stop is on (\(settingsPath)). Press play to send again."
    }

    // MARK: Targets

    public var targets: [SendTarget] { didSet { saveTargets(); reconfigure() } }
    /// Which targets are being sent to. Never persisted — see `SendTarget`.
    public var sending: Set<UUID> = [] {
        didSet {
            reconfigure()
            updateCapture()
            wakeIfNeeded(); sleepIfIdle()
            if !previewOnly { persist("lastSending", sending.map(\.uuidString)) }
        }
    }
    // MARK: Offer (VBAN stage 3)

    /// Offer the stream to Grabbers on this network: they list it, and one click starts it
    /// flowing to them. Off by default, and like sending it only comes back on at launch if
    /// "Resume sending when opened" is on — see `VBANOffer` for why it is opt-in.
    public var offering = false {
        didSet {
            if !previewOnly { persist("lastOffering", offering) }
            if oldValue != offering {
                if offering {
                    note(.request, "Offering “\(VBAN.wireName(streamName))” to Grabbers on this network (VBAN), "
                         + (askFirst ? "asking before a new one listens." : "to anyone who presses play."))
                } else {
                    note(.stopped, "Stopped offering"
                         + (listeners.isEmpty ? "." : " — \(listeners.count) listening dropped."))
                }
            }
            if !offering { listeners = [] }
            reconfigure()
            updateCapture()
            wakeIfNeeded(); sleepIfIdle()
        }
    }
    /// The Grabbers listening now, by subscription.
    public private(set) var listeners: [VBANOffer.Subscriber] = []
    /// Ask before a Grabber this Mac has not allowed yet starts listening. On by default: it is
    /// the difference between "anyone on the network can listen" and "anyone you say yes to".
    public var askFirst: Bool { didSet { persist("askBeforeListening", askFirst); reconfigure() } }
    /// The networks the offer announces on, by interface name — any number, since a Mac can be
    /// on several at once; empty for every local network (the default, and how it always was).
    /// "Send to" targets are unaffected: they go wherever this Mac routes their address.
    public var offerInterfaces: Set<String> {
        didSet {
            persist("offerInterfaces", offerInterfaces.sorted())
            // Unticking a network also stops the Grabbers listening through it, so the menu
            // means "send on these networks", not only "announce on them". Every network — nothing ticked — keeps everyone.
            if !offerInterfaces.isEmpty, !previewOnly {
                let kept = networks.filter { offerInterfaces.contains($0.name) }
                let stopped = offer.stopListeners(outside: kept)
                if stopped > 0 {
                    note(.note, "Stopped sending to \(stopped) Grabber\(stopped == 1 ? "" : "s") on a network no "
                         + "longer ticked. Tick it again to let them rejoin.")
                }
            }
            reconfigure()
        }
    }
    /// The Mac's output device and its rate, for the header: what the capture taps.
    public private(set) var outputDeviceName = ""
    public private(set) var outputRate = 0
    /// Render-harness stand-ins, so screenshots never show this Mac's own device or networks.
    public var previewOutput: (name: String, rate: Int)? {
        didSet { if let previewOutput { outputDeviceName = previewOutput.name; outputRate = previewOutput.rate } }
    }
    public var previewNetworks: [LocalNetwork]?

    /// The networks the header's menu offers.
    public var networks: [LocalNetwork] { previewNetworks ?? (previewOnly ? [] : LocalNetworks.list()) }
    /// Grabbers asking to listen, waiting for Allow or Deny.
    public private(set) var requests: [VBANOffer.Subscriber] = []
    /// Grabbers allowed to listen, by address, with the name each last reported.
    public private(set) var allowedGrabbers: [String: String] = [:]
    /// Each allowed Grabber's identity, by the address it was allowed at: it is let
    /// in from its Mac's other addresses too, without asking again. Older Grabbers give none.
    public private(set) var allowedGrabberIDs: [String: String] = [:]
    /// Grabbers denied since the Sender opened, by address — refused until allowed here or the
    /// Sender reopens. Not saved.
    public private(set) var deniedGrabbers: [VBANOffer.Subscriber] = []
    /// The last name each Grabber reported, by address. Remembered, so a target with that
    /// address can show it even when that Grabber is not listening.
    public private(set) var reportedNames: [String: String] = [:]
    /// Something is going out: a target is on, or a Grabber is listening.
    public var isActive: Bool { !sending.isEmpty || !listeners.isEmpty }

    public var draftHost = ""
    public var draftPort = String(VBAN.port)
    public var draftError: String?

    // MARK: Status

    public private(set) var captureStatus: CaptureStatus = .idle
    public private(set) var bitrateKbps: Double = 0
    /// True once sending has run for a few seconds with nothing but silence captured — the
    /// shape of a denied audio-recording permission, and also of a Mac playing nothing.
    public private(set) var quietForAWhile = false
    /// The capture is running and macOS has delivered nothing at all — not silence, nothing.
    /// That is what an ungranted audio-recording permission looks like, and it is worth saying
    /// so plainly rather than letting it pass for a Mac that is playing nothing.
    public private(set) var captureBlocked = false
    private var captureStartedAt: Date?

    public let defaults: UserDefaults
    /// What the Sender did and why, kept between launches (Settings → Log).
    public let activity: ActivityLog
    /// Into the log (or the Grabber's, for its Send). Platforms add to it too.
    public func note(_ kind: ActivityLog.Kind, _ text: String) {
        guard !previewOnly else { return }
        if let logSink { logSink(kind, "Send: " + text); return }
        activity.add(kind, text)
    }
    private let transmitter: VBANTransmitter
    @ObservationIgnored private lazy var offer = VBANOffer(socket: { [transmitter] in
        transmitter.openIfNeeded()
        return transmitter.udpSocket
    }, instance: offerTag)
    /// This Sender's identity in its beacons, kept in its own settings.
    @ObservationIgnored private var offerTag: [UInt8] = []
    /// What the Sender last captured, for the beacon while nothing is being captured.
    private var lastFormat = (rate: 48000, channels: 2)
    /// Handshake events, for the self-test.
    public var onOfferLog: ((String) -> Void)?
    /// The inserts, if this platform has them.
    public let processor: SendProcessor?
    private let meter = SendMeter()
    /// This Mac's audio. Always there: both apps need macOS 14.2, where process taps arrived.
    /// Nil in the Audio Unit, which sends its track instead (`hostFeed`).
    public let capture: SystemAudioSource?
    /// The Audio Unit's track: the source in place of the system capture.
    public let hostFeed: TrackAudioSource?
    /// Sending a DAW track, not this Mac's audio: the words change to match.
    public var sendsTrack: Bool { hostFeed != nil }
    /// The Audio Unit only: the track carries on to its output while being sent (the default),
    /// or is silenced in the host while something is sent.
    public var passThrough: Bool {
        didSet { persist("passThrough", passThrough); applyPassThrough() }
    }
    private func applyPassThrough() { hostFeed?.setPasses(passThrough || !isActive) }
    @ObservationIgnored private var timer: Timer?
    private var lastBytes: UInt64 = 0
    private var lastSample = Date()
    private var quietSince: Date?

    /// `onDemand`: the Grabber's Send (see `onDemand`). `hostFeed`: the Audio Unit's, which
    /// sends its track rather than capturing the Mac.
    /// `defaultName`: the stream's name until one is chosen (the Grabber's Send takes the
    /// Grabber's own, so one Mac shows up under one name).
    /// `capture`: this machine's audio, made by the platform (nil with a `hostFeed`).
    /// `processor`: the inserts, if the platform has them. `logFile`: where the log is kept, or
    /// nil for one in memory only.
    public init(defaults: UserDefaults = .standard, onDemand: Bool = false, hostFeed: TrackAudioSource? = nil,
                defaultName: String? = nil, capture: SystemAudioSource?, processor: SendProcessor?, logFile: URL?) {
        self.defaults = defaults
        self.onDemand = onDemand
        self.hostFeed = hostFeed
        self.processor = processor
        transmitter = VBANTransmitter(openNow: !onDemand)
        activity = ActivityLog(appName: "Network Audio Sender", file: logFile)
        streamName = defaults.string(forKey: "streamName")
            ?? defaultName.flatMap { VBAN.wireName($0).isEmpty ? nil : VBAN.wireName($0) }
            ?? (hostFeed != nil ? "DAW Track" : "Mac Audio")
        dataType = VBAN.DataType(rawValue: UInt8(defaults.integer(forKey: "dataType"))) ?? .int16
        muteThisMac = defaults.bool(forKey: "muteThisMac")
        stereoOnly = defaults.bool(forKey: "stereoOnly")
        resumeSending = defaults.bool(forKey: "resumeSending")
        autoStopSends = defaults.bool(forKey: "autoStopSends")
        passThrough = defaults.object(forKey: "passThrough") as? Bool ?? true
        autoStopSendsMinutes = defaults.object(forKey: "autoStopSendsMinutes") as? Int ?? 15
        reportedNames = defaults.dictionary(forKey: "reportedNames") as? [String: String] ?? [:]
        askFirst = defaults.object(forKey: "askBeforeListening") as? Bool ?? true
        // "offerInterface" held one name for the first build of this.
        offerInterfaces = Set(defaults.stringArray(forKey: "offerInterfaces")
                              ?? defaults.string(forKey: "offerInterface").map { [$0] } ?? [])
        allowedGrabbers = defaults.dictionary(forKey: "allowedGrabbers") as? [String: String] ?? [:]
        allowedGrabberIDs = defaults.dictionary(forKey: "allowedGrabberIDs") as? [String: String] ?? [:]
        // Links from before the link was encrypted (no secret) can't be used: said once, dropped.
        let savedLinks = defaults.stringArray(forKey: "remoteLinks") ?? []
        let savedSecrets = defaults.dictionary(forKey: "remoteLinkSecrets") as? [String: String] ?? [:]
        let usable = savedLinks.filter { savedSecrets[$0] != nil }
        if usable.count != savedLinks.count { defaults.set(usable, forKey: "remoteLinks") }
        remoteLinks = usable
        remoteLinkSecrets = savedSecrets
        droppedOldLinks = savedLinks.count - usable.count
        remoteLinksPaused = defaults.bool(forKey: "remoteLinksPaused")
        remoteMethod = defaults.integer(forKey: "remoteMethod")
        if defaults.object(forKey: "lastRate") != nil {
            lastFormat = (defaults.integer(forKey: "lastRate"), max(1, defaults.integer(forKey: "lastChannels")))
        }
        // "favouriteTargets" is where 0.1 kept only the starred ones.
        if let data = defaults.data(forKey: "targets") ?? defaults.data(forKey: "favouriteTargets"),
           let saved = try? JSONDecoder().decode([SendTarget].self, from: data) {
            targets = saved
        } else {
            targets = []
        }

        offerTag = VBANOffer.stored(in: defaults)
        // The app's own (one per process there); a plugin's Senders each keep their own.
        if hostFeed == nil { VBANOffer.processInstance = offerTag }
        if let hostFeed {
            self.capture = nil
            // Track → inserts (none in a DAW) → meters → network, on the feed's send thread.
            hostFeed.onAudio = { [transmitter, processor, meter] samples, frames, channels, rate in
                let sent = processor?.process(samples, frames: frames, channels: channels,
                                              sampleRate: rate) ?? samples
                meter.measure(sent, frames: frames, channels: channels)
                transmitter.push(sent, frames: frames, channels: channels, sampleRate: rate)
            }
        } else if let capture {
            self.capture = capture
            capture.muteLocal = muteThisMac
            capture.stereoOnly = stereoOnly
            // Capture → inserts → meters → network, all on the capture queue.
            capture.onAudio = { [transmitter, processor, meter] samples, frames, channels, rate in
                let sent = processor?.process(samples, frames: frames, channels: channels,
                                              sampleRate: rate) ?? samples
                meter.measure(sent, frames: frames, channels: channels)
                transmitter.push(sent, frames: frames, channels: channels, sampleRate: rate)
            }
            capture.onStateChange = { [weak self] in self?.refreshCaptureStatus() }
            capture.onRestart = { [weak self] text in self?.note(.note, text) }
        } else {
            self.capture = nil
        }
        reconfigure()
    }


    public func persist(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }

    private func saveTargets() {
        guard !previewOnly, let data = try? JSONEncoder().encode(targets) else { return }
        defaults.set(data, forKey: "targets")
    }

    // MARK: - Lifecycle

    public func start() {
        guard !started else { return }
        started = true
        if droppedOldLinks > 0 {
            note(.note, "\(droppedOldLinks) Remote link\(droppedOldLinks == 1 ? " was" : "s were") made before links were "
                 + "encrypted and can't be used now: swap new codes with the other end.")
        }
        offer.onChange = { [weak self] list, asking in self?.listenersChanged(list, requests: asking) }
        offer.onLog = { [weak self] kind, text in
            self?.note(kind, text)
            self?.onOfferLog?(text)
        }
        if !onDemand {
            platformStart()
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            note(.note, "Opened Network Audio Sender" + (version.isEmpty ? "." : " \(version)."))
            offer.start()
            if !remoteLinks.isEmpty { applyKnocks() }
            startTimer()
        }
        resumeKeptBroadcasts()
        if resumeSending {
            let last = Set((defaults.stringArray(forKey: "lastSending") ?? []).compactMap(UUID.init))
            // A broadcast made for one network never resumes on another.
            let resumable = last.intersection(targets.filter { $0.networkSignature == nil || onItsNetwork($0) }.map(\.id))
            if !resumable.isEmpty { sending.formUnion(resumable) }
            if defaults.bool(forKey: "lastOffering") { offering = true }
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    // MARK: - On demand (the Grabber's Send)

    /// Inside the Grabber: nothing runs until something is sent or offered — no
    /// tick, no offer thread, no capture — and it all stops again when nothing is.
    public var onDemand = false
    @ObservationIgnored private var started = false

    /// Starts the tick and the offer, if on demand and there is now something to do.
    private func wakeIfNeeded() {
        guard onDemand, started, timer == nil, isActive || offering || remoteWanted else { return }
        offer.start()
        if !remoteLinks.isEmpty { applyKnocks() }
        startTimer()
    }

    /// Stops them again once nothing is sent, offered or listened to.
    private func sleepIfIdle() {
        guard onDemand, timer != nil, !isActive, !offering, !remoteWanted else { return }
        timer?.invalidate()
        timer = nil
        offer.stop()
        bitrateKbps = 0
        setBusy(false)
    }

    /// Where the notes go instead of this state's own log: the Grabber's.
    @ObservationIgnored public var logSink: ((ActivityLog.Kind, String) -> Void)?

    /// Every receiver hears silence, and stays connected; per-target mutes are kept underneath.
    public var allMuted = false {
        didSet {
            guard oldValue != allMuted else { return }
            reconfigure()
            note(.note, allMuted ? "Muted every send (receivers stay connected)." : "Sends unmuted.")
        }
    }

    /// Quitting stops the capture but keeps the record of what was sending, for "Resume".
    public func shutdown() {
        let out = sending.count + listeners.count
        note(out == 0 ? .note : .stopped, out == 0 ? "Quit." : "Quit: stopped sending to \(out) destination\(out == 1 ? "" : "s").")
        activity.save()
        platformShutdown()          // the Mac: a plugin's own settings change in its editor, unseen here
        previewOnly = true          // so clearing `sending` below is not saved as the choice
        sending = []
        offering = false
        capture?.stop()
        hostFeed?.setActive(false)
    }

    // MARK: - Targets

    /// Adds what is in the entry fields. Sets `draftError` and returns false if it is not a
    /// usable address.
    @discardableResult
    public func addDraft() -> Bool {
        let host = draftHost.trimmingCharacters(in: .whitespaces)
        guard let value = ipv4Value(host), value != 0 else {
            draftError = host.isEmpty ? "Type the receiver's IP address."
                                      : "\(host) is not an IPv4 address, such as 192.0.2.20."
            return false
        }
        guard let port = Int(draftPort.trimmingCharacters(in: .whitespaces)),
              (1...65535).contains(port) else {
            draftError = "The port is a number from 1 to 65535; VBAN's is \(VBAN.port)."
            return false
        }
        if let existing = targets.first(where: { $0.host == host && $0.port == port }) {
            draftError = "\(existing.label) is already in the list."
            return false
        }
        let target = SendTarget(host: host, port: port)
        targets.append(target)
        // Adding a target is asking to send to it: it starts at once, one click fewer.
        note(.request, "Added \(target.address) and started sending to it (VBAN).")
        sending.insert(target.id)
        draftHost = ""
        draftPort = String(VBAN.port)
        draftError = nil
        return true
    }

    public func isSending(_ id: UUID) -> Bool { sending.contains(id) }

    public func toggleSending(_ id: UUID) {
        let label = targets.first { $0.id == id }.map { t in t.name.map { "\($0) at \(t.address)" } ?? t.address } ?? "a target"
        if sending.contains(id) {
            sending.remove(id)
            note(.stopped, "Stopped sending to \(label) — you stopped it.")
        } else {
            autoStoppedTargets[id] = nil
            sending.insert(id)
            note(.request, "Sending to \(label) (VBAN).")
        }
    }

    /// "Stop all": nothing leaves this Mac — no targets, and no offer.
    public func stopAll() {
        let n = sending.count, l = listeners.count
        sending = []
        offering = false
        // Remote links pause too, and say so: nothing goes out until Resume.
        if !remoteLinks.isEmpty {
            remoteLinksPaused = true
            persist("remoteLinksPaused", true)
            applyKnocks()
            for key in remoteLinks { if let ip = key.split(separator: ":").first { offer.drop(ip: String(ip)) } }
        }
        note(.stopped, "Stop all: stopped \(n) target\(n == 1 ? "" : "s")" + (l > 0 ? " and \(l) listening" : "")
             + (remoteLinks.isEmpty ? "." : "; Remote links paused until resumed."))
        sleepIfIdle()
    }

    public func toggleFavourite(_ id: UUID) { update(id) { $0.favourite.toggle() } }
    public func toggleMuted(_ id: UUID) { update(id) { $0.muted.toggle() } }
    public func toggleBroadcast(_ id: UUID) { update(id) { $0.broadcast.toggle() } }
    /// Blank clears the name, so the address shows again.
    public func rename(_ id: UUID, to name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        update(id) { $0.name = trimmed.isEmpty ? nil : trimmed }
    }

    public func remove(_ id: UUID) {
        if let t = targets.first(where: { $0.id == id }) { note(.stopped, "Removed \(t.label) (\(t.address)).") }
        sending.remove(id)
        targets.removeAll { $0.id == id }
    }

    private func update(_ id: UUID, _ change: (inout SendTarget) -> Void) {
        guard let i = targets.firstIndex(where: { $0.id == id }) else { return }
        change(&targets[i])
    }

    /// Where a target's packets actually go: its host, or with broadcast on, the broadcast
    /// address of the local network it is on. Nil when broadcast is asked for but the host is
    /// not on a network this Mac is on — a broadcast cannot cross a router.
    // MARK: Broadcast on this network
    //
    // One choice instead of typing an address and switching BCAST on: a broadcast target on the
    // chosen network, named for it. "Keep broadcasting when opened again" resumes it at launch
    // **only on the same network** (`NetworkIdentity`), and a broadcast whose network the Mac has
    // left stops — so a broadcast meant for one place never starts on another.

    /// Networks a broadcast can go to: those with a broadcast address.
    public var broadcastNetworks: [LocalNetwork] { networks.filter { $0.broadcast != nil } }

    public func startBroadcast(on network: LocalNetwork, keepOn: Bool) {
        let signature = networkSignature(interface: network.name, broadcast: network.broadcast)
        if let existing = targets.firstIndex(where: { $0.broadcast && $0.interface == network.name && $0.networkSignature == signature }) {
            targets[existing].keepOn = keepOn
            sending.insert(targets[existing].id)
            note(.request, "Broadcasting again to everyone on \(network.name).")
            return
        }
        var target = SendTarget(host: network.address, port: VBAN.port, broadcast: true, name: "Everyone on \(network.name)")
        target.interface = network.name
        target.networkSignature = signature
        target.keepOn = keepOn
        targets.append(target)
        sending.insert(target.id)
        note(.request, "Broadcasting to everyone on \(network.name)" + (keepOn ? ", and again when opened on this network." : "."))
    }

    /// Whether this Sender is broadcasting to that network now.
    public func isBroadcasting(on network: LocalNetwork) -> Bool {
        if let names = previewBroadcasting { return names.contains(network.name) }
        return targets.contains { t in
            t.broadcast && sending.contains(t.id)
                && (t.interface == network.name || (network.broadcast != nil && destination(of: t) == network.broadcast))
        }
    }

    /// Whether a kept broadcast's network is the one this Mac is on now.
    private func onItsNetwork(_ t: SendTarget) -> Bool {
        guard let interface = t.interface, let signature = t.networkSignature,
              let network = LocalNetworks.list().first(where: { $0.name == interface }) else { return false }
        return networkSignature(interface: interface, broadcast: network.broadcast) == signature
    }

    /// Which kept broadcasts may come back on, given each interface's network now (nil: not on
    /// it). Pure, for the checks.
    public static func keptBroadcastsToResume(_ targets: [SendTarget], signatureNow: (String) -> String?) -> Set<UUID> {
        Set(targets.filter { t in
            guard t.keepOn == true, let interface = t.interface, let signature = t.networkSignature else { return false }
            return signatureNow(interface) == signature
        }.map(\.id))
    }

    /// At launch: kept broadcasts come back on, each only on its own network.
    private func resumeKeptBroadcasts() {
        let ok = Self.keptBroadcastsToResume(targets) { interface in
            LocalNetworks.list().first { $0.name == interface }.map {
                self.networkSignature(interface: interface, broadcast: $0.broadcast)
            }
        }
        for t in targets where t.keepOn == true && !sending.contains(t.id) {
            if ok.contains(t.id) {
                sending.insert(t.id)
                note(.request, "Broadcasting again to \(t.label) — kept on, and \(thisMachine) is on that network.")
            } else {
                note(.note, "Not broadcasting to \(t.label): \(thisMachine) is not on the network it was started on.")
            }
        }
    }

    @ObservationIgnored private var lastBroadcastCheck = Date.distantPast
    /// While running, every few seconds: a broadcast whose network the Mac has left stops.
    private func checkBroadcastNetworks() {
        guard Date().timeIntervalSince(lastBroadcastCheck) > 5 else { return }
        lastBroadcastCheck = Date()
        for t in targets where t.networkSignature != nil && sending.contains(t.id) && !onItsNetwork(t) {
            sending.remove(t.id)
            note(.stopped, "Stopped broadcasting to \(t.label): \(thisMachine) has left that network.")
        }
    }

    /// Unreachable targets for the row, and auto-stop's check (the tick, twice a second).
    private func checkReachability() {
        let failing = transmitter.unreachable()
        var down: Set<UUID> = []
        let now = CFAbsoluteTimeGetCurrent()
        var stop: [SendTarget] = []
        for t in targets where sending.contains(t.id) {
            guard let address = destination(of: t), let since = failing["\(address):\(t.port)"] else { continue }
            down.insert(t.id)
            if autoStopSends, now - since >= TimeInterval(autoStopSendsMinutes * 60) { stop.append(t) }
        }
        if down != unreachableTargets { unreachableTargets = down }
        for t in stop {
            sending.remove(t.id)
            autoStoppedTargets[t.id] = (Date(), autoStopSendsMinutes)
            note(.stopped, "Stopped sending to \(t.label): unreachable for \(Self.minutesText(autoStopSendsMinutes)), "
                         + "so auto-stop stopped it (\(settingsPath)).")
        }
    }

    public func destination(of target: SendTarget) -> String? {
        target.broadcast ? LocalNetworks.broadcast(for: target.host) : target.host
    }

    /// Whether broadcast is possible for this target at all.
    public func canBroadcast(_ target: SendTarget) -> Bool {
        LocalNetworks.broadcast(for: target.host) != nil
    }

    // MARK: - Wiring

    private func reconfigure() {
        var live = targets.filter { sending.contains($0.id) }.compactMap { t -> VBANTransmitter.Destination? in
            guard let address = destination(of: t) else { return nil }
            return .init(address: address, port: t.port, muted: t.muted || allMuted)
        }
        // Listening Grabbers, once each: one that is also a target on gets the stream once, not
        // twice (two copies of every packet would read as a stream of duplicates).
        for l in listeners where !live.contains(where: { $0.address == l.ip && $0.port == l.port }) {
            live.append(.init(address: l.ip, port: l.port, muted: allMuted,
                              sealer: offer.sealer(for: "\(l.ip):\(l.port)")))
        }
        let name = VBAN.wireName(streamName).isEmpty ? "Mac Audio" : VBAN.wireName(streamName)
        transmitter.configure(name: name, dataType: dataType, destinations: live)
        guard !previewOnly else { return }
        // A network this Sender broadcasts to already hears the stream: an offer there too would
        // list it twice in every Grabber, under one name.
        let broadcasting = Set(targets.filter { $0.broadcast && sending.contains($0.id) }.compactMap(destination(of:)))
        let allowed = Set(allowedGrabbers.keys).union(allowedGrabberIDs.values.map(VBANOffer.identityKey))
        offer.configure(offering: offering, askFirst: askFirst, allowed: allowed,
                        name: name, format: beaconFormat, interfaces: offerInterfaces,
                        skipping: broadcasting)
    }

    /// What the beacon says the stream is: what is being captured, or what was last time.
    private var beaconFormat: VBANControl.Format {
        var rate = lastFormat.rate, channels = stereoOnly ? 2 : lastFormat.channels
        if case .running(let r, let c) = captureStatus { rate = r; channels = c }
        if !VBAN.sampleRates.contains(rate) { rate = 48000 }
        return .init(sampleRate: rate, channels: channels, dataType: dataType)
    }

    private func listenersChanged(_ list: [VBANOffer.Subscriber], requests asking: [VBANOffer.Subscriber]) {
        // Listeners count with the offer on, or through a Remote link, which does not need it.
        guard offering || !remoteLinks.isEmpty || (list.isEmpty && asking.isEmpty) else { return }
        let newRequest = asking.contains { r in !requests.contains { $0.id == r.id } }
        requests = asking
        // Bring it to the user's attention if the Sender is behind something else.
        if newRequest, !previewOnly { requestAttention() }
        listeners = list
        sleepIfIdle()
        var names = reportedNames
        for l in list { if let n = l.name { names[l.ip] = n } }
        if names != reportedNames {
            reportedNames = names
            if !previewOnly { persist("reportedNames", names) }
        }
        reconfigure()
        updateCapture()
    }

    /// This Mac's addresses, for the connection guide. The render harness puts documentation
    /// addresses here, since the images go in the docs.
    /// A render never reads the real ones: it could put this Mac's address in a screenshot, which
    /// the project must never contain (a quiet shot once did, when the window showed it).
    public var localAddresses: [String] {
        previewAddresses ?? (previewOnly ? ["192.0.2.30"] : LocalNetworks.list().map(\.address))
    }
    public var previewAddresses: [String]?

    /// The port Grabbers ask on: 6981, unless another Sender on this Mac had it.
    public var offerPort: Int { transmitter.boundPort }

    /// Allow a Grabber that asked, and remember its address.
    public func allow(_ request: VBANOffer.Subscriber) {
        guard let ip = offer.allow(request.id) else { return }
        note(.done, "Allowed \(request.name ?? "a Grabber") at \(ip) — by you. It is remembered.")
        remember(request)
    }

    private func remember(_ grabber: VBANOffer.Subscriber) {
        let ip = grabber.ip
        allowedGrabbers[ip] = grabber.name ?? allowedGrabbers[ip] ?? ""
        if let id = grabber.instance { allowedGrabberIDs[ip] = id }
        if !previewOnly {
            persist("allowedGrabbers", allowedGrabbers)
            persist("allowedGrabberIDs", allowedGrabberIDs)
        }
    }

    /// Refuse it, until the Sender is next opened or it is allowed in Settings.
    public func decline(_ request: VBANOffer.Subscriber) {
        offer.decline(request.id)
        deniedGrabbers.removeAll { $0.ip == request.ip }
        deniedGrabbers.append(request)
        note(.failed, "Denied \(request.name ?? "a Grabber") at \(request.ip) — by you, until the Sender is reopened "
           + "or you allow it in Settings → Grabbers.")
    }

    /// Allow a Grabber denied earlier: it is let in the next time it asks, within 20 seconds.
    public func allowDenied(_ grabber: VBANOffer.Subscriber) {
        deniedGrabbers.removeAll { $0.ip == grabber.ip }
        offer.undecline(ip: grabber.ip, instance: grabber.instance)
        remember(grabber)
        reconfigure()
        note(.done, "Allowed \(grabber.name ?? "a Grabber") at \(grabber.ip) — by you, after denying it. It is "
           + "let in the next time it asks, within 20 seconds.")
    }

    /// No longer allowed: it stops listening now and has to ask next time.
    public func revoke(_ ip: String) {
        note(.stopped, "No longer allowed: \(allowedGrabbers[ip].flatMap { $0.isEmpty ? nil : $0 } ?? "the Grabber") at \(ip). It has to ask next time.")
        allowedGrabbers[ip] = nil
        let id = allowedGrabberIDs.removeValue(forKey: ip)
        // The same Grabber allowed at its Mac's other addresses goes too: it is one Grabber.
        for (other, otherID) in allowedGrabberIDs where otherID == id {
            allowedGrabberIDs[other] = nil
            allowedGrabbers[other] = nil
        }
        if !previewOnly {
            persist("allowedGrabbers", allowedGrabbers)
            persist("allowedGrabberIDs", allowedGrabberIDs)
        }
        offer.drop(ip: ip, instance: id)
        reconfigure()
    }

    // MARK: Remote link
    //
    // The sending end: its code comes from the socket audio leaves from; the receiving end's code,
    // pasted here, is allowed (no asking — the codes were swapped on purpose) and knocked on, so
    // this router lets its request in. Needs the offer on: a Remote link is an offer to one
    // Grabber in another place. The links are kept, and knocked on again at launch.

    public private(set) var remoteCode: RemoteCode?
    public private(set) var remoteCodeError: String?
    public private(set) var makingRemoteCode = false
    /// "address:port" of each receiving end linked.
    public private(set) var remoteLinks: [String] = []
    public private(set) var remoteCodeMadeAt: Date?
    /// Each link as the guide lists it: the Grabber's name once it listens.
    public var remoteLinkInfo: [RemoteLinkInfo] {
        remoteLinks.map { key in
            let listener = listeners.first { "\($0.ip):\($0.port)" == key }
            return RemoteLinkInfo(key: key, name: listener?.name, connected: listener != nil)
        }
    }
    /// How, when somewhere else (`RemoteMethod`), in the connection guide.
    public var remoteMethod: Int = 0 { didSet { persist("remoteMethod", remoteMethod) } }
    @ObservationIgnored private var mappingTimer: Timer?

    /// RENDER HARNESS only: a made-up code, as if made.
    public func setPreviewRemoteCode(_ code: RemoteCode) { remoteCode = code; remoteCodeMadeAt = Date().addingTimeInterval(-4 * 60) }
    public func setPreviewRemoteLinks(_ links: [String]) { remoteLinks = links }
    public func setPreviewLinksPaused(_ on: Bool) { remoteLinksPaused = on }

    /// Stop sending paused the links: nobody is let in or knocked on until Resume.
    public private(set) var remoteLinksPaused = false

    /// The offer runs for the links, a code being made, or one still fresh — not only for
    /// Findable (a link no longer turns Findable on, which announced it locally).
    public var remoteWanted: Bool {
        (!remoteLinks.isEmpty && !remoteLinksPaused) || makingRemoteCode
            || (remoteCodeMadeAt.map { Date().timeIntervalSince($0) < 15 * 60 } ?? false)
    }

    public func makeRemoteCode() {
        remoteCodeError = nil
        makingRemoteCode = true
        wakeIfNeeded()                                  // starts the offer (and its socket)
        offer.makeRemoteCode { [weak self] code in
            guard let self else { return }
            self.makingRemoteCode = false
            guard let code else {
                self.remoteCodeError = "No answer from the address server: this network may block it, or \(self.thisMachine) is offline."
                return
            }
            self.remoteCode = RemoteCode(role: code.role, address: code.address, port: code.port, secret: self.remoteSecret)
            self.remoteCodeMadeAt = Date()
            self.note(.done, "Made this end's Remote link code (sending).")
            self.remoteCodeError = RemoteLinkInfo.linkedBehindSameRouter(self.remoteLinks, own: code)
            // Keep the router's mapping for it alive for 15 minutes while it is passed on.
            self.mappingTimer?.invalidate()
            let until = Date().addingTimeInterval(15 * 60)
            self.mappingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                guard Date() < until else { t.invalidate(); self.sleepIfIdle(); return }
                self.offer.refreshRemoteMapping()
            }
        }
    }

    /// Links the receiving end whose code was pasted. Nil, or what was wrong.
    public func linkRemote(_ text: String) -> String? {
        guard let code = RemoteCode(text: text) else { return RemoteCode.problem(with: text) }
        guard code.role == .receiving else {
            return "That code is from a sending end. Paste the code from the Grabber that is to receive."
        }
        if code.address == remoteCode?.address { return RemoteLinkInfo.sameRouter }
        let key = "\(code.address):\(code.port)"
        guard !remoteLinks.contains(key) else { return "That end is already linked." }
        remoteLinkSecrets[key] = RemoteSeal.hex(code.secret)
        persist("remoteLinkSecrets", remoteLinkSecrets)
        remoteLinks.append(key)
        persist("remoteLinks", remoteLinks)
        remoteLinksPaused = false
        persist("remoteLinksPaused", false)
        wakeIfNeeded()
        // Let in exactly that end (address and port), and open this router to it.
        applyKnocks()
        note(.request, "Remote link: letting in the Grabber at \(key), and opening this router to it.")
        return nil
    }

    /// Ends the link: no longer let in or knocked on, and dropped if listening.
    public func unlinkRemote(_ key: String) {
        remoteLinks.removeAll { $0 == key }
        persist("remoteLinks", remoteLinks)
        remoteLinkSecrets[key] = nil
        persist("remoteLinkSecrets", remoteLinkSecrets)
        linkCryptos[key] = nil
        applyKnocks()
        if let ip = key.split(separator: ":").first.map(String.init),
           !remoteLinks.contains(where: { $0.hasPrefix(ip + ":") }), allowedGrabbers[ip] == nil {
            offer.drop(ip: ip)
            reconfigure()
        }
        note(.stopped, "Remote link to \(key) ended — by you.")
        sleepIfIdle()
    }

    /// Lets the linked ends in again after Stop sending.
    public func resumeRemoteLinks() {
        remoteLinksPaused = false
        persist("remoteLinksPaused", false)
        wakeIfNeeded()
        applyKnocks()
        note(.request, "Remote links resumed — by you.")
    }

    private func applyKnocks() {
        guard !remoteLinksPaused else { offer.setKnocks([]); return }
        offer.setKnocks(remoteLinks.compactMap { key in
            let parts = key.split(separator: ":")
            guard parts.count == 2, let port = Int(parts[1]), let crypto = linkCrypto(for: key) else { return nil }
            return (String(parts[0]), port, crypto)
        })
    }

    // MARK: Remote link encryption (`RemoteSeal`)

    /// This end's secret, in every code it makes: made once and kept, so a new code doesn't
    /// break a link already made. "Remove all settings" forgets it.
    public var remoteSecret: [UInt8] {
        if let text = defaults.string(forKey: "remoteSecret"), let secret = RemoteSeal.secret(fromHex: text) { return secret }
        let made = RemoteSeal.newSecret()
        defaults.set(RemoteSeal.hex(made), forKey: "remoteSecret")
        return made
    }
    /// Each linked end's secret, from its code, by "address:port".
    @ObservationIgnored private var remoteLinkSecrets: [String: String] = [:]
    /// Each link's sealer and opener for this run, made once (so the other end sees one epoch).
    @ObservationIgnored private var linkCryptos: [String: LinkCrypto] = [:]
    /// Links dropped at launch for having no secret (made before encryption), for one note.
    @ObservationIgnored private var droppedOldLinks = 0

    private func linkCrypto(for key: String) -> LinkCrypto? {
        if let made = linkCryptos[key] { return made }
        guard let peer = remoteLinkSecrets[key].flatMap(RemoteSeal.secret(fromHex:)) else { return nil }
        let made = LinkCrypto(own: remoteSecret, peer: peer, sendingEnd: true)
        linkCryptos[key] = made
        return made
    }

    /// The name the Grabber at this address last reported, if any.
    public func reportedName(for host: String) -> String? { reportedNames[host] }

    /// Capture runs while anything is being sent, and not otherwise: an idle Sender records
    /// nothing, and the system's recording indicator says so.
    private func updateCapture() {
        if let hostFeed, !previewOnly {
            hostFeed.setActive(isActive)
            applyPassThrough()
            let status: CaptureStatus = isActive ? .running(rate: hostFeed.sampleRate, channels: hostFeed.channelCount) : .idle
            if status != captureStatus {
                if case .running(let rate, let channels) = status {
                    note(.done, "Sending the track: \(rate / 1000) kHz, \(channels) ch.")
                    lastFormat = (rate, channels)
                    captureStatus = status
                    reconfigure()
                } else {
                    captureStatus = status
                }
            }
            return
        }
        guard !previewOnly, toneTimer == nil, let capture else { return }
        if !isActive {
            if capture.running { capture.stop() }
        } else if !capture.running {
            capture.muteLocal = muteThisMac
            capture.stereoOnly = stereoOnly
            capture.start()
        }
    }

    private func restartCaptureIfRunning() {
        guard let capture else { return }
        capture.muteLocal = muteThisMac
        capture.stereoOnly = stereoOnly
        if capture.running { capture.start() }
    }

    private func refreshCaptureStatus() {
        guard let capture else { return }
        let status: CaptureStatus
        if let error = capture.lastError { status = .failed(error) }
        else if capture.running { status = .running(rate: capture.sampleRate, channels: capture.channels) }
        else { status = .idle }
        if captureStatus != status {
            switch status {
            case .running(let rate, let channels): note(.done, "Capturing \(thisMachine)'s audio: \(rate / 1000) kHz, \(channels) ch.")
            case .failed(let message): note(.failed, "Capture failed: \(message)")
            case .idle: if case .running = captureStatus { note(.note, "Capture stopped: nothing is being sent.") }
            }
            captureStatus = status
            if case .running(let rate, let channels) = status, !previewOnly {
                lastFormat = (rate, channels)
                persist("lastRate", rate)
                persist("lastChannels", channels)
                reconfigure()               // so the beacon says what is actually being sent
            }
        }
    }

    // MARK: - Meters and status

    /// Channels being captured, for the meters: the device's own count, or two when idle.
    public var captureChannels: Int {
        if let preview = previewLevels { return preview.count }
        if case .running(_, let channels) = captureStatus { return max(1, channels) }
        return 2
    }

    /// Fixed meter levels for the render harness, which captures nothing.
    public var previewLevels: [Float]?
    /// The render harness: nothing is captured, sent or saved.
    public private(set) var previewOnly = false

    /// Shows the offer on with these listeners, and names they reported — for the render harness.
    public func setPreviewListeners(_ list: [VBANOffer.Subscriber], reported: [String: String],
                             requests asking: [VBANOffer.Subscriber] = []) {
        previewOnly = true
        offering = true
        listeners = list
        requests = asking
        reportedNames = reported
    }

    /// Allowed Grabbers for the render harness, without touching the saved list.
    /// RENDER HARNESS only: the networks to show as broadcast to, without sending anything.
    public var previewBroadcasting: Set<String>?
    public func setPreviewDenied(_ list: [VBANOffer.Subscriber]) { deniedGrabbers = list }
    public func allowPreview(_ list: [String: String]) { previewOnly = true; allowedGrabbers = list }

    /// Shows targets as sending without capturing or sending anything — for the render harness.
    public func setPreviewSending(_ ids: Set<UUID>) {
        previewOnly = true
        sending = ids
    }

    public func level(_ channel: Int) -> Float {
        if let preview = previewLevels { return channel < preview.count ? preview[channel] : 0 }
        return isActive ? meter.level(channel) : 0
    }

    public var unsupportedRate: Int? { transmitter.unsupportedRate }
    public var packetsSent: UInt64 { transmitter.packetsSent }

    /// For the self-test: feed the transmitter a stereo sine (440 Hz left, 660 right, −12 dBFS)
    /// instead of the capture, so the packetising and the network path can be checked against
    /// a receiver without capturing anything — and without the recording permission.
    @ObservationIgnored private var toneTimer: DispatchSourceTimer?
    public func startTestTone(rate: Int = 48000, channels: Int = 2) {
        let chunk = rate / 100
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: chunk * channels)
        var n = 0
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "test tone", qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        timer.setEventHandler { [transmitter, unowned self] in
            for f in 0..<chunk {
                let t = Double(n + f) / Double(rate)
                for c in 0..<channels {
                    buffer[f * channels + c] = Float(0.25 * sin(2 * .pi * Double(440 + 110 * c) * t))
                }
            }
            n += chunk
            // Through the inserts like captured audio, so the self-test exercises them too.
            let sent = self.processor?.process(buffer, frames: chunk, channels: channels,
                                               sampleRate: rate) ?? UnsafePointer(buffer)
            self.meter.measure(sent, frames: chunk, channels: channels)
            transmitter.push(sent, frames: chunk, channels: channels, sampleRate: rate)
        }
        timer.resume()
        toneTimer = timer
    }
    public var captureDebug: String {
        guard let c = capture else { return "" }
        return "callbacks \(c.callbacks), buffers \(c.lastBufferCount) × \(c.lastBufferBytes) B"
    }
    public var sendErrors: UInt64 { transmitter.sendErrors }

    @ObservationIgnored private var othersPlaying: (at: Date, value: Bool)?

    private func tick() {
        platformTick()
        checkReachability()
        if !previewOnly { checkBroadcastNetworks() }
        let device = previewOutput ?? outputDevice() ?? ("No output device", 0)
        if device.name != outputDeviceName { outputDeviceName = device.name }
        if device.rate != outputRate { outputRate = device.rate }
        let now = Date()
        let bytes = transmitter.bytesSent
        let elapsed = now.timeIntervalSince(lastSample)
        if elapsed > 0 {
            let kbps = isActive ? Double(bytes &- lastBytes) * 8 / 1000 / elapsed : 0
            // Published only when it moves visibly, so the window is not re-rendered twice a
            // second for a figure that did not change.
            if abs(kbps - bitrateKbps) > 20 || (kbps == 0) != (bitrateKbps == 0) { bitrateKbps = kbps }
        }
        lastBytes = bytes
        lastSample = now

        setBusy(isActive)
        var blocked = false
        if let capture, capture.running, toneTimer == nil {
            if captureStartedAt == nil { captureStartedAt = now }
            // No callbacks is also what a quiet Mac gives: macOS runs the tap only while
            // something plays. So it only reads as a missing permission while another app is
            // actually playing (The warning once sat there on a silent Mac with the
            // permission granted, and cleared when something played).
            blocked = capture.callbacks == 0
                && now.timeIntervalSince(captureStartedAt ?? now) > 3
                && othersArePlaying(capture, now: now)
        } else {
            captureStartedAt = nil
        }
        if blocked != captureBlocked {
            captureBlocked = blocked
            if blocked { note(.warning, "macOS is delivering no audio. Allow System Audio Recording for Network Audio Sender in System Settings → Privacy & Security.") }
        }

        let signal = level(0) > 0.0005 || level(1) > 0.0005
        if !isActive || signal {
            quietSince = nil
        } else if quietSince == nil {
            quietSince = now
        }
        // Only while another app is actually playing: a quiet Mac is not a permission problem,
        // and saying it might be sent people to System Settings for nothing.
        var quiet = !blocked && (quietSince.map { now.timeIntervalSince($0) > 6 } ?? false)
        if quiet, let capture, toneTimer == nil { quiet = othersArePlaying(capture, now: now) }
        if quiet != quietForAWhile { quietForAWhile = quiet }
    }

    /// Whether another app is playing, asked of macOS at most every 2.5 s: the question walks
    /// every running process, and the tick asked it twice a second. Both warnings it
    /// gates already wait seconds before showing, so the lag is invisible.
    private func othersArePlaying(_ capture: SystemAudioSource, now: Date) -> Bool {
        if let cached = othersPlaying, now.timeIntervalSince(cached.at) < 2.5 { return cached.value }
        let value = capture.othersArePlaying()
        othersPlaying = (now, value)
        return value
    }


    // MARK: - What each platform adds (overridden by the Mac's `SenderState`)

    /// At launch of a standalone Sender: the Mac scans its Audio Units here.
    open func platformStart() {}
    /// At quit: the Mac saves its inserts' settings.
    open func platformShutdown() {}
    /// Twice a second while running.
    open func platformTick() {}
    /// The output device being captured, and its rate, for the header.
    open func outputDevice() -> (name: String, rate: Int)? { nil }
    /// A Grabber asks to listen while the app is behind something else.
    open func requestAttention() {}
    /// What the log calls this machine: "this Mac", "this PC".
    open var thisMachine: String { "this Mac" }
    /// Keep the system from napping the app while it sends.
    open func setBusy(_ busy: Bool) {}
    /// Which network an interface is on, so a kept broadcast resumes only there. The default
    /// tells networks apart only by interface and broadcast address.
    open func networkSignature(interface: String, broadcast: String?) -> String {
        "local:\(interface):\(broadcast ?? "")"
    }
}
