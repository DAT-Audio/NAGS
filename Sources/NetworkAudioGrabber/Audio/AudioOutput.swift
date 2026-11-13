import Foundation
import AVFoundation
import CoreAudio
import os
import NetworkAudioAtomics

/// Mixes every active receiver into the monitor bus, runs it through the insert slots, and
/// plays
/// it out of the Mac's current default output device. Follows default-device changes.
///
/// Signal path:
///
///     receivers → [source node: sum, loudness tap, dim, mono]
///               → insert 1 (dry/wet) → insert 2 (dry/wet) → [safety limiter]
///               → main mixer → default output device
///
/// Each insert is wired as a parallel pair rather than in line, so its dry/wet balance is our
/// own mixer rather than the plugin's honour system:
///
///     upstream ─┬─ plugin ─ wetGain ─┬─ sum ─→
///               └────────── dryGain ─┘
final class AudioOutput {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var limiterNode: AVAudioUnitEffect?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var meteringInstalled = false
    /// How the output is metered: a render notification on the output unit (`.notify`), or the
    /// mixer tap as a fallback if that unit's format is not one the notification can read.
    private enum Metering { case notify(AudioUnit), tap }
    private var metering: Metering?

    /// The three inserts and the wiring around each — shared with the Sender, so an insert
    /// behaves the same in both apps. `slots` stays for the callers that walk them.
    let inserts = InsertChain()
    var slots: [PluginSlot] { inserts.slots }
    var slotRefusedWidth: Set<Int> { inserts.refused }
    var deltaSlot: Int? { inserts.deltaSlot }

    /// BS.1770 loudness, measured on the summed bus before the monitor controls.
    let loudness = LoudnessMeter()

    private var receivers: [StreamReceiver] = []
    private let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()

    private(set) var deviceName = "—"
    private(set) var deviceRate: Double = 48000

    /// Output channels the current device presents. What a wider bus would have to fit inside.
    private(set) var deviceChannels = 2

    /// How wide the monitor bus is. Every stage of the graph is built from the one format
    /// derived from it, which is what makes widening it tractable.
    private(set) var busChannels = 2

    /// What the user asked for. The bus is this clamped to what the device can carry, so a
    /// remembered 7.1 on a rig that has become a pair of headphones comes back as stereo
    /// without losing the choice for when that rig returns.
    var requestedBusChannels = 2

    private(set) var deviceUID = ""
    private(set) var running = false

    /// Frames CoreAudio asks for per callback. Not known until the engine is running, and it is
    /// the floor under the whole playout budget — see `StreamReceiver.render`.
    private(set) var renderBlockFrames = 0

    /// The output device's own buffer size, which is what sets `renderBlockFrames`. Readable and
    /// settable; nothing in the app changed it until now.
    var deviceBufferFrames: UInt32 { CoreAudioDevice.bufferFrameSize(of: CoreAudioDevice.defaultOutputID) }

    @discardableResult
    func setDeviceBufferFrames(_ frames: UInt32) -> Bool {
        CoreAudioDevice.setBufferFrameSize(frames, on: CoreAudioDevice.defaultOutputID)
    }

    // Monitor controls
    var masterGain: Float = 1.0
    var dimmed = false
    var monoFold = false
    var safetyLimiter = false { didSet { if oldValue != safetyLimiter { rebuildChain() } } }

    /// −20 dB, the conventional dim amount on a monitor controller.
    static let dimGain: Float = 0.1

    // MARK: - Metering
    //
    // The tap writes an envelope and a timestamp; the accessors decay it to *now* on every
    // read. That is what makes the bars fluid: the tap only arrives every few milliseconds, so
    // a stored number stair-steps between callbacks however fast the view redraws, whereas a
    // value computed from elapsed time is continuous and can be sampled at any rate.

    /// A one-pole envelope evaluated continuously from its last update, so it can be sampled at
    /// any frame rate and always has somewhere to be part-way between updates.
    ///
    /// This is what the bars need that a decay-only envelope could not give them. The metering
    /// tap fires at 10 Hz, so a decay-only envelope spends 100 ms falling and is then
    /// yanked back up by the next callback — a 6.7 dB sag ten times a second at the old 0.13 s
    /// fall, which is exactly what read as choppy. A follower with a short attack instead *rises*
    /// into each new measurement over about 25 ms and settles, so the motion is continuous.
    private struct Follower {
        var from: Float = 0
        var target: Float = 0
        var at: CFAbsoluteTime = 0
        var tau: Double = 0.3

        /// Attack when the new measurement is louder than where the envelope currently is,
        /// release when it is quieter.
        mutating func update(to measured: Float, now: CFAbsoluteTime,
                             attack: Double, release: Double) {
            let current = value(at: now)
            from = current
            target = measured
            tau = measured > current ? attack : release
            at = now
        }

        func value(at now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Float {
            guard at > 0 else { return 0 }
            let elapsed = now - at
            guard elapsed > 0 else { return from }
            guard elapsed < tau * 8 else { return target }
            return target + (from - target) * Float(exp(-elapsed / tau))
        }
    }

    /// One envelope per bus channel, in storage made once: the metering runs on the audio
    /// thread, where a Swift array's copy-on-write could allocate. `barCount` of them are in use.
    private static let maxMeterChannels = 64
    private let bars: UnsafeMutablePointer<Follower> = {
        let p = UnsafeMutablePointer<Follower>.allocate(capacity: AudioOutput.maxMeterChannels)
        p.initialize(repeating: Follower(), count: AudioOutput.maxMeterChannels)
        return p
    }()
    private var barCount = 2
    private var holdValue: Float = 0
    private var holdSetAt: CFAbsoluteTime = 0
    /// Guards the bars and the hold, which the audio thread writes together and the meters read
    /// on the main thread: an envelope is three values that only mean something as a set.
    private let meterLock = SeqLock()
    /// The clip latch and the maximum, each a value on its own (`SharedFloats`): [0] clip, [1] max.
    private let latches = SharedFloats(count: 2)
    var clipped: Bool { latches[0] > 0 }

    /// Highest level seen since the last reset. Monotonic, so the figure the UI shows changes
    /// only when a new peak beats the old one — which is what lets it be published rather than
    /// redrawn.
    var peakMax: Float { latches[1] }

    // Cadence of the metering tap, for diagnostics. `installTap`'s buffer size is advisory and
    // the engine frequently delivers something far larger than asked for. That sets a hard
    // ceiling on how fast the bars can *rise*, whatever rate the view redraws at, so it is worth
    // being able to see it rather than guess.
    private(set) var tapFrames = 0
    private(set) var tapHz: Double = 0
    private var tapCallbacks = 0
    private var tapWindowStart: CFAbsoluteTime = 0

    // Three different ballistics, because the three displays answer different questions. All
    // three attack instantly; what differs is how fast they let go.

    /// The bars. A 25 ms attack is short enough that a sustained level is reached well inside
    /// one tap interval, so nothing is under-reported for long; it exists only to turn each
    /// 10 Hz measurement into a rise rather than a jump. Release is slower than it was, because
    /// there is no point falling faster than new data arrives.
    ///
    /// The true peak is not lost to the smoothing: the hold marker and the dBFS figure both keep
    /// instant attack, which is the conventional division of labour on a meter — a smoothed bar
    /// to watch, a peak marker to read.
    private static let barAttackTau = 0.025
    // 0.30 read as smoothed against the compact window's long horizontal bars — the envelope
    // is shared, but a 500-point bar shows the same fall over five times the distance a
    // 104-point one does, so the short bars looked sluggish and the long ones lively. Shortened
    // to 0.22, which keeps the fall readable rather than twitchy; the other half of the fix is
    // that the panel's bars are no longer 104 points.
    private static let barReleaseTau = 0.22

    /// The dBFS figure. A number that moves as fast as a bar is unreadable, and what is wanted
    /// off a readout is the recent loudest rather than the instantaneous. ~17 dB/s.
    private static let readoutFallTau = 0.50

    /// Peak hold: sits still this long after a new maximum, then falls at about 7 dB/s.
    private static let holdSeconds = 1.5
    private static let holdFallTau = 1.20

    /// Envelope for one bus channel. Out-of-range asks return silence rather than trapping:
    /// a view can outlive a narrowing of the bus by a frame or two.
    func peak(_ channel: Int) -> Float {
        guard channel >= 0, channel < barCount else { return 0 }
        let bar = meterLock.read { bars[channel] }
        return bar.value()
    }

    var peakL: Float { peak(0) }
    var peakR: Float { peak(barCount > 1 ? 1 : 0) }

    /// The topmost mark on the master meters. Rises instantly, holds, then slides down. It used
    /// to snap back to the current level after two seconds, which read as the marker
    /// teleporting rather than falling.
    var peakHold: Float { meterLock.read { heldPeak() } }

    private func heldPeak(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Float {
        guard holdValue > 0, holdSetAt > 0 else { return 0 }
        // `decayed` returns the value unchanged while the elapsed time is negative, so shifting
        // the stamp forward by the plateau gives hold-then-fall in one expression.
        return Self.decayed(holdValue, from: holdSetAt + Self.holdSeconds,
                            tau: Self.holdFallTau, now: now)
    }

    private static func decayed(_ value: Float, from stamp: CFAbsoluteTime, tau: Double,
                                now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Float {
        guard value > 0, stamp > 0 else { return 0 }
        let elapsed = now - stamp
        guard elapsed > 0 else { return value }
        // Past eight time constants there is under −69 dB left, which is nothing to draw, and
        // stopping here saves an `exp` on every read while the app sits idle.
        guard elapsed < tau * 8 else { return 0 }
        return value * Float(exp(-elapsed / tau))
    }

    var onStatusChange: (() -> Void)?
    var onError: ((String) -> Void)?
    /// Asked to reload a slot after its plugin's first failure; reloads directly when unset.
    var onAutoReload: ((Int) -> Void)?

    // MARK: - Host mode (the Audio Unit)

    /// Inside a DAW, as the Audio Unit: no device and no engine — the host calls
    /// `renderForHost` instead of the device pulling from the source node, so the same mixing,
    /// fold-down, trims, mutes, solos, loudness and meters run in both. Set before the first
    /// `AudioOutput` is made; process-wide, since a plugin's process is its host's.
    nonisolated(unsafe) public static var hostMode = false
    /// The host's rate and channel count, set by the Audio Unit when it is initialised.
    private var hostRate: Double = 48000
    private var hostChannels = 2

    /// The Audio Unit's format changed (or it was initialised): the rate and width to mix at.
    func configureForHost(rate: Double, channels: Int) {
        os_unfair_lock_lock(lock)
        hostRate = max(8000, rate)
        hostChannels = max(1, min(channels, Self.maxMeterChannels))
        deviceName = "DAW"
        deviceRate = hostRate
        deviceChannels = hostChannels
        busChannels = max(1, min(requestedBusChannels, hostChannels))
        if barCount != busChannels {
            for i in 0..<Self.maxMeterChannels { bars[i] = Follower() }
            barCount = min(busChannels, Self.maxMeterChannels)
        }
        for receiver in receivers { receiver.busChannels = busChannels }
        os_unfair_lock_unlock(lock)
        loudness.configure(rate: hostRate, channels: busChannels)
        running = true
        onStatusChange?()
    }

    /// One buffer for the host: the mix, then the meters, as the device path does. The audio
    /// thread; allocates nothing.
    func renderForHost(_ abl: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        // The first render says the plugin is in use (`PluginBridge.startEngine`).
        if nag_load32(&hostRendered) == 0 { nag_store32(&hostRendered, 1) }
        var silent = ObjCBool(false)
        _ = render(isSilence: &silent, frames: frames, abl: abl)
        meter(UnsafeMutableAudioBufferListPointer(abl), frames: frames)
    }

    /// 1 once the host has rendered this output. Written by the render thread.
    var hostRendered: UInt32 = 0

    init() {
        guard !Self.hostMode else { return }
        // The system default changing matters only while playing on it: a chosen device stays
        // put whatever the Mac's own setting does.
        deviceListener = CoreAudioDevice.observeDefaultOutputChanges { [weak self] in
            guard let self, self.preferredDeviceUID == nil || self.usingFallback else { return }
            self.scheduleRestart()
        }
        // A chosen device unplugged (play on the default meanwhile) or plugged back in (go back).
        deviceListListener = CoreAudioDevice.observeDeviceListChanges { [weak self] in
            guard let self, let uid = self.preferredDeviceUID else { return }
            let present = CoreAudioDevice.outputDevice(withUID: uid) != nil
            if present == self.usingFallback { self.scheduleRestart() }
        }
        // **`AVAudioEngine` stops itself when the hardware under it changes** — a device switch,
        // a sample-rate change, a device going away — and says so only through this
        // notification. Without it, a switch back from 44.1 kHz speakers to a 48 kHz interface
        // rebuilt the engine for the interface and then the change itself stopped it again: the
        // app believed it was running and played nothing until relaunched. Only acted on
        // when the engine really has stopped, so this app's own rebuilds cannot start a loop.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, !self.engine.isRunning else { return }
            self.scheduleRestart()
        }
        for slot in slots {
            let index = slot.index
            slot.onFailure = { [weak self] dead in self?.pluginFailed(slot: index, dead: dead) }
        }
    }

    private var configObserver: NSObjectProtocol?
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var restartPending = false

    /// **The chosen output device**, by UID; nil plays on the
    /// system default and follows it, as before. Set by the app from its settings.
    var preferredDeviceUID: String?
    /// True while the chosen device is not connected and the system default stands in for it.
    private(set) var usingFallback = false

    /// The device to play on now: the chosen one if connected, else the system default.
    private func targetDevice() -> (id: AudioDeviceID, fallback: Bool) {
        if let uid = preferredDeviceUID {
            if let chosen = CoreAudioDevice.outputDevice(withUID: uid) { return (chosen, false) }
            return (CoreAudioDevice.defaultOutputID, true)
        }
        return (CoreAudioDevice.defaultOutputID, false)
    }

    /// Chooses the device (nil: the system default) and rebuilds onto it if playing.
    func setPreferredDevice(uid: String?) {
        guard uid != preferredDeviceUID else { return }
        preferredDeviceUID = uid
        if running { scheduleRestart() }
    }
    /// Restarts made by `scheduleRestart`, for the self-test: a number that keeps climbing
    /// with nothing changing would be a restart loop.
    private(set) var restarts = 0

    /// Rebuilds the engine after the output device or its configuration changes.
    ///
    /// Both signals can arrive for one change, in either order, and the hardware is not settled
    /// the instant either fires — so restarts are coalesced, made a moment later, and then
    /// *checked*: running, and on the device the system says is the default. If not, it tries
    /// again a few times before saying so in the log rather than going quietly silent.
    private func scheduleRestart(attempt: Int = 0) {
        guard running, !Self.hostMode else { return }
        if attempt == 0 {
            guard !restartPending else { return }
            restartPending = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * Double(attempt + 1)) { [weak self] in
            guard let self else { return }
            guard self.running else { self.restartPending = false; return }
            self.restarts += 1
            let error = self.start()
            let healthy = error == nil && self.engine.isRunning
                && self.engineDeviceID == self.targetDevice().id
            if healthy || attempt >= 3 {
                self.restartPending = false
                if !healthy {
                    self.onError?(error ?? "The output device changed and audio could not be "
                        + "restarted on \(self.deviceName). Pick the device again, or relaunch.")
                }
            } else {
                self.scheduleRestart(attempt: attempt + 1)
            }
        }
    }

    // MARK: - Lifecycle

    /// (Re)builds the engine against the chosen output device, or the system default.
    /// Returns an error message on failure.
    @discardableResult
    func start() -> String? {
        if Self.hostMode {
            configureForHost(rate: hostRate, channels: hostChannels)
            return nil
        }
        let keep = withLockedReceivers { $0 }
        teardown()

        let (device, fallback) = targetDevice()
        usingFallback = fallback
        guard device != 0 else { return "No default output device." }
        deviceName = CoreAudioDevice.name(of: device)
        deviceRate = max(8000, CoreAudioDevice.sampleRate(of: device))
        deviceChannels = max(2, CoreAudioDevice.outputChannelCount(of: device))

        do {
            try engine.outputNode.auAudioUnit.setDeviceID(device)
        } catch {
            // Non-fatal: the engine still opens on the system default.
        }

        deviceUID = CoreAudioDevice.uid(of: device)
        busChannels = max(2, min(requestedBusChannels, deviceChannels))
        // The engine is stopped here (`teardown`), so nothing on the audio thread is reading.
        if barCount != busChannels {
            for i in 0..<Self.maxMeterChannels { bars[i] = Follower() }
            barCount = min(busChannels, Self.maxMeterChannels)
        }
        guard let format = Self.busFormat(rate: deviceRate, channels: busChannels) else {
            return "Could not create a \(Int(deviceRate)) Hz \(busChannels)-channel output format."
        }

        // K-weighting coefficients are rate-dependent, so the loudness meter has to be told
        // whenever the device changes underneath us. It clears itself when it is reconfigured.
        loudness.configure(rate: deviceRate, channels: busChannels)

        let node = AVAudioSourceNode(format: format) { [weak self] isSilence, _, frameCount, abl in
            guard let self else {
                isSilence.pointee = true
                return noErr
            }
            return self.render(isSilence: isSilence, frames: Int(frameCount), abl: abl)
        }
        sourceNode = node
        engine.attach(node)

        if let error = connectChain(format: format) { return error }

        for receiver in keep { receiver.busChannels = busChannels }
        setReceivers(keep)
        running = true
        onStatusChange?()
        return nil
    }

    /// Rates the current device offers, for the picker in Settings.
    var deviceSampleRates: [Double] {
        CoreAudioDevice.availableSampleRates(of: CoreAudioDevice.defaultOutputID)
    }

    /// Asks the device to run at `rate`. **This is the device's own setting, not the app's** —
    /// every other application on this Mac sees the change too, which is why it has to be as
    /// reversible here as it was avoidable.
    @discardableResult
    func setDeviceSampleRate(_ rate: Double) -> Bool {
        CoreAudioDevice.setSampleRate(rate, on: CoreAudioDevice.defaultOutputID)
    }

    /// The format every stage of the graph is built from. Shared with the Sender — see
    /// `BusFormat.make` for why it is built the way it is.
    static func busFormat(rate: Double, channels: Int) -> AVAudioFormat? {
        BusFormat.make(rate: rate, channels: channels)
    }

    func stop() {
        teardown()
        running = false
    }

    private func teardown() {
        removeMetering()
        if engine.isRunning { engine.stop() }
        inserts.detachPlugins(from: engine)
        inserts.detachGains(from: engine)
        if let l = limiterNode, engine.attachedNodes.contains(l) { engine.detach(l) }
        limiterNode = nil
        if let node = sourceNode, engine.attachedNodes.contains(node) { engine.detach(node) }
    }

    /// Wires source → inserts → limiter → main mixer and starts the engine.
    private func connectChain(format: AVAudioFormat) -> String? {
        guard let source = sourceNode else { return "No source node." }

        var upstream: AVAudioNode = source

        inserts.sampleRate = deviceRate
        upstream = inserts.connect(in: engine, after: upstream, format: format,
                                   channels: busChannels)

        if safetyLimiter {
            let limiter = AVAudioUnitEffect(audioComponentDescription: PluginCatalog.appleLimiter)
            engine.attach(limiter)
            limiterNode = limiter
            engine.connect(upstream, to: limiter, format: format)
            upstream = limiter
        }

        engine.connect(upstream, to: engine.mainMixerNode, format: format)
        // **The tail has to be connected by hand.** `AVAudioEngine` wires its main mixer to the
        // output node itself, at stereo, the first time the mixer is touched — so an 8-channel
        // bus arrived at a 2-channel mixer output and a discrete-layout fold to stereo is
        // silence, not a downmix. Connecting the last hop explicitly makes the mixer and the
        // output node as wide as the bus, and the output unit maps those onto the device's
        // first N outputs.
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0

        installMetering()
        engine.prepare()
        do {
            try engine.start()
        } catch {
            return "Could not start audio engine: \(error.localizedDescription)"
        }
        return nil
    }

    /// Rebuilds the insert chain after a plugin is loaded or removed. Bypass and dry/wet do
    /// **not** come through here — they are gain changes on a graph that already exists, so
    /// they take effect without stopping the engine.
    func rebuildChain() {
        guard running, !Self.hostMode else { return }
        let keep = withLockedReceivers { $0 }
        removeMetering()
        engine.stop()
        // Disconnecting the source cascades: every downstream insert is rewired below.
        if let source = sourceNode { engine.disconnectNodeOutput(source) }
        inserts.disconnect(in: engine)
        inserts.detachGains(from: engine)
        if let l = limiterNode {
            engine.disconnectNodeOutput(l)
            if engine.attachedNodes.contains(l) { engine.detach(l) }
            limiterNode = nil
        }
        // The bus width, not two: this was hard-coded stereo from before the bus could be
        // widened, so loading a plugin — or toggling the safety limiter, which also rebuilds —
        // quietly collapsed a 16-channel graph back to a stereo one while everything else went
        // on believing it was wide.
        guard let format = Self.busFormat(rate: deviceRate, channels: busChannels) else { return }
        if let error = connectChain(format: format) { onError?(error) }
        setReceivers(keep)
        // **A rebuild is a status change.** The delta units are created in here, so whether a
        // slot can offer Δ is only true once this has run — and `slotLive` is derived, not
        // observed. Without this, plugins restored at launch came back with Δ greyed out and
        // stayed that way until some unrelated action happened to refresh the status; loading
        // a plugin by hand did it, which is why the third insert appeared to fix the first two.
        onStatusChange?()
    }

    /// A plugin whose process has gone: take its dead node out of the engine and rebuild
    /// without it, so the monitor path carries on, then say which slot it was.
    private func pluginFailed(slot index: Int, dead: AVAudioUnit) {
        if running {
            let keep = withLockedReceivers { $0 }
            removeMetering()
            engine.stop()
            if engine.attachedNodes.contains(dead) {
                engine.disconnectNodeOutput(dead)
                engine.detach(dead)
            }
            setReceivers(keep)
        } else if engine.attachedNodes.contains(dead) {
            engine.detach(dead)
        }
        rebuildChain()
        let slot = slots[index]
        let name = slot.info?.name ?? "plugin"
        if slot.retriesAutomatically {
            onError?("Insert \(index + 1) (\(name)) stopped responding; the audio carries on without it "
                   + "while it is reloaded with its last settings.")
            retryAfterFailure(slot: index)
        } else {
            onError?("Insert \(index + 1) (\(name)) stopped responding again within a minute and was "
                   + "taken out of the chain; the audio carries on without it. Reload it from the insert.")
        }
        onStatusChange?()
    }

    /// The one automatic reload after a failure (`PluginSlot.retriesAutomatically`), once the
    /// hosting process has had time to go — unless the slot has been changed or reloaded since.
    private func retryAfterFailure(slot index: Int) {
        let id = slots[index].info?.id
        DispatchQueue.main.asyncAfter(deadline: .now() + PluginSlot.retryDelay) { [weak self] in
            guard let self, self.slots[index].failure != nil, self.slots[index].info?.id == id else { return }
            if let reload = self.onAutoReload { reload(index) } else { self.reloadPlugin(slot: index) }
        }
    }

    func insertLevel(slot: Int, output: Bool) -> Float { inserts.level(slot: slot, output: output) }

    /// The inserts' health check, from the app's tick.
    func probeInserts() { inserts.probe() }

    /// Loads the slot's plugin again after a failure, with its last settings.
    func reloadPlugin(slot index: Int) {
        guard slots.indices.contains(index) else { return }
        slots[index].reload { [weak self] error in
            if let error { self?.onError?(error) }
            self?.rebuildChain()
            self?.onStatusChange?()
        }
    }

    /// Loads a plugin into an insert slot and rewires the chain around it.
    func setPlugin(slot index: Int, to info: PluginInfo?) {
        guard slots.indices.contains(index) else { return }
        slots[index].load(info) { [weak self] error in
            if let error { self?.onError?(error) }
            self?.rebuildChain()
            // Instantiation is asynchronous, so until this fires the slot has a name but no
            // node: `setDelta` would find nothing to engage, and the Δ button would do nothing
            // without saying why.
            self?.onStatusChange?()
        }
    }

    /// Whether a slot's plugin is instantiated and wired, as opposed to merely chosen.
    func isSlotLive(_ index: Int) -> Bool { inserts.isLive(index) }

    /// Whether a slot's plugin was refused for being too narrow for the bus.
    func isSlotRefused(_ index: Int) -> Bool { inserts.isRefused(index) }

    // MARK: - Insert bypass, dry/wet and delta — `InsertChain`'s, see there

    func setBypass(slot index: Int, _ bypassed: Bool) { inserts.setBypass(slot: index, bypassed) }

    func setMix(slot index: Int, _ mix: Double) { inserts.setMix(slot: index, mix) }

    /// Returns the compensation applied, in frames — see `InsertChain.setDelta`.
    @discardableResult
    func setDelta(slot index: Int, _ on: Bool) -> Int? {
        inserts.sampleRate = deviceRate
        return inserts.setDelta(slot: index, on)
    }

    // MARK: - Receiver set

    func setReceivers(_ list: [StreamReceiver]) {
        for receiver in list { receiver.busChannels = busChannels }
        os_unfair_lock_lock(lock)
        receivers = list
        os_unfair_lock_unlock(lock)
    }

    /// Changes the width of the monitor bus.
    ///
    /// Unlike bypass, dry/wet and delta, this **does** rebuild: the format is threaded through
    /// every connection in the graph, so the engine stops and starts. Returns the width
    /// actually in use, which is the request clamped to what the device offers.
    @discardableResult
    func setBusChannels(_ channels: Int) -> Int {
        requestedBusChannels = max(2, channels)
        guard running else { return min(requestedBusChannels, max(2, deviceChannels)) }
        guard max(2, min(requestedBusChannels, deviceChannels)) != busChannels else {
            return busChannels
        }
        if let error = start() { onError?(error) }
        onStatusChange?()
        return busChannels
    }

    private func withLockedReceivers<T>(_ body: ([StreamReceiver]) -> T) -> T {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return body(receivers)
    }

    // MARK: - Metering

    /// Output metering, **after everything** — master level, DIM and MONO (applied in `render`),
    /// the inserts and the limiter — so the bars show what reaches the device.
    ///
    /// **A render notification on the output unit, not a tap.** The mixer
    /// tap was delivered in 100 ms blocks (4410 or 4800 frames) whatever size was asked for, so
    /// the output bars trailed the input meters by up to a tenth of a second. The output unit's
    /// post-render notification sees every buffer it hands the device — one per device buffer,
    /// ~11 ms — and only observes: it adds no node and changes no connection, so the insert
    /// chain's routing is exactly as it was. It runs on the audio thread, so `meter` allocates
    /// nothing and takes no lock.
    private func installMetering() {
        if let unit = engine.outputNode.audioUnit, Self.readsFloat32(unit),
           AudioUnitAddRenderNotify(unit, Self.meterNotify,
                                    Unmanaged.passUnretained(self).toOpaque()) == noErr {
            metering = .notify(unit)
        } else {
            // The old way, which is always available: coarser, but never wrong.
            let mixer = engine.mainMixerNode
            let format = mixer.outputFormat(forBus: 0)
            guard format.channelCount >= 1 else { return }
            mixer.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
                guard let self, let data = buffer.floatChannelData else { return }
                let frames = Int(buffer.frameLength)
                let now = CFAbsoluteTimeGetCurrent()
                var instant: Float = 0
                let counted = min(Int(buffer.format.channelCount), self.barCount)
                self.meterLock.write {
                    for c in 0..<counted {
                        var peak: Float = 0
                        for i in 0..<frames { peak = max(peak, abs(data[c][i])) }
                        self.bars[c].update(to: peak, now: now, attack: Self.barAttackTau, release: Self.barReleaseTau)
                        instant = max(instant, peak)
                    }
                    self.finishMeasurement(channels: counted, instant: instant, frames: frames, now: now)
                }
            }
            metering = .tap
        }
        meteringInstalled = metering != nil
    }

    private func removeMetering() {
        switch metering {
        case .notify(let unit):
            AudioUnitRemoveRenderNotify(unit, Self.meterNotify, Unmanaged.passUnretained(self).toOpaque())
        case .tap:
            engine.mainMixerNode.removeTap(onBus: 0)
        case nil:
            break
        }
        metering = nil
        meteringInstalled = false
    }

    /// Whether the output unit's input — what the engine hands it — is 32-bit float, which is
    /// what `meter` reads. It always has been; this is the check that keeps it honest.
    private static func readsFloat32(_ unit: AudioUnit) -> Bool {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                   &format, &size) == noErr else { return false }
        return format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
    }

    private static let meterNotify: AURenderCallback = { refCon, flags, _, _, frames, ioData in
        guard flags.pointee.contains(.unitRenderAction_PostRender),
              !flags.pointee.contains(.unitRenderAction_PostRenderError),
              let ioData else { return noErr }
        Unmanaged<AudioOutput>.fromOpaque(refCon).takeUnretainedValue()
            .meter(UnsafeMutableAudioBufferListPointer(ioData), frames: Int(frames))
        return noErr
    }

    /// Peaks of one output buffer, into the bars, the hold, the maximum and the clip latch.
    /// Audio thread: no allocation, no lock. Reads interleaved or not, whichever arrives.
    private func meter(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        let now = CFAbsoluteTimeGetCurrent()
        var instant: Float = 0
        var c = 0
        meterLock.write {
        for b in 0..<buffers.count {
            let buffer = buffers[b]
            let width = Int(buffer.mNumberChannels)
            guard width > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let available = min(frames, Int(buffer.mDataByteSize) / (4 * width))
            for k in 0..<width where c < barCount {
                var peak: Float = 0
                var i = k
                while i < available * width {
                    peak = max(peak, abs(data[i]))
                    i += width
                }
                bars[c].update(to: peak, now: now, attack: Self.barAttackTau, release: Self.barReleaseTau)
                instant = max(instant, peak)
                c += 1
            }
        }
        finishMeasurement(channels: c, instant: instant, frames: frames, now: now)
        }
    }

    /// What both ways of metering share once the bars are updated.
    private func finishMeasurement(channels counted: Int, instant: Float, frames: Int, now: CFAbsoluteTime) {
        // A mono device gets the one channel mirrored, so the pair of bars still reads.
        if counted == 1, barCount > 1 {
            bars[1].update(to: instant, now: now, attack: Self.barAttackTau,
                           release: Self.barReleaseTau)
        }

        tapFrames = frames
        tapCallbacks += 1
        if tapWindowStart == 0 { tapWindowStart = now }
        let span = now - tapWindowStart
        if span >= 1 {
            tapHz = Double(tapCallbacks) / span
            tapCallbacks = 0
            tapWindowStart = now
        }

        // The hold only ever rises; a new maximum restarts its plateau.
        if instant > heldPeak(now: now) {
            holdValue = instant
            holdSetAt = now
        }
        if instant > latches[1] { latches[1] = instant }
        if instant >= 0.999 { latches[0] = 1 }
    }

    /// Clears the clip latch and the maximum together: they answer the same question, and one
    /// gesture for both is less to explain than two buttons that look alike.
    func clearClip() {
        latches[0] = 0
        latches[1] = 0
    }

    /// Drops the maximum without touching the clip latch.
    ///
    /// For DIM. The peak figure is measured after the monitor gain — deliberately, so the meter
    /// shows what reaches the headphones — which means a maximum captured at one monitor level
    /// says nothing about the next. Dimming used to leave the old, louder figure standing until
    /// the programme happened to beat it, and undimming left the quiet one standing for the
    /// same reason; both read as a stuck readout. A clip is not cleared, because clipping
    /// happened whatever the monitor was set to afterwards.
    func clearPeakMax() { latches[1] = 0 }

    // MARK: - Diagnostics

    /// Describes the chain as it is actually wired, for `--selftest`. The parallel dry path
    /// around each insert is invisible from the outside, so this is how it gets verified.
    var graphSummary: String {
        guard running else { return "not running" }
        var parts = ["source"] + inserts.summary(channels: busChannels)
        if limiterNode != nil { parts.append("limiter") }
        // Channel counts at each hop: the place a wide bus goes wrong is the last one, where
        // the graph's width has to become the device's.
        let mixerIn = Int(engine.mainMixerNode.inputFormat(forBus: 0).channelCount)
        let mixerOut = Int(engine.mainMixerNode.outputFormat(forBus: 0).channelCount)
        let deviceIn = Int(engine.outputNode.inputFormat(forBus: 0).channelCount)
        parts.append("mixer(\(engine.isRunning ? "running" : "stopped") "
                   + "\(mixerIn)→\(mixerOut) ch)")
        parts.append("device(\(deviceIn) ch)")
        return parts.joined(separator: " → ")
    }

    // MARK: - Render

    /// The device the engine is actually rendering to, as the output unit reports it — which is
    /// not necessarily the system default the app *asked* for. The two disagreeing is the
    /// failure this check is for.
    var engineDeviceID: AudioDeviceID { engine.outputNode.auAudioUnit.deviceID }
    var engineIsRunning: Bool { engine.isRunning }

    /// Render callbacks so far. A diagnostic: a counter that stops climbing means the engine has
    /// stopped pulling audio, whatever `running` says. One writer, the audio thread.
    private(set) var renderCalls: UInt64 = 0

    private func render(isSilence: UnsafeMutablePointer<ObjCBool>,
                        frames: Int,
                        abl: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        renderCalls &+= 1
        renderBlockFrames = frames
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        // Trust the buffer list over `busChannels`: the format can change between a connection
        // being made and this callback running, and writing past what arrived would be fatal
        // rather than merely wrong.
        let busCount = min(buffers.count, busChannels)
        guard busCount >= 1 else {
            isSilence.pointee = true
            return noErr
        }

        // Stack scratch for the bus pointers — the audio thread must not allocate.
        return withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<Float>.self,
                                             capacity: busCount) { buses -> OSStatus in
            for b in 0..<busCount {
                guard let channel = buffers[b].mData?.assumingMemoryBound(to: Float.self) else {
                    isSilence.pointee = true
                    return noErr
                }
                channel.update(repeating: 0, count: frames)
                buses[b] = channel
            }
            guard let base = buses.baseAddress else {
                isSilence.pointee = true
                return noErr
            }

            // Never block the audio thread: if the receiver list is mid-update, emit this one
            // buffer of silence and pick the change up on the next callback.
            guard os_unfair_lock_trylock(lock) else {
                isSilence.pointee = true
                return noErr
            }
            for receiver in receivers {
                receiver.render(into: base, busCount: busCount, frames: frames,
                                outputRate: deviceRate)
            }
            let active = !receivers.isEmpty
            os_unfair_lock_unlock(lock)

            // Loudness is taken here, on the summed bus, *before* master level, DIM and MONO —
            // and before the inserts, which are graph nodes downstream of this callback. A
            // monitor level control must not move a loudness reading, and room correction is
            // not part of the programme.
            //
            // Skipped entirely when nothing is playing: silence is gated out of the measurement
            // anyway, so there is nothing to gain from filtering it, and idle CPU stays at zero.
            //
            // BS.1770 channel weighting comes from the bus width the meter was configured
            // with: surrounds +1.5 dB, LFE excluded, everything else at unity.
            if active {
                loudness.process(buses: base, channels: busCount, frames: frames)
            }

            let gain = masterGain * (dimmed ? Self.dimGain : 1.0)
            // LFE sits out of the fold: it is a band-limited effects channel, not programme, so
            // summing it in would count bass already present in the bed a second time. It keeps
            // its own signal and takes the gain like everything else.
            let lfe = SMPTELayout.forChannelCount(busCount)?.lfeIndex
            if monoFold, busCount > 1 {
                let folded = lfe == nil ? busCount : busCount - 1
                let scale = folded > 0 ? 1 / Float(folded) : 0
                for i in 0..<frames {
                    var sum: Float = 0
                    for b in 0..<busCount where b != lfe { sum += buses[b][i] }
                    let mono = sum * scale * gain
                    for b in 0..<busCount where b != lfe { buses[b][i] = mono }
                    if let lfe { buses[lfe][i] *= gain }
                }
            } else if gain != 1.0 {
                for b in 0..<busCount {
                    let channel = buses[b]
                    for i in 0..<frames { channel[i] *= gain }
                }
            }

            isSilence.pointee = ObjCBool(!active)
            return noErr
        }
    }
}
