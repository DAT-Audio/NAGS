import SwiftUI
import AppKit
import AudioToolbox

/// The Mac's Sender: the shared engine's `SendEngine`, plus what only the Mac has — the look
/// (appearance, colour scheme, skin), the Audio Unit inserts, and the hooks into macOS (the
/// network's identity, App Nap, the Dock's bounce, the output device). Everything else is the
/// engine's, which the Windows build shares. The name, and every member the views
/// use, are as before, so no view changed.
@Observable
final class SenderState: SendEngine {
    private let inserts: InsertProcessor
    /// Keeps App Nap off while sending (`BusyAssertion`).
    @ObservationIgnored private let busy = BusyAssertion(reason: "Sending this Mac's audio")

    /// `onDemand`: the Grabber's Send. `hostFeed`: the Audio Unit's, which sends its track rather
    /// than capturing the Mac. `defaultName`: the stream's name until one is chosen.
    init(defaults: UserDefaults = .standard, onDemand: Bool = false, hostFeed: HostAudioFeed? = nil,
         defaultName: String? = nil) {
        let processor = InsertProcessor()
        inserts = processor
        showInsertMix = defaults.object(forKey: "showInsertMix") as? Bool ?? true
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .dark
        theme = ThemeChoice.stored(in: defaults)   // Graphite & Amber unless set before
        // What to send: the system output unless chosen otherwise, through one
        // capture that swaps its source underneath.
        let source = SendSource(stored: defaults.string(forKey: "sendSource"))
        sendSource = source
        let switchable = hostFeed == nil ? SwitchableCapture(source: source) : nil
        sourceCapture = switchable
        super.init(defaults: defaults, onDemand: onDemand, hostFeed: hostFeed, defaultName: defaultName,
                   capture: switchable, processor: processor,
                   logFile: defaults === UserDefaults.standard
                       ? ActivityLog.standardFile(bundleID: Bundle.main.bundleIdentifier ?? "app.networkaudiosender.send")
                       : nil)
        // A plugin whose process has gone: the rebuild detaches every node, the dead one
        // included, so the stream carries on without it.
        for slot in processor.chain.slots {
            let i = slot.index
            slot.onFailure = { [weak self, weak slot] _ in
                guard let self, let slot else { return }
                self.inserts.rebuild()
                let name = self.slotInfo[i]?.name ?? "plugin"
                if slot.retriesAutomatically {
                    self.note(.failed, "Insert \(i + 1) (\(name)) stopped responding; sending carries on without "
                                   + "it while it is reloaded with its last settings.")
                    // The one automatic reload, once the hosting process has gone — unless the
                    // slot has been changed or reloaded since.
                    let id = self.slotInfo[i]?.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + PluginSlot.retryDelay) { [weak self, weak slot] in
                        guard let self, let slot, slot.failure != nil, self.slotInfo[i]?.id == id else { return }
                        self.reloadPlugin(slot: i)
                    }
                } else {
                    self.note(.failed, "Insert \(i + 1) (\(name)) stopped responding again within a minute and was "
                                   + "taken out of the chain; sending carries on without it. Reload it from the insert.")
                }
                self.slotRevision &+= 1
            }
        }
        processor.onError = { [weak self] message in
            DispatchQueue.main.async { self?.draftError = message }
        }
    }

    /// The Mac's system-audio capture, for the self-test's `--only-pid`.
    var systemCapture: SystemAudioCapture? { sourceCapture?.inner as? SystemAudioCapture }

    // MARK: Source

    @ObservationIgnored private let sourceCapture: SwitchableCapture?

    /// What is sent: the system output (the default), chosen apps, or one input device.
    public var sendSource: SendSource {
        didSet {
            guard sendSource != oldValue else { return }
            persist("sendSource", sendSource.stored)
            sourceCapture?.source = sendSource
            note(.note, "Source: \(sourceDescription).")
        }
    }

    /// The source in words, for the log and the window.
    public var sourceDescription: String {
        switch sendSource {
        case .system: return "system audio output, all apps"
        case .apps(let ids):
            let names = ids.map(RunningAudioApp.name(of:))
            return names.count == 1 ? names[0] : "\(names.count) apps (\(names.joined(separator: ", ")))"
        case .input(_, let name): return name
        }
    }

    /// Short, for the header and the stream panel.
    public var sourceShort: String {
        switch sendSource {
        case .system: return "System audio"
        case .apps(let ids): return ids.count == 1 ? RunningAudioApp.name(of: ids[0]) : "\(ids.count) apps"
        case .input(_, let name): return name
        }
    }

    public var sourceSymbol: String {
        switch sendSource {
        case .system: return "speaker.wave.2"
        case .apps: return "app.badge"
        case .input: return "mic"
        }
    }

    // MARK: Hooks into macOS

    override func platformStart() { scanPlugins() }
    override func platformShutdown() { savePlugins() }
    override func platformTick() { inserts.chain.probe() }
    override func outputDevice() -> (name: String, rate: Int)? { SystemAudioCapture.defaultOutput() }
    override func requestAttention() {
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }
    override func setBusy(_ busy: Bool) { self.busy.set(busy) }
    override func networkSignature(interface: String, broadcast: String?) -> String {
        NetworkIdentity.signature(interface: interface, broadcast: broadcast)
    }

    // MARK: Look

    // Dark unless chosen otherwise.

    public var appearance: Appearance { didSet { persist("appearance", appearance.rawValue) } }
    /// The look that goes with the scheme: REAPER's for Rea-Theme Default, the app's own otherwise.
    public var skin: Skin { Skin.for(enabled: theme.enabled, primary: theme.primaryHex, secondary: theme.secondaryHex) }

    public var theme: ThemeChoice {
        didSet {
            persist("themeEnabled", theme.enabled)
            persist("themePrimaryHex", theme.primaryHex)
            persist("themeSecondaryHex", theme.secondaryHex)
        }
    }
    public var showSettings = false
    /// Settings shows the log instead of the settings — a tab rather than another button.
    public var settingsShowsLog = false

    // MARK: Inserts — the Grabber's, via `InsertChain`

    public private(set) var availablePlugins: [PluginInfo] = []
    public private(set) var slotInfo: [PluginInfo?] = [nil, nil, nil]
    public private(set) var slotBypassed: [Bool] = [false, false, false]
    public private(set) var slotMix: [Double] = [1, 1, 1]
    /// Off by default, as in the Grabber: the least reached-for control, and the widest.
    public var showInsertMix: Bool { didSet { persist("showInsertMix", showInsertMix) } }

    /// System Settings at the privacy page that holds audio recording. If the exact pane is not
    /// found, macOS opens Privacy & Security, one click away from it.
    public func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }



    // MARK: - Inserts

    /// Effects first, published on their own, then MIDI-capable effects added: the Grabber's
    /// order.
    private func scanPlugins() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let effects = PluginCatalog.tidied(PluginCatalog.effects())
            DispatchQueue.main.async {
                self?.availablePlugins = effects
                self?.restorePlugins()
            }
            let music = PluginCatalog.musicEffects()
            guard !music.isEmpty else { return }
            let both = PluginCatalog.tidied(effects + music)
            DispatchQueue.main.async {
                self?.availablePlugins = both
                self?.restorePlugins()
            }
        }
    }

    private var restored = false

    /// Puts back the plugins, their settings, bypass and blend from last time, once the scan
    /// can say which are still installed.
    private func restorePlugins() {
        guard !restored else { return }
        var pending = false
        for i in inserts.chain.slots.indices {
            guard let id = defaults.string(forKey: "slot\(i).plugin") else { continue }
            guard let info = availablePlugins.first(where: { $0.id == id }) else { pending = true; continue }
            let state = defaults.data(forKey: "slot\(i).state")
            slotBypassed[i] = defaults.bool(forKey: "slot\(i).bypass")
            slotMix[i] = defaults.object(forKey: "slot\(i).mix") as? Double ?? 1
            load(info, into: i) { [weak self] in
                guard let self else { return }
                if let state { self.inserts.chain.slots[i].restoreState(state) }
                self.inserts.setBypass(slot: i, self.slotBypassed[i])
                self.inserts.setMix(slot: i, self.slotMix[i])
            }
        }
        // A plugin missing from the effects-only first pass may be a music effect; wait for the
        // second before giving up on it.
        restored = !pending || availablePlugins.contains { $0.type == kAudioUnitType_MusicEffect }
    }

    public func setPlugin(slot i: Int, to info: PluginInfo?) {
        guard inserts.chain.slots.indices.contains(i) else { return }
        slotBypassed[i] = false
        slotMix[i] = 1
        load(info, into: i) { [weak self] in
            self?.inserts.setBypass(slot: i, false)
            self?.inserts.setMix(slot: i, 1)
        }
    }

    private func load(_ info: PluginInfo?, into i: Int, then: @escaping () -> Void = {}) {
        slotInfo[i] = info
        inserts.chain.slots[i].load(info) { [weak self] error in
            guard let self else { return }
            if let error { self.draftError = error; self.slotInfo[i] = nil }
            self.inserts.rebuild()
            then()
            self.savePlugins()
            // Loading finishes after the menu choice; the slot's controls wait for it.
            self.slotRevision &+= 1
        }
    }

    public func toggleBypass(slot i: Int) {
        slotBypassed[i].toggle()
        inserts.setBypass(slot: i, slotBypassed[i])
        savePlugins()
    }

    public func setSlotMix(_ i: Int, _ mix: Double) {
        slotMix[i] = mix
        inserts.setMix(slot: i, mix)
        savePlugins()
    }

    /// True while any slot holds a plugin: the inserts then shape what is sent, which this Mac's
    /// own speakers never hear.
    public var hasInserts: Bool { slotInfo.contains { $0 != nil } }

    /// Help → Connect to a Grabber over VBAN…: the window opens the guide and clears this.
    public var connectGuideRequested = false

    /// Bumped when a plugin finishes loading. The chain is not observable, so the getters below
    /// read this to refresh the slot controls that show it.
    public private(set) var slotRevision = 0

    public func slotIsLive(_ i: Int) -> Bool { _ = slotRevision; return inserts.chain.isLive(i) }
    public func slotIsRefused(_ i: Int) -> Bool { _ = slotRevision; return inserts.chain.isRefused(i) }
    public func slotLatencyMs(_ i: Int) -> Double { _ = slotRevision; return inserts.chain.slots[i].latencySeconds * 1000 }
    public var insertChannels: Int { _ = slotRevision; return inserts.channels }
    public var insertSummary: String { _ = slotRevision; return inserts.summary }
    public func showPluginUI(slot i: Int) { inserts.chain.slots[i].showUI() }
    public func slotLevel(_ i: Int, output: Bool) -> Float { inserts.chain.level(slot: i, output: output) }
    public func slotFailure(_ i: Int) -> String? { _ = slotRevision; return inserts.chain.slots[i].failure }

    public func reloadPlugin(slot i: Int) {
        note(.note, "Insert \(i + 1): reloading \(slotInfo[i]?.name ?? "plugin").")
        inserts.chain.slots[i].reload { [weak self] error in
            guard let self else { return }
            if let error { self.draftError = error }
            self.inserts.rebuild()
            self.inserts.setBypass(slot: i, self.slotBypassed[i])
            self.inserts.setMix(slot: i, self.slotMix[i])
            self.slotRevision &+= 1
        }
    }

    private func savePlugins() {
        guard !previewOnly else { return }
        for (i, slot) in inserts.chain.slots.enumerated() {
            defaults.set(slotInfo[i]?.id, forKey: "slot\(i).plugin")
            defaults.set(slot.savedState, forKey: "slot\(i).state")
            defaults.set(slotBypassed[i], forKey: "slot\(i).bypass")
            defaults.set(slotMix[i], forKey: "slot\(i).mix")
        }
    }

    /// For the self-test: load a plugin by name into a slot.
    public func loadPlugin(named name: String, slot i: Int) -> Bool {
        guard let info = availablePlugins.first(where: {
            $0.name.localizedCaseInsensitiveContains(name)
        }) else { return false }
        setPlugin(slot: i, to: info)
        return true
    }

    /// For the render harness: show slots as filled without loading anything.
    public func setPreviewInserts(_ infos: [PluginInfo?]) {
        for (i, info) in infos.enumerated() where i < slotInfo.count { slotInfo[i] = info }
    }

    // MARK: - Theme

    public func applyTheme(_ preset: ThemePreset) {
        theme = ThemeChoice(enabled: true, primaryHex: preset.primary, secondaryHex: preset.secondary)
    }
}
