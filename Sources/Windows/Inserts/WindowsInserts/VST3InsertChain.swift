import Foundation
import WinSDK
import NetworkAudioEngine
import NAGVST3

/// One insert slot. The UI-side facts are plain properties (main thread); what the audio thread
/// reads is either under the chain's lock (`rtPlugin`, `rtLatency`, `delay`) or atomic (the gains,
/// the levels).
public final class VST3InsertSlot: @unchecked Sendable {
    public let index: Int
    public fileprivate(set) var info: VST3PluginInfo?
    public fileprivate(set) var plugin: VST3Plugin?
    /// Hard bypass: wet silenced, dry at unity, no delay — whatever the plug-in does with its own
    /// bypass parameter, which it is told about too.
    public fileprivate(set) var bypassed = false
    /// 0 = all dry, 1 = all wet. Our gains, not the plug-in's.
    public fileprivate(set) var mix: Double = 1
    /// Would not take the bus width, so held out of circuit entirely.
    public fileprivate(set) var refused = false
    /// Why it stopped by itself (it faulted, or would not start), for the failed-insert row.
    public fileprivate(set) var failure: String?
    /// The plug-in's reported latency, in samples at the chain's rate.
    public fileprivate(set) var latencyFrames = 0
    /// For the engine's channel `e`, the plug-in's channel (`VST3Plugin.Configuration`).
    public fileprivate(set) var channelMap: [Int] = []
    /// The settings as last seen alive, for Reload after a fault.
    fileprivate var lastGoodState: Data?

    // Read by the audio thread, written only under the chain's lock.
    fileprivate var rtPlugin: OpaquePointer?
    fileprivate var rtLatency = 0
    fileprivate var delay: DelayLine?

    /// [0] wet gain, [1] dry gain, [2] bypassed (1) — together under `gainLock`, since a wet gain
    /// read with the wrong dry gain is a click.
    fileprivate let gains = SharedFloats(count: 3)
    fileprivate let gainLock = SeqLock()
    /// What the audio thread last applied, for ramping to new gains across one block.
    fileprivate var appliedWet: Float = 1
    fileprivate var appliedDry: Float = 0
    /// [0] input peak, [1] output peak since the meter last took them.
    fileprivate let peaks = SharedFloats(count: 2)
    fileprivate var shown: (input: Float, output: Float) = (0, 0)

    init(index: Int) {
        self.index = index
        gains[0] = 1
    }

    public var isLoaded: Bool { plugin != nil }
    public var displayName: String { info?.name ?? "Empty" }
}

/// Whole-sample delay for one slot's dry leg, all channels, made on the main thread at the size
/// the plug-in's latency needs: the audio thread only reads and writes it.
final class DelayLine: @unchecked Sendable {
    let channels: Int
    let capacity: Int
    private let mask: Int
    private let buffer: UnsafeMutablePointer<Float>
    private var write = 0

    init(channels: Int, delay: Int, maxFrames: Int) {
        self.channels = max(1, channels)
        var size = 1024
        while size < delay + maxFrames + 1 { size <<= 1 }
        capacity = size
        mask = size - 1
        buffer = .allocate(capacity: self.channels * size)
        buffer.initialize(repeating: 0, count: self.channels * size)
    }
    deinit { buffer.deallocate() }

    /// Feeds `frames` of each plane in; with `output`, replaces each sample with the one from
    /// `delay` samples ago. Delay 0 is a copy.
    func process(_ planes: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels: Int, frames: Int,
                 delay: Int, output: Bool) {
        let n = min(channels, self.channels)
        for c in 0..<n {
            let ring = buffer + c * capacity
            let plane = planes[c]
            if output {
                for i in 0..<frames {
                    let w = (write + i) & mask
                    ring[w] = plane[i]
                    plane[i] = ring[(w - delay) & mask]
                }
            } else {
                for i in 0..<frames { ring[(write + i) & mask] = plane[i] }
            }
        }
        write = (write + frames) & mask
    }
}

/// The three insert slots on the Windows Grabber's monitor bus, as the Mac's `InsertChain` is on
/// its own: the same hard bypass, the same dry/wet, the same latency-aligned dry leg, the same Δ,
/// over VST3 instead of Audio Units, and on planar buffers instead of an `AVAudioEngine` graph.
///
/// Each loaded insert is a parallel pair, so its dry/wet balance is ours rather than the plug-in's:
///
///     bus ─┬─ plugin ──── × wet ─┬─ sum ─→ bus
///          └─ delay(L) ── × dry ─┘
///
/// with L the plug-in's reported latency, at every blend (so moving the knob never moves the
/// timing), Δ as wet × 1 + dry × −1, and bypass as the undelayed dry alone.
///
/// **Threads.** `process` is the audio thread's and does no allocation and never waits: it *tries*
/// the chain's lock and, if the main thread holds it, leaves the bus untouched for that block —
/// the dry signal, never silence. Everything else is the main thread's (VST3's UI thread), which
/// takes the lock only to swap what the audio thread reads: a new plug-in is created and activated
/// before it is swapped in, and an old one released after it is swapped out.
public final class VST3InsertChain: @unchecked Sendable {
    public static let maxChannels = 8
    /// The longest block processed at once; longer ones are done in pieces.
    public static let maxBlockFrames = 4096
    /// The longest latency the dry leg follows, in seconds. Past it the alignment stops.
    public static let maxLatencySeconds = 1.0

    public let slots: [VST3InsertSlot]
    public private(set) var sampleRate: Double = 48000
    public private(set) var channels = 2
    public private(set) var maxFrames = VST3InsertChain.maxBlockFrames
    /// Which slot, if any, is carrying its difference. One at a time, like solo.
    public private(set) var deltaSlot: Int?

    /// Called on the main thread when a slot's editor window closes.
    public var onEditorClosed: ((Int) -> Void)?

    private let lock: UnsafeMutablePointer<SRWLOCK> = {
        let p = UnsafeMutablePointer<SRWLOCK>.allocate(capacity: 1)
        p.initialize(to: SRWLOCK())
        InitializeSRWLock(p)
        return p
    }()
    // The audio thread's copies of the configuration, written under the lock.
    private var rtChannels = 2
    private var rtMaxFrames = VST3InsertChain.maxBlockFrames

    /// The dry copy of one piece, and the pointer arrays for it and for the piece of the bus being
    /// worked on. Made once.
    private let dryPlanes = UnsafeMutablePointer<Float>.allocate(capacity: VST3InsertChain.maxChannels * VST3InsertChain.maxBlockFrames)
    private let dryPointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: VST3InsertChain.maxChannels)
    private let piecePointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: VST3InsertChain.maxChannels)

    public init(count: Int = 3) {
        slots = (0..<count).map { VST3InsertSlot(index: $0) }
        dryPlanes.initialize(repeating: 0, count: Self.maxChannels * Self.maxBlockFrames)
        for c in 0..<Self.maxChannels {
            dryPointers[c] = dryPlanes + c * Self.maxBlockFrames
            piecePointers[c] = dryPlanes     // replaced on every piece
        }
    }

    deinit {
        for slot in slots { slot.plugin?.unload() }
        dryPlanes.deallocate()
        dryPointers.deallocate()
        piecePointers.deallocate()
        lock.deallocate()
    }

    /// Whether any slot has a plug-in in it. With none, the owner may skip `process` altogether.
    public var isEmpty: Bool { !slots.contains { $0.isLoaded } }

    private func locked<T>(_ body: () -> T) -> T {
        AcquireSRWLockExclusive(lock)
        defer { ReleaseSRWLockExclusive(lock) }
        return body()
    }

    // MARK: - Configuration

    /// The bus the chain runs on: call from the main thread whenever the device's rate or the
    /// bus width changes, before `process` is called at the new width. Every loaded plug-in is
    /// renegotiated; one that cannot take the width is held out (refused). Until this is called
    /// at a width, `process` leaves buses of other widths untouched.
    public func configure(sampleRate: Double, channels: Int, maxFrames: Int = VST3InsertChain.maxBlockFrames) {
        let channels = max(1, min(channels, Self.maxChannels))
        let maxFrames = max(1, min(maxFrames, Self.maxBlockFrames))
        locked {
            self.sampleRate = sampleRate
            self.channels = channels
            self.maxFrames = maxFrames
            rtChannels = channels
            rtMaxFrames = maxFrames
            // The plug-ins are reactivated with the lock held: the audio thread passes the bus
            // through untouched meanwhile, which beats processing a half-configured plug-in.
            for slot in slots where slot.plugin != nil && slot.failure == nil {
                apply(slot.plugin!.configure(sampleRate: sampleRate, maxFrames: maxFrames, channels: channels),
                      to: slot)
            }
        }
        if let d = deltaSlot, !isLive(d) { setDelta(slot: d, false) }
        for slot in slots { applyMix(slot.index) }
    }

    /// Takes a plug-in's configuration into its slot. The lock must be held if the audio thread
    /// can already see the slot.
    private func apply(_ configuration: VST3Plugin.Configuration, to slot: VST3InsertSlot) {
        switch configuration {
        case .accepted(let map):
            slot.refused = false
            slot.channelMap = map
            setLatency(slot.plugin?.latencySamples ?? 0, of: slot)
            slot.rtPlugin = slot.plugin?.handle
        case .refused:
            slot.refused = true
            slot.channelMap = []
            slot.rtPlugin = nil
        case .failed:
            slot.refused = false
            slot.rtPlugin = nil
            slot.failure = "Would not start at \(channels) ch, \(Int(sampleRate)) Hz"
        }
    }

    /// The dry leg's delay for `latency`, with a new line only when the old one is too short.
    private func setLatency(_ latency: Int, of slot: VST3InsertSlot) {
        let limit = Int(Self.maxLatencySeconds * sampleRate)
        let frames = max(0, min(latency, limit))
        slot.latencyFrames = max(0, latency)
        if slot.delay == nil || slot.delay!.channels < channels || slot.delay!.capacity < frames + maxFrames + 1 {
            slot.delay = DelayLine(channels: channels, delay: frames, maxFrames: maxFrames)
        }
        slot.rtLatency = frames
    }

    // MARK: - Loading

    /// Puts `info` in slot `index` — nil empties it — with its saved `state` if given, and says
    /// how it went (nil is fine, otherwise why not). Synchronous on the main thread: VST3 loads on
    /// the UI thread, and a plug-in takes a moment. The old plug-in keeps processing until the new
    /// one is ready.
    @discardableResult
    public func load(slot index: Int, info: VST3PluginInfo?, state: Data? = nil,
                     completion: ((String?) -> Void)? = nil) -> String? {
        guard slots.indices.contains(index) else { completion?("No such slot"); return "No such slot" }
        let slot = slots[index]

        var fresh: VST3Plugin?
        var configuration = VST3Plugin.Configuration.failed
        var problem: String?
        if let info {
            switch VST3Plugin.load(info) {
            case .failure(let error):
                problem = "\(info.name) failed to load: \(error.description)"
            case .success(let plugin):
                fresh = plugin
                plugin.setBypass(slot.bypassed)
                if let state, !plugin.setState(state) { problem = "\(info.name): its saved settings were not accepted" }
                configuration = plugin.configure(sampleRate: sampleRate, maxFrames: maxFrames, channels: channels)
            }
        }

        if deltaSlot == index { deltaSlot = nil }
        let old = slot.plugin
        if let old, !old.hasFailed { slot.lastGoodState = old.state }
        old?.closeEditor()
        locked {
            slot.rtPlugin = nil
            slot.plugin = fresh
            slot.info = fresh == nil ? nil : info
            slot.failure = nil
            slot.refused = false
            slot.latencyFrames = 0
            slot.channelMap = []
            if info?.id != old?.info.id { slot.lastGoodState = nil }
            if fresh != nil { apply(configuration, to: slot) } else { slot.delay = nil }
        }
        old?.unload()         // out of the audio thread's reach now
        applyMix(index)
        completion?(problem)
        return problem
    }

    public func unload(slot index: Int) { load(slot: index, info: nil) }

    /// Loads the same plug-in again with the settings it last had: after a fault, or to recover.
    @discardableResult
    public func reload(slot index: Int, completion: ((String?) -> Void)? = nil) -> String? {
        guard slots.indices.contains(index), let info = slots[index].info else { completion?(nil); return nil }
        let state = slots[index].plugin.flatMap { $0.hasFailed ? nil : $0.state } ?? slots[index].lastGoodState
        return load(slot: index, info: info, state: state, completion: completion)
    }

    // MARK: - Housekeeping

    /// About once a second (or every UI frame; it is cheap), on the main thread: notices a plug-in
    /// that faulted, acts on `restartComponent` (a new latency, new I/O, a reload), and follows a
    /// latency the plug-in changed without saying. Returns whether anything the UI shows changed.
    @discardableResult
    public func poll() -> Bool {
        var changed = false
        for slot in slots {
            guard let plugin = slot.plugin, slot.failure == nil else { continue }
            if plugin.hasFailed {
                locked { slot.rtPlugin = nil }
                slot.failure = "Stopped responding — taken out of the chain"
                if deltaSlot == slot.index { deltaSlot = nil }
                changed = true
                continue
            }
            let flags = plugin.takeRestartFlags()
            if flags & 1 != 0 {                       // kReloadComponent
                reload(slot: slot.index)
                changed = true
                continue
            }
            if flags & (2 | 8) != 0, !slot.refused {  // kIoChanged, kLatencyChanged
                locked { apply(plugin.restart(channels: channels), to: slot) }
                applyMix(slot.index)
                changed = true
            } else if slot.rtPlugin != nil {
                let latency = plugin.latencySamples
                if latency != slot.latencyFrames {
                    locked { setLatency(latency, of: slot) }
                    changed = true
                }
            }
        }
        return changed
    }

    // MARK: - State

    public func isLive(_ index: Int) -> Bool {
        slots.indices.contains(index) && slots[index].plugin != nil && slots[index].rtPlugin != nil
    }
    public func isRefused(_ index: Int) -> Bool { slots.indices.contains(index) && slots[index].refused }
    public func isBypassed(_ index: Int) -> Bool { slots.indices.contains(index) && slots[index].bypassed }
    public func mix(_ index: Int) -> Double { slots.indices.contains(index) ? slots[index].mix : 1 }
    public func failure(_ index: Int) -> String? { slots.indices.contains(index) ? slots[index].failure : nil }
    public func info(_ index: Int) -> VST3PluginInfo? { slots.indices.contains(index) ? slots[index].info : nil }

    /// The slot's reported latency in milliseconds, which is also how far its dry leg is delayed.
    public func latencyMs(_ index: Int) -> Double {
        guard slots.indices.contains(index), sampleRate > 0 else { return 0 }
        return Double(slots[index].latencyFrames) / sampleRate * 1000
    }

    /// Level going into and coming out of slot `index`'s plug-in, 0…1, for a meter polled about
    /// 30 times a second: the loudest since the last poll, falling gently between, as on the Mac.
    public func level(slot index: Int, output: Bool) -> Float {
        guard slots.indices.contains(index), isLive(index) else { return 0 }
        let slot = slots[index]
        let k = output ? 1 : 0
        let fresh = slot.peaks[k]
        slot.peaks[k] = 0
        if output { slot.shown.output = max(fresh, slot.shown.output * 0.82); return slot.shown.output }
        slot.shown.input = max(fresh, slot.shown.input * 0.82)
        return slot.shown.input
    }

    // MARK: - Bypass, dry/wet, delta

    public func setBypass(slot index: Int, _ bypassed: Bool) {
        guard slots.indices.contains(index) else { return }
        slots[index].bypassed = bypassed
        slots[index].plugin?.setBypass(bypassed)
        if bypassed, deltaSlot == index { deltaSlot = nil }
        applyMix(index)
    }

    /// 0 = all dry, 1 = all wet.
    public func setMix(slot index: Int, _ mix: Double) {
        guard slots.indices.contains(index) else { return }
        slots[index].mix = min(1, max(0, mix))
        applyMix(index)
    }

    /// The gains the audio thread ramps to: Δ is a unity comparison whatever the knob says, as on
    /// the Mac; bypass is the dry leg alone and undelayed; otherwise the knob, with the dry leg
    /// delayed at every blend.
    private func applyMix(_ index: Int) {
        let slot = slots[index]
        let wet: Float, dry: Float
        if deltaSlot == index, !slot.bypassed { wet = 1; dry = -1 }
        else if slot.bypassed { wet = 0; dry = 1 }
        else { wet = Float(slot.mix); dry = 1 - Float(slot.mix) }
        slot.gainLock.write {
            slot.gains[0] = wet
            slot.gains[1] = dry
            slot.gains[2] = slot.bypassed ? 1 : 0
        }
    }

    /// Carries slot `index`'s difference — `wet − dry`, the dry leg delayed to match the plug-in's
    /// reported latency. Returns the compensation applied, in frames, so the caller can say whether
    /// the null is to be trusted (a plug-in that under-reports combs rather than nulls). Bypassed,
    /// refused and empty slots refuse, because the difference a plug-in out of circuit makes is
    /// nothing. One slot at a time.
    @discardableResult
    public func setDelta(slot index: Int, _ on: Bool) -> Int? {
        guard slots.indices.contains(index) else { return nil }
        if on, let previous = deltaSlot, previous != index {
            deltaSlot = nil
            applyMix(previous)
        }
        guard on else {
            guard deltaSlot == index else { return nil }
            deltaSlot = nil
            applyMix(index)
            return nil
        }
        guard isLive(index), !slots[index].bypassed else { return nil }
        deltaSlot = index
        applyMix(index)
        return slots[index].rtLatency
    }

    // MARK: - Editor

    public func hasEditor(slot index: Int) -> Bool {
        slots.indices.contains(index) && (slots[index].plugin?.hasEditor ?? false)
    }

    /// Opens slot `index`'s editor in its own window owned by `parent`, titled with the plug-in's
    /// name, or brings it forward. Main thread, which runs the message loop the window needs.
    @discardableResult
    public func openEditor(slot index: Int, parent: HWND?) -> Bool {
        guard slots.indices.contains(index), let plugin = slots[index].plugin, slots[index].failure == nil else { return false }
        return plugin.openEditor(parent: parent, title: plugin.info.name) { [weak self, weak slot = slots[index]] in
            // The moment someone has usually finished adjusting it: keep its settings for Reload.
            if let slot, let p = slot.plugin, !p.hasFailed { slot.lastGoodState = p.state }
            self?.onEditorClosed?(index)
        }
    }

    public func closeEditor(slot index: Int) {
        guard slots.indices.contains(index) else { return }
        slots[index].plugin?.closeEditor()
    }

    public func closeAllEditors() { for slot in slots { slot.plugin?.closeEditor() } }

    // MARK: - Saving

    /// UserDefaults keys: `<prefix><n>` for slot n (0, 1, 2), each a dictionary of
    ///   "id", "name", "vendor", "path", "classID", "version": String; "subcategories": [String];
    ///   "state": String (base64 of `VST3Plugin.state`); "bypass": Bool; "mix": Double.
    /// An empty slot has no key.
    public static let defaultsPrefix = "VST3InsertSlot"

    public func save(to defaults: UserDefaults = .standard, prefix: String = VST3InsertChain.defaultsPrefix) {
        for slot in slots {
            let key = "\(prefix)\(slot.index)"
            guard let info = slot.info else { defaults.removeObject(forKey: key); continue }
            let state = slot.plugin.flatMap { $0.hasFailed ? nil : $0.state } ?? slot.lastGoodState
            if let state { slot.lastGoodState = state }
            var entry: [String: Any] = [
                "id": info.id, "name": info.name, "vendor": info.vendor, "path": info.path,
                "classID": info.classID, "version": info.version, "subcategories": info.subcategories,
                "bypass": slot.bypassed, "mix": slot.mix,
            ]
            if let state { entry["state"] = state.base64EncodedString() }
            defaults.set(entry, forKey: key)
        }
    }

    /// Loads what `save` stored. The catalog, if given, supplies where each plug-in is now (it is
    /// found by class ID); otherwise the saved path is used. Returns the problems, if any.
    @discardableResult
    public func restore(from defaults: UserDefaults = .standard, prefix: String = VST3InsertChain.defaultsPrefix,
                        catalog: VST3Catalog? = nil) -> [String] {
        var problems: [String] = []
        for slot in slots {
            guard let entry = defaults.dictionary(forKey: "\(prefix)\(slot.index)"),
                  let classID = entry["classID"] as? String, let path = entry["path"] as? String else {
                if slot.plugin != nil { unload(slot: slot.index) }
                continue
            }
            let saved = VST3PluginInfo(name: entry["name"] as? String ?? "Plug-in",
                                       vendor: entry["vendor"] as? String ?? "",
                                       path: path, classID: classID,
                                       subcategories: entry["subcategories"] as? [String] ?? [],
                                       version: entry["version"] as? String ?? "")
            let info = catalog?.plugin(id: classID) ?? saved
            slot.bypassed = entry["bypass"] as? Bool ?? false
            slot.mix = min(1, max(0, entry["mix"] as? Double ?? 1))
            let state = (entry["state"] as? String).flatMap { Data(base64Encoded: $0) }
            if let problem = load(slot: slot.index, info: info, state: state) { problems.append(problem) }
            slot.lastGoodState = state ?? slot.lastGoodState
        }
        return problems
    }

    // MARK: - The audio thread

    /// Runs the bus through the live slots, in place: `buses[c]` is channel `c` in the engine's
    /// SMPTE order, `channels` wide (the width `configure` was given, else left alone), `frames`
    /// long. Audio thread only: no allocation, no waiting, no COM.
    public func process(buses: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels: Int, frames: Int) {
        guard frames > 0, TryAcquireSRWLockExclusive(lock) != 0 else { return }
        defer { ReleaseSRWLockExclusive(lock) }
        guard channels == rtChannels else { return }
        var done = 0
        while done < frames {
            let n = min(frames - done, rtMaxFrames)
            for c in 0..<channels { piecePointers[c] = buses[c] + done }
            for slot in slots { process(slot, channels: channels, frames: n) }
            done += n
        }
    }

    private func process(_ slot: VST3InsertSlot, channels: Int, frames n: Int) {
        guard let handle = slot.rtPlugin, let delay = slot.delay else { return }
        let read = slot.gainLock.read { (slot.gains[0], slot.gains[1], slot.gains[2]) }
        let wet = read.0, dry = read.1, bypassed = read.2 > 0.5
        let piece = piecePointers

        var inPeak: Float = 0
        for c in 0..<channels {
            let p = piece[c]
            dryPointers[c].update(from: p, count: n)
            for i in 0..<n { inPeak = max(inPeak, abs(p[i])) }
        }

        let planes = UnsafeRawPointer(piece).assumingMemoryBound(to: UnsafeMutablePointer<Float>?.self)
        let status = nag_vst3_process(handle, planes, Int32(channels), Int32(n))
        if status != 0 {
            // Not processed (or it faulted, which `poll` will see): the bus is still dry.
            delay.process(dryPointers, channels: channels, frames: n, delay: slot.rtLatency, output: false)
            return
        }

        var outPeak: Float = 0
        for c in 0..<channels {
            let p = piece[c]
            for i in 0..<n { outPeak = max(outPeak, abs(p[i])) }
        }

        if bypassed {
            // The line is still fed, so taking bypass off finds it current.
            delay.process(dryPointers, channels: channels, frames: n, delay: slot.rtLatency, output: false)
            for c in 0..<channels { piece[c].update(from: dryPointers[c], count: n) }
            slot.appliedWet = 0
            slot.appliedDry = 1
        } else {
            delay.process(dryPointers, channels: channels, frames: n, delay: slot.rtLatency, output: true)
            let w0 = slot.appliedWet, d0 = slot.appliedDry
            if w0 == wet && d0 == dry {
                if !(wet == 1 && dry == 0) {
                    for c in 0..<channels {
                        let p = piece[c], d = dryPointers[c]
                        for i in 0..<n { p[i] = p[i] * wet + d[i] * dry }
                    }
                }
            } else {
                // A new balance arrives as a ramp across this block, not a step.
                let step = 1 / Float(n)
                for c in 0..<channels {
                    let p = piece[c], d = dryPointers[c]
                    for i in 0..<n {
                        let t = Float(i + 1) * step
                        p[i] = p[i] * (w0 + (wet - w0) * t) + d[i] * (d0 + (dry - d0) * t)
                    }
                }
                slot.appliedWet = wet
                slot.appliedDry = dry
            }
        }

        if inPeak > slot.peaks[0] { slot.peaks[0] = inPeak }
        if outPeak > slot.peaks[1] { slot.peaks[1] = outPeak }
    }

    // MARK: - Diagnostics

    /// The chain as it is wired, one part per occupied slot, as the Mac's `summary(channels:)`.
    public var summary: [String] {
        func db(_ v: Float) -> String { v > 0.00001 ? String(format: "%.0f", 20 * log10(v)) : "−∞" }
        var parts: [String] = []
        for slot in slots {
            guard slot.info != nil else { continue }
            if let failure = slot.failure { parts.append("[\(slot.displayName): FAILED — \(failure)]"); continue }
            if slot.refused { parts.append("[\(slot.displayName): OUT — cannot take \(channels) ch]"); continue }
            let ms = latencyMs(slot.index)
            if deltaSlot == slot.index {
                parts.append(String(format: "[%@: DELTA wet − dry, dry delayed %.1f ms]", slot.displayName, ms))
                continue
            }
            let wet = slot.bypassed ? 0 : Int((slot.mix * 100).rounded())
            let aligned = !slot.bypassed && ms > 0 ? String(format: ", dry aligned %.1f ms", ms) : ""
            let levels = ", in \(db(slot.peaks[0])) → out \(db(slot.peaks[1])) dBFS"
            parts.append("[\(slot.displayName): wet \(wet) % ∥ dry \(100 - wet) %\(aligned), VST3 in-process\(levels)]")
        }
        return parts
    }
}
