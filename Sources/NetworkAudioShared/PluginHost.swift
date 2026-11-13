import Foundation
import AVFoundation
import AudioToolbox
import CoreAudioKit
import AppKit

/// One installed effect plugin.
///
/// macOS loads **Audio Units**. VST/VST3 are not loadable without bundling Steinberg's own
/// host SDK, but essentially every room-correction and EQ plugin (SoundID Reference, FabFilter,
/// Waves, Apple's own) ships an AU alongside its VST, so the practical coverage is the same.
public struct PluginInfo: Identifiable, Hashable {
    public let name: String
    public let manufacturer: String
    public let type: OSType
    public let subType: OSType
    public let manufacturerCode: OSType
    public let hasCustomView: Bool

    public init(name: String, manufacturer: String, type: OSType, subType: OSType,
                manufacturerCode: OSType, hasCustomView: Bool) {
        self.name = name
        self.manufacturer = manufacturer
        self.type = type
        self.subType = subType
        self.manufacturerCode = manufacturerCode
        self.hasCustomView = hasCustomView
    }

    public var id: String { "\(type)-\(subType)-\(manufacturerCode)" }
    public var display: String { "\(name) — \(manufacturer)" }

    public var componentDescription: AudioComponentDescription {
        AudioComponentDescription(componentType: type,
                                  componentSubType: subType,
                                  componentManufacturer: manufacturerCode,
                                  componentFlags: 0,
                                  componentFlagsMask: 0)
    }
}

public enum PluginCatalog {
    /// Installed Audio Units of one type.
    ///
    /// **Both `aufx` and `aumf` belong in the insert list.** The app enumerated
    /// `kAudioUnitType_Effect` only, on the reasoning that music effects are note-driven and
    /// have no place on a monitor bus — and that reasoning is wrong. `aumf` means "an
    /// audio effect that also accepts MIDI", not "an instrument": FabFilter ship Pro-Q 4 as
    /// `aumf` while Pro-Q 3 was `aufx`, and a dynamic EQ that can be MIDI-driven processes audio
    /// exactly like one that cannot. Instruments are `aumu`, which is not enumerated.
    ///
    /// The real reason for the restriction was a deadlock: this call for `kAudioUnitType_
    /// MusicEffect` never returned while an `AVAudioEngine` was running. That no longer
    /// reproduces — 59 music effects in under 10 ms with the engine started — but the caller
    /// still scans effects first and publishes them before asking for music effects, so a
    /// return of the hang degrades to the old behaviour rather than to empty menus.
    public static func units(of type: OSType) -> [PluginInfo] {
        let description = AudioComponentDescription(componentType: type,
                                                    componentSubType: 0,
                                                    componentManufacturer: 0,
                                                    componentFlags: 0,
                                                    componentFlagsMask: 0)
        return AVAudioUnitComponentManager.shared().components(matching: description)
            .map { component in
                let d = component.audioComponentDescription
                return PluginInfo(name: component.name,
                                  manufacturer: component.manufacturerName,
                                  type: d.componentType,
                                  subType: d.componentSubType,
                                  manufacturerCode: d.componentManufacturer,
                                  hasCustomView: component.hasCustomView)
            }
    }

    /// Plain audio effects — `aufx`.
    public static func effects() -> [PluginInfo] { units(of: kAudioUnitType_Effect) }

    /// Effects that also accept MIDI — `aumf`. Not instruments, which are `aumu` and are never
    /// enumerated.
    public static func musicEffects() -> [PluginInfo] { units(of: kAudioUnitType_MusicEffect) }

    /// De-duplicated and sorted by manufacturer then name, which is the order the menus group by.
    public static func tidied(_ units: [PluginInfo]) -> [PluginInfo] {
        var seen = Set<String>()
        return units
            .filter { seen.insert($0.id).inserted }
            .sorted {
                ($0.manufacturer.lowercased(), $0.name.lowercased())
                    < ($1.manufacturer.lowercased(), $1.name.lowercased())
            }
    }

    /// Apple's built-in peak limiter, used as the optional headphone safety net.
    public static var appleLimiter: AudioComponentDescription {
        AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                  componentSubType: kAudioUnitSubType_PeakLimiter,
                                  componentManufacturer: kAudioUnitManufacturer_Apple,
                                  componentFlags: 0,
                                  componentFlagsMask: 0)
    }
}

/// One insert slot. Shared by the Grabber's monitor path and the Sender's — see `InsertChain`.
public final class PluginSlot {
    public let index: Int
    public private(set) var info: PluginInfo?
    public private(set) var node: AVAudioUnit?
    private var window: NSWindow?

    /// Hard bypass. `InsertChain` silences the slot's wet path when this is set, so the bypass
    /// holds whether or not the plugin honours `shouldBypassEffect` — several do not. The
    /// plugin is told as well, so it can stop working while it is out of circuit.
    public var bypassed = false {
        didSet { node?.auAudioUnit.shouldBypassEffect = bypassed }
    }

    /// Dry/wet balance: 0 is the untouched signal, 1 is the plugin alone. Applied by
    /// `InsertChain` as gains on the slot's parallel paths, not by the plugin.
    public var mix: Double = 1

    /// Whether the plugin will accept a bus this wide, asked **before** it is connected.
    ///
    /// `channelCapabilities` is a list of (in, out) pairs; a negative entry means "any", and an
    /// empty list means the unit has not declared a restriction. Room-correction and EQ units
    /// are frequently stereo-only and will refuse an 8-channel format outright, and finding
    /// that out by connecting it and watching the engine fail is both late and noisy.
    public func accepts(channels: Int) -> Bool {
        guard let unit = node?.auAudioUnit else { return true }
        guard let capabilities = unit.channelCapabilities, !capabilities.isEmpty else { return true }
        for pair in stride(from: 0, to: capabilities.count - 1, by: 2) {
            let input = capabilities[pair].intValue
            let output = capabilities[pair + 1].intValue
            let inputOK = input < 0 || input == channels
            let outputOK = output < 0 || output == channels
            if inputOK && outputOK { return true }
        }
        return false
    }

    /// Processing delay the plugin reports, in seconds. A partial dry/wet blend across a
    /// latent plugin comb-filters, because nothing delays the dry path to match, so this is
    /// what the warning in `AppState.setSlotMix` is keyed on.
    public var latencySeconds: Double { node?.auAudioUnit.latency ?? 0 }

    /// Why the plugin is no longer running, when it has stopped by itself — its process ended
    /// under it. Cleared by loading again. Distinct from a plugin that never loaded, which
    /// leaves the slot empty with the reason in the log.
    public private(set) var failure: String?

    /// Whether the plugin runs in macOS's plugin-hosting process rather than in this app's.
    public private(set) var outOfProcess = false

    /// Called on the main queue when the plugin's process has gone, with the dead node, so the
    /// owner can take it out of its engine and rebuild without it.
    public var onFailure: ((AVAudioUnit) -> Void)?

    /// Whether the owner should bring the plugin back by itself after this failure:
    /// yes the first time, so a one-off crash costs a second or two of the plugin rather than a
    /// trip to the insert; no if it failed again within `retryWindow` of the last time, so a
    /// plugin that keeps crashing — on this audio, say — is left out until Reload is pressed.
    public private(set) var retriesAutomatically = false
    public static let retryWindow: TimeInterval = 60
    /// How long the owner waits before that automatic reload: the hosting process has to be gone.
    public static let retryDelay: TimeInterval = 2
    private var lastFailure: Date?

    /// The plugin's settings as last seen alive, so Reload can put them back: a plugin that has
    /// crashed cannot be asked for them afterwards. Taken whenever the owner saves, and when the
    /// plugin's own window closes — the moment someone has usually finished adjusting it.
    private var lastGoodState: Data?
    private var invalidation: NSObjectProtocol?

    public init(index: Int) { self.index = index }

    public var isLoaded: Bool { node != nil }
    public var displayName: String { info?.name ?? "Empty" }

    /// Instantiates the plugin off the main thread and calls back on the main queue.
    /// Passing nil unloads the slot.
    ///
    /// **Out of process where the plugin allows it.** The plugin runs in
    /// macOS's own plugin-hosting process, so a plugin that crashes takes that process down,
    /// not this app and its audio: the slot reports `failure`, the owner rebuilds without it,
    /// and Reload brings it back. Audio Hijack hosts its plugins the same way. A plugin that
    /// will not run out of process — some copy protection refuses — is loaded in-process, as
    /// every plugin was before.
    public func load(_ info: PluginInfo?, completion: @escaping (String?) -> Void) {
        if node != nil { _ = savedState }
        closeUI()
        stopWatching()
        node = nil
        failure = nil
        if info?.id != self.info?.id { lastGoodState = nil; lastFailure = nil }
        self.info = info
        guard let info else {
            completion(nil)
            return
        }
        // `NAG_INSERTS_IN_PROCESS=1` loads in-process, for an A/B against the old behaviour.
        let inProcess = ProcessInfo.processInfo.environment["NAG_INSERTS_IN_PROCESS"] == "1"
        instantiate(info, outOfProcess: !inProcess, completion: completion)
    }

    private func instantiate(_ info: PluginInfo, outOfProcess: Bool, completion: @escaping (String?) -> Void) {
        AVAudioUnit.instantiate(with: info.componentDescription,
                                options: outOfProcess ? .loadOutOfProcess : []) { [weak self] unit, error in
            DispatchQueue.main.async {
                guard let self, self.info?.id == info.id else { return }
                if let error {
                    if outOfProcess {
                        self.instantiate(info, outOfProcess: false, completion: completion)
                        return
                    }
                    self.info = nil
                    completion("\(info.name) failed to load: \(error.localizedDescription)")
                    return
                }
                self.node = unit
                self.outOfProcess = outOfProcess
                unit?.auAudioUnit.shouldBypassEffect = self.bypassed
                if let unit {
                    self.watch(unit)
                    self.probeAnswered = outOfProcess && Self.answers(unit)
                }
                completion(nil)
            }
        }
    }

    /// Loads the same plugin again after a failure, with the settings it last had.
    public func reload(completion: @escaping (String?) -> Void) {
        guard let info else { completion(nil); return }
        let state = lastGoodState
        load(info) { [weak self] error in
            if error == nil, let state { self?.restoreState(state) }
            completion(error)
        }
    }

    /// Whether the plugin answered the health check when it loaded. Only a plugin that did can
    /// be judged by it later: one that never answers is not thereby dead.
    private var probeAnswered = false

    private static func answers(_ unit: AVAudioUnit) -> Bool {
        var latency = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioUnitGetProperty(unit.audioUnit, kAudioUnitProperty_Latency,
                                    kAudioUnitScope_Global, 0, &latency, &size) == noErr
    }

    /// **The health check** — call about once a second, on the main thread; ~0.2 ms.
    ///
    /// Measured: when the hosting process of an out-of-process plugin is killed,
    /// macOS posts nothing, does not restart it, and the render keeps "succeeding" while the
    /// plugin's output is silence — at 100 % wet, a monitor gone quiet with no reason given. A
    /// property query to the dead instance fails (status 4099), where a live one answers. So a
    /// plugin that answered at load and stops answering has gone, and is failed as a crash is.
    public func probe() {
        guard outOfProcess, probeAnswered, let unit = node else { return }
        guard Self.answers(unit) else { fail(unit); return }
        // Alive, and its window open: someone may be adjusting it, so the settings Reload puts
        // back are kept fresh every few seconds rather than only when the window closes.
        if window != nil {
            snapshotTicks += 1
            if snapshotTicks % 5 == 0 { _ = savedState }
        }
    }
    private var snapshotTicks = 0

    private func fail(_ dead: AVAudioUnit) {
        guard node === dead else { return }
        stopWatching()
        window?.close()
        window = nil
        node = nil
        probeAnswered = false
        let now = Date()
        retriesAutomatically = lastFailure.map { now.timeIntervalSince($0) >= Self.retryWindow } ?? true
        lastFailure = now
        failure = retriesAutomatically ? "Stopped responding — reloading…"
                                       : "Stopped responding again — taken out of the chain"
        onFailure?(dead)
    }

    /// macOS says when an instance has become invalid — its hosting process has exited. Not
    /// posted for every kind of plugin (see `probe`), but acted on when it is.
    private func watch(_ unit: AVAudioUnit) {
        let name = Notification.Name(rawValue: kAudioComponentInstanceInvalidationNotification as String)
        // Any sender, matched here: for a version-3 unit the notice comes from its `AUAudioUnit`;
        // for a version-2 unit it carries the `AudioUnit` in its userInfo instead.
        let wrapper = unit.auAudioUnit
        let instance = unit.audioUnit
        invalidation = NotificationCenter.default.addObserver(forName: name, object: nil,
                                                              queue: .main) { [weak self] note in
            let fromWrapper = (note.object as AnyObject?) === wrapper
            let fromInstance = (note.userInfo?["audioUnit"] as? NSValue)?.pointerValue
                .map { UnsafeMutableRawPointer($0) == UnsafeMutableRawPointer(instance) } ?? false
            guard fromWrapper || fromInstance else { return }
            self?.fail(unit)
        }
    }

    private func stopWatching() {
        if let invalidation { NotificationCenter.default.removeObserver(invalidation) }
        invalidation = nil
    }

    // MARK: - State

    /// The plugin's own settings, for saving between launches.
    public var savedState: Data? {
        guard let state = node?.auAudioUnit.fullState else { return lastGoodState }
        let data = try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
        if let data { lastGoodState = data }
        return data
    }

    public func restoreState(_ data: Data) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let state = plist as? [String: Any] else { return }
        node?.auAudioUnit.fullState = state
    }

    // MARK: - Editor window

    public func showUI() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let unit = node else { return }
        unit.auAudioUnit.requestViewController { [weak self] controller in
            guard let self else { return }
            guard let controller else {
                NSSound.beep()
                return
            }
            let w = NSWindow(contentViewController: controller)
            w.title = self.info?.name ?? "Plugin"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            // Closed with its own button: keep what the plugin was set to, for Reload.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w,
                                                   queue: .main) { [weak self] _ in
                if self?.node != nil { _ = self?.savedState }
                self?.window = nil
            }
            w.center()
            w.makeKeyAndOrderFront(nil)
            self.window = w
        }
    }

    public func closeUI() {
        if window != nil, node != nil { _ = savedState }
        window?.close()
        window = nil
    }
}
