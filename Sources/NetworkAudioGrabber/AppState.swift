import Foundation
import SwiftUI
import CoreAudio
import SystemConfiguration
import CoreWLAN

/// The Mac's Grabber: the shared engine's `GrabberEngine`, plus what only the Mac has — the look
/// and the windows, the Audio Unit inserts, the Send (Network Audio Sender inside the Grabber),
/// internet streams (decoded by macOS), and the hooks into macOS: the output (`AudioOutput`), the
/// Bonjour browsers, the Wi-Fi names, App Nap, quitting and the main-thread watchdog. The name
/// and every member the views use are as before, so no view changed.
@Observable
final class AppState: GrabberEngine {
    /// Keeps App Nap off while a stream plays (`BusyAssertion`).
    @ObservationIgnored private let busy = BusyAssertion(reason: "Receiving network audio")
    @ObservationIgnored private let watchdog = MainWatchdog()

    /// `hostOutput`: a Grabber plugin hands in its own, made before the engine (its render thread
    /// holds it from the start). `keepsLog`: in a DAW, only one Receiver keeps the log file.
    init(defaults: UserDefaults = .standard, hostOutput: AudioOutput? = nil, keepsLog: Bool = true) {
        let audio = hostOutput ?? AudioOutput()
        self.audio = audio
        // The chosen output device, applied before the engine first starts. Not in a
        // DAW, where the host is the output.
        let chosenOutput = hostOutput == nil ? defaults.string(forKey: "outputDeviceUID") : nil
        outputDeviceUID = chosenOutput
        outputDeviceChosenName = defaults.string(forKey: "outputDeviceChosenName") ?? ""
        audio.preferredDeviceUID = chosenOutput
        // The platform's parts of the engine's discovery.
        Interfaces.wifiNames = Set(CWWiFiClient.shared().interfaceNames() ?? [])
        SAPListener.inflate = SAPInflate.inflate
        GrabberEngine.computerName = { SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "" }
        Self.carryOverLegacyDefaults(into: defaults)
        showInsertMix = defaults.object(forKey: "showInsertMix") as? Bool ?? true
        showLevelHistory = Self.storedShowLevelHistory(in: defaults)
        pinnedLoudness = (defaults.string(forKey: "pinnedLoudness")
            .flatMap(LoudnessPin.init(rawValue:))) ?? .integrated
        loudnessOpen = defaults.object(forKey: "loudnessOpen") as? Bool ?? false
        insertsOpen = defaults.object(forKey: "insertsOpen") as? Bool ?? false
        panelInsertsOpen = defaults.object(forKey: "panelInsertsOpen") as? Bool ?? false
        streamsOpen = defaults.object(forKey: "streamsOpen") as? Bool ?? true
        showPanel = defaults.object(forKey: "showPanel") as? Bool ?? true
        showSourceBar = defaults.object(forKey: "showSourceBar") as? Bool ?? true
        sendOpen = defaults.object(forKey: "sendOpen") as? Bool ?? true
        remoteMethod = defaults.integer(forKey: "remoteMethod")
        sendHeight = defaults.object(forKey: "sendHeight") as? Double ?? 190
        compactTab = defaults.integer(forKey: "compactTab")
        sourceFilterPlacementSetting = SourceFilterPlacement(rawValue: defaults.string(forKey: "sourceFilterPlacement") ?? "") ?? .sidebar
        viewMode = ViewMode(rawValue: defaults.string(forKey: "viewMode") ?? "") ?? .full
        let theme = ThemeChoice.stored(in: defaults)   // Graphite & Amber unless set before
        themeEnabled = theme.enabled
        themePrimaryHex = theme.primaryHex
        themeSecondaryHex = theme.secondaryHex
        meterHz = defaults.object(forKey: "meterHz") as? Int ?? 30
        // Dark unless chosen otherwise.
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .dark
        // Only the real app keeps its log on disk; a self-test or render keeps it in memory.
        let logFile = defaults === UserDefaults.standard
            ? ActivityLog.standardFile(bundleID: Bundle.main.bundleIdentifier ?? "app.networkaudiograbber.monitor")
            // The Audio Unit keeps its own, not under its host's name.
            : (AudioOutput.hostMode && keepsLog ? ActivityLog.standardFile(bundleID: PluginBridge.bundleID) : nil)
        super.init(defaults: defaults, output: audio, hostMode: AudioOutput.hostMode, logFile: logFile,
                   ravenna: RavennaBrowser(), dante: DanteBrowser())
        // The automatic reload after a plugin's first failure goes the way Reload does, logged.
        audio.onAutoReload = { [weak self] slot in self?.reloadPlugin(slot: slot) }
    }

    // MARK: - Hooks into macOS

    override func platformStart() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.shutdown() }
        // Send: the Sender's own state, idle until used; its log lines come here. Not in the
        // Grabber plugins: sending is the Sender plugin's job (`PluginBridge`).
        if !hostMode {
            let suite = defaults === UserDefaults.standard ? "app.networkaudiograbber.monitor.send"
                                                           : "app.networkaudiograbber.preview.send"
            // Named as the Grabber tells Senders it is, until renamed.
            let s = GrabberSend(suiteName: suite, defaultName: Self.receiverName(vbanReceiverName))
            s.log = { [weak self] kind, text in self?.append(log: text, kind) }
            send = s
            syncSendTheme()
            s.start()
            // The app's own main thread only: a DAW's is the host's business.
            watchdog.start { [weak self] held in
                self?.append(log: String(format: "The window did not respond for %.1f s.", held), .warning)
            }
        }
        // Off the main thread, and the insert menus filled in when it lands. The scan reads the
        // system's Audio Unit registry and loads no plugin's code (measured: 440
        // listed in 0.26 s, nothing loaded), so it cannot set off a plugin's licence check.
        // **Not in a DAW:** the plugins have no inserts, and querying the registry while the
        // host is scanning it hung the app on a slow machine.
        if !hostMode { DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Effects first, published on their own, then music effects added to them. Two
            // stages rather than one, so that if the music-effect query ever hangs
            // again the menus still hold every `aufx`, which is what the app shipped with,
            // instead of being empty.
            let scanStart = CFAbsoluteTimeGetCurrent()
            let effects = PluginCatalog.tidied(PluginCatalog.effects())
            let took = CFAbsoluteTimeGetCurrent() - scanStart
            DispatchQueue.main.async {
                self?.availablePlugins = effects
                self?.restorePlugins()
                // How long macOS took to list them: seconds, not a fraction of one, means it was
                // rebuilding its Audio Unit registry first (after new plugins or an update).
                self?.append(log: String(format: "Found %d Audio Units in %.1f s.", effects.count, took))
            }
            let music = PluginCatalog.musicEffects()
            guard !music.isEmpty else { return }
            let both = PluginCatalog.tidied(effects + music)
            DispatchQueue.main.async {
                self?.availablePlugins = both
                self?.restorePlugins()
            }
        } }
    }

    override func platformShutdown() {
        send?.shutdown()
        savePlugins()
    }

    override func platformTickAlways() {
        if showLevelHistory { sampleHistory() }
        // The chosen device unplugged, or back: said once each way, in the log and in Settings.
        let fallback = audio.usingFallback
        if fallback != outputFallback {
            outputFallback = fallback
            append(log: fallback
                   ? "\(outputDeviceChosenName) isn't connected: playing on the system default until it's back."
                   : "\(outputDeviceChosenName) is back: playing on it again.", fallback ? .warning : .note)
        }
    }

    // MARK: - Output device

    /// The chosen output device by UID; nil plays on the system default and follows it.
    var outputDeviceUID: String? {
        didSet {
            guard outputDeviceUID != oldValue else { return }
            defaults.set(outputDeviceUID, forKey: "outputDeviceUID")
            audio.setPreferredDevice(uid: outputDeviceUID)
        }
    }
    /// Its name when chosen, for saying so while it is unplugged.
    private(set) var outputDeviceChosenName: String {
        didSet { defaults.set(outputDeviceChosenName, forKey: "outputDeviceChosenName") }
    }
    /// The chosen device is not connected and the system default stands in.
    private(set) var outputFallback = false

    struct OutputDeviceOption: Identifiable, Hashable {
        let uid: String, name: String, channels: Int
        var id: String { uid }
    }

    /// Every output device connected now, by name, for the menus. Not this app's own private
    /// capture device, which only the Grabber's Send can see.
    var outputDeviceOptions: [OutputDeviceOption] {
        CoreAudioDevice.outputDevices.map {
            OutputDeviceOption(uid: CoreAudioDevice.uid(of: $0), name: CoreAudioDevice.name(of: $0),
                               channels: CoreAudioDevice.outputChannelCount(of: $0))
        }
        .filter { !$0.uid.isEmpty && !$0.name.hasPrefix("Network Audio") }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The system default's name, for "System default — …".
    var systemDefaultOutputName: String { CoreAudioDevice.name(of: CoreAudioDevice.defaultOutputID) }

    func chooseOutputDevice(_ option: OutputDeviceOption?) {
        outputDeviceChosenName = option?.name ?? ""
        outputDeviceUID = option?.uid
        append(log: option.map { "Output: \($0.name), whatever the Mac's own output setting." }
                    ?? "Output: the system default (\(systemDefaultOutputName)), following the Mac's setting.")
    }

    /// Audio MIDI Setup, where macOS makes a Multi-Output or aggregate device.
    func openAudioMIDISetup() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
    }

    override func platformTick() {
        if tickCount % 4 == 0 { audio.probeInserts() }
        refreshReadouts()
        // The Detailed figures' beat: a notification the AppKit figure views follow, so nothing
        // in SwiftUI is invalidated for it.
        if detailed, isPlayingAny, metersActive { FigureBeat.post() }
    }

    override func refreshInsertStatus() {
        let live = (0..<slotLive.count).map { audio.isSlotLive($0) }
        if live != slotLive { slotLive = live }

        let failed = audio.slots.map(\.failure)
        if failed != slotFailure { slotFailure = failed }

        let refused = (0..<slotRefused.count).map { audio.isSlotRefused($0) }
        if refused != slotRefused {
            for (slot, isRefused) in refused.enumerated() where isRefused && !slotRefused[slot] {
                let name = slotInfo[slot]?.name ?? "plugin"
                append(log: "Insert \(slot + 1) (\(name)) is held out of circuit: it will not "
                     + "take a \(busChannels)-channel bus. Narrow the output bus, or use a "
                     + "plugin that handles \(busChannels) channels — it is not being applied "
                     + "to part of the bus, because that would not be what you are hearing.")
            }
            slotRefused = refused
        }
    }

    override func makeWebReceiver(for stream: StreamDescription, latencyMs: Double) -> StreamReceiver {
        let r = WebStreamReceiver(stream: stream, latencyMs: latencyMs)
        r.onLog = { [weak self] text in self?.append(log: text) }
        return r
    }

    override func receiverNameChanged(_ name: String) { send?.grabberRenamed(name) }

    override func setBusy(_ busy: Bool) { self.busy.set(busy) }

    /// In a DAW, Bundle.main is the DAW: the plugin's own bundle has the version (the log said
    /// "7.71", REAPER's).
    override func appVersion() -> String {
        let bundle = hostMode ? (Bundle(identifier: PluginBridge.bundleID) ?? .main) : .main
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var appearance: Appearance { didSet { persist("appearance", appearance.rawValue) } }

    /// Whether the dry/wet slider is shown on an insert. Off by default: it is the least
    /// reached-for control in the strip and the widest thing in the row, and Δ answers the
    /// question it is usually opened for. The balance itself is unaffected — hiding the
    /// slider does not reset it.
    var showInsertMix: Bool { didSet { persist("showInsertMix", showInsertMix) } }
    /// The 30-second output history under the meters. On unless turned off: it costs nothing
    /// measurable, and a dropout you missed is what it is for.
    var showLevelHistory: Bool {
        didSet {
            persist("showLevelHistory", showLevelHistory)
            if !showLevelHistory { levelHistory.clear() }
        }
    }
    let levelHistory = LevelHistoryStore()


    /// On for a fresh install; a choice to turn it off is kept.
    static func storedShowLevelHistory(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: "showLevelHistory") as? Bool ?? true
    }
    private var faultsSeen: UInt64 = 0


    /// Which sections of the compact window are unfolded. Each is independent and each
    /// remembers itself, so the window is whatever the person watching it needs rather than one
    /// designer's idea of a mini player.
    ///
    /// The defaults are loudness and inserts folded, listening open: what is playing stays
    /// visible and everything else is one summary line until it is wanted.
    /// A loudness reading pinned beside the compact window's peak figure, at the same size, so
    /// the number you are judging by is the one you can read from across the room. `.none` pins
    /// nothing. Integrated by default: it is the figure a delivery specification means.
    var pinnedLoudness: LoudnessPin {
        didSet { persist("pinnedLoudness", pinnedLoudness.rawValue) }
    }

    var loudnessOpen: Bool { didSet { persist("loudnessOpen", loudnessOpen) } }
    var insertsOpen: Bool { didSet { persist("insertsOpen", insertsOpen) } }
    // The full window's panel folds on its own, apart from the compact window's:
    // Inserts folded to start with, so the output below has the room. **The output never
    // folds** — in either window, or the Sender — it is what the app is for.
    var panelInsertsOpen: Bool { didSet { persist("panelInsertsOpen", panelInsertsOpen) } }
    var streamsOpen: Bool { didSet { persist("streamsOpen", streamsOpen) } }
    var showPanel: Bool { didSet { persist("showPanel", showPanel) } }

    /// The source sidebar, shown or hidden. Full window only.
    var showSourceBar: Bool { didSet { persist("showSourceBar", showSourceBar) } }

    // MARK: Send: Network Audio Sender's own state and views, inside the Grabber.

    /// This Mac's audio, sent to other receivers. Made when the app starts; runs nothing until
    /// something is sent or offered (`GrabberSend`). Not in the Audio Unit.
    private(set) var send: GrabberSend?
    /// The Send section along the bottom of the full window: open (the default) or folded.
    var sendOpen: Bool { didSet { persist("sendOpen", sendOpen) } }
    /// Its height when open, set by dragging its handle; kept between launches.
    var sendHeight: Double { didSet { persist("sendHeight", sendHeight) } }
    /// Which tab the Receive / Send window and the compact window show: 0 Receive, 1 Send.
    var connectTab = 0
    /// Where the other end is, in the connection guide: 0 on this network, 1 somewhere else.
    var connectWhere = 0
    /// How, when somewhere else (`RemoteMethod`): the Remote link unless another was chosen.
    var remoteMethod: Int { didSet { persist("remoteMethod", remoteMethod) } }
    var compactTab: Int { didSet { persist("compactTab", compactTab) } }


    /// RENDER HARNESS only: a Send that was never started.
    func attachPreviewSend(_ s: GrabberSend?) { send = s; syncSendTheme() }

    /// Send takes the Grabber's colours.
    func syncSendTheme() {
        send?.applyTheme(enabled: themeEnabled, primary: themePrimaryHex, secondary: themeSecondaryHex)
    }
    /// MOCKUPS only (`--mockup-send`): "window", "panel", "panel-open", "strip", "strip-open".
    /// Never set in the app.
    var previewSendLayout: String?
    /// Sidebar or row, for the full window. The Audio Unit always uses the row (narrower).
    var sourceFilterPlacementSetting: SourceFilterPlacement {
        didSet { persist("sourceFilterPlacement", sourceFilterPlacementSetting.rawValue) }
    }
    var sourceFilterPlacement: SourceFilterPlacement {
        AudioOutput.hostMode ? .row : sourceFilterPlacementSetting
    }


    var viewMode: ViewMode { didSet { persist("viewMode", viewMode.rawValue) } }

    /// Whether Settings has taken over the stream list. Lives here rather than in a view so that
    /// both windows and the ⌘, menu item drive the same thing; not persisted, because an app
    /// that reopens into its own settings is an app that has lost its place.
    var showSettings = false

    // Accent theming. Independent of light/dark: the appearance still decides the window's
    // shading, this only re-tints what the shading is accenting. See `Theme.swift` for which
    // colours are deliberately left alone.
    var themeEnabled: Bool { didSet { persist("themeEnabled", themeEnabled); syncSendTheme() } }
    var themePrimaryHex: String { didSet { persist("themePrimaryHex", themePrimaryHex); syncSendTheme() } }
    var themeSecondaryHex: String { didSet { persist("themeSecondaryHex", themeSecondaryHex); syncSendTheme() } }

    /// The look that goes with the scheme: REAPER's for Rea-Theme Default, the app's own otherwise.
    var skin: Skin { Skin.for(enabled: themeEnabled, primary: themePrimaryHex, secondary: themeSecondaryHex) }

    /// How strongly the primary colour washes the window's surfaces. Deliberately small: the
    /// point is a tinted ground, not a painted one, so the text hierarchy keeps the contrast it
    /// has in the untinted app. Dark needs more because a wash over near-black shows less.
    private static let washLight = 0.13
    private static let washDark = 0.22

    /// The window wash. `Color.clear` when theming is off, which leaves the system background
    /// showing exactly as it did before.
    ///
    /// Applied as a translucent layer rather than a flat colour on purpose — every
    /// `Color.primary.opacity(…)` fill in the app then keeps working unchanged, darkening in
    /// light mode and lightening in dark mode over whatever ground this puts down.
    func surfaceWash(_ scheme: ColorScheme) -> Color {
        guard themeEnabled, let primary = Color(hex: themePrimaryHex) else { return .clear }
        // A skin with its own ground paints it outright.
        if let window = skin.style.window { return Color(nsColor: window) }
        return primary.opacity(scheme == .dark ? Self.washDark : Self.washLight)
    }

    /// Anything meaning *active*: a stream being listened to, its stop button, the ACTIVE
    /// filter, the panel toggle, MONO, the sliders. Falls back to the system accent colour.
    var tintActive: Color {
        themeEnabled ? (ThemeColors.active(hex: themeSecondaryHex) ?? .accentColor) : .accentColor
    }

    /// The same colour, safe to draw as an icon or a label rather than as a low-opacity fill.
    /// Already legible either way — see `ThemeChoice.active(on:)`, which this matches.
    func tintActive(on scheme: ColorScheme) -> Color { tintActive }

    /// Solo. Not themeable: it is yellow in every DAW there is, and it has to stay distinct
    /// from the active colour, which is themeable.
    var tintSolo: Color { .yellow }
    /// Solo's yellow as **text**: the same in dark mode, darkened in light, where a yellow
    /// "SOLO" on a light window could not be read. Fills keep `tintSolo`: yellow with black on
    /// it is the convention and reads fine in either appearance.
    var tintSoloText: Color { ThemeColors.solo }

    func applyTheme(_ preset: ThemePreset) {
        themePrimaryHex = preset.primary
        themeSecondaryHex = preset.secondary
        themeEnabled = true
    }


    /// Refresh rate of the level meters. The largest single cost in the app, because each redraw
    /// schedules a Core Animation commit and the window's view tree is walked on every one:
    /// 60 fps measures 15.4 % of a core against 4.3 % at 30. 30 is the default because it
    /// is where the curve flattens and it still reads as continuous.
    var meterHz: Int {
        didSet {
            let clamped = min(60, max(15, meterHz))
            if clamped != meterHz { meterHz = clamped; return }
            persist("meterHz", meterHz)
        }
    }

    var meterRate: Double { Double(meterHz) }


    /// Formatted readouts, on their own observable object so a change reaches three labels
    /// instead of every view in the window.
    let readouts = Readouts()

    // MARK: - Window geometry

    /// Which mode the window has been shaped to, held here so it outlives the view that does
    /// the shaping. Not `@Published`: it is bookkeeping, and publishing it would re-render the
    /// window every time it was written. Not persisted: it describes this session's window,
    /// not a preference.
    let windowShape = WindowShapeMemory()

    /// Each view mode remembers the size it was left at, so switching back and forth does not
    /// flatten a window the user has deliberately sized.
    func windowSize(for mode: ViewMode) -> CGSize {
        let width = defaults.object(forKey: "window.\(mode.rawValue).w") as? Double
        let height = defaults.object(forKey: "window.\(mode.rawValue).h") as? Double
        switch mode {
        case .full:    return CGSize(width: width ?? 1120, height: height ?? 700)
        case .compact: return CGSize(width: width ?? 380, height: height ?? 560)
        }
    }

    func rememberWindowSize(_ mode: ViewMode, _ size: CGSize) {
        guard size.width > 100, size.height > 100 else { return }
        defaults.set(Double(size.width), forKey: "window.\(mode.rawValue).w")
        defaults.set(Double(size.height), forKey: "window.\(mode.rawValue).h")
    }


    // Plugins
    var availablePlugins: [PluginInfo] = []
    var slotInfo: [PluginInfo?] = [nil, nil, nil]
    var slotBypassed: [Bool] = [false, false, false]

    /// Dry/wet balance per insert: 0 is the untouched signal, 1 the plugin alone.
    var slotMix: [Double] = [1, 1, 1]

    /// Which insert, if any, is being monitored as a difference. One at a time, like solo, and
    /// not persisted: delta is something you do while listening, not a setting.
    var deltaSlot: Int?

    /// Whether each slot's plugin is instantiated and in the graph. A slot has its name the
    /// instant it is chosen but its node a moment later, and Δ needs the node.
    var slotLive: [Bool] = [false, false, false]

    /// Slots whose plugin will not take the current bus width and is therefore held out of the
    /// chain. Published because it has to be *visible*: a plugin silently not processing is
    /// exactly the situation the capability check exists to prevent, and a check that only
    /// writes to a diagnostic log recreates it.
    var slotRefused: [Bool] = [false, false, false]

    /// Slot arrays, read by index from views.
    ///
    /// Bounds-checked because a view can outlive the state it was built from: three crash
    /// reports landed inside `InsertSlotView` reading `slotInfo[slot]`, and while the index
    /// should never be out of range, a monitor tool falling over while someone is listening is
    /// not the place to find out that it was.
    func slotInfo(_ slot: Int) -> PluginInfo? {
        slotInfo.indices.contains(slot) ? slotInfo[slot] : nil
    }

    func slotIsBypassed(_ slot: Int) -> Bool {
        slotBypassed.indices.contains(slot) && slotBypassed[slot]
    }

    func slotIsLive(_ slot: Int) -> Bool {
        slotLive.indices.contains(slot) && slotLive[slot]
    }

    func slotIsRefused(_ slot: Int) -> Bool {
        slotRefused.indices.contains(slot) && slotRefused[slot]
    }

    /// Which settings pane is showing. On the state rather than in the view because the view is
    /// rebuilt when the window mode changes, and being thrown back to the first pane for having
    /// switched to the compact window — from inside the pane that switches it — is absurd.
    var settingsPane: String = "playout"


    /// Help → Connect to a Sender over VBAN…: the window opens the guide, through the same
    /// trust notice as its own button, and clears this.
    var connectGuideRequested = false
    /// The Sources guide's "SDP Address…": the window opens the add-by-hand sheet, and clears this.
    var addStreamRequested = false


    /// The same, as lines, for the drawer under the list and the self-test.
    var log: [String] {
        activity.entries.suffix(300).map { "\(ActivityLogView.time($0.date))  \($0.text)" }
    }


    private let audio: AudioOutput
    /// For the Audio Unit's render call, which must not go through this observable object.
    var audioOutput: AudioOutput { audio }

    /// For `--selftest --flipto`: where the engine really is rendering, against where the system
    /// says output should go, and whether it is still pulling audio at all.
    var outputDiagnostic: (engineDevice: String, defaultDevice: String, renderCalls: UInt64,
                           engineRunning: Bool, restarts: Int) {
        (CoreAudioDevice.name(of: audio.engineDeviceID),
         CoreAudioDevice.name(of: CoreAudioDevice.defaultOutputID),
         audio.renderCalls, audio.engineIsRunning, audio.restarts)
    }

    // MARK: - Preferences carried over from the old bundle identifier

    /// The app was renamed in 0.5, and the bundle identifier changed with it. macOS keys the
    /// preferences domain off the identifier, so without this every setting — interface,
    /// favourites, insert plugin and its state, loudness targets, window sizes — would have
    /// reset on first launch. This is the one place the previous name still appears, and it has
    /// to: it is the name of a domain that already exists on disk.
    ///
    /// **Local Network permission cannot be carried over**, because that is keyed off the
    /// identifier by the system rather than by us. It has to be granted again, and until it is,
    /// RAVENNA and Dante discovery return nothing while SAP keeps working — which looks exactly
    /// like a fault in the app.
    private static let legacyDomain = "app.earshot.monitor"

    private static func carryOverLegacyDefaults(into defaults: UserDefaults) {
        // Never for the render and self-test harnesses: they pass a throwaway suite precisely so
        // they cannot see or touch the real settings.
        guard defaults === UserDefaults.standard,
              !defaults.bool(forKey: "carriedOverLegacyDefaults") else { return }
        defaults.set(true, forKey: "carriedOverLegacyDefaults")

        guard let legacy = UserDefaults.standard.persistentDomain(forName: legacyDomain),
              !legacy.isEmpty else { return }
        // Anything already set under the new identifier wins; this only fills in blanks.
        for (key, value) in legacy where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }


    // MARK: - Internet streams

    /// Stations added by address, saved as what the probe learnt, so they are listed at launch
    /// without connecting to anything — nothing is fetched until one is played.
    private var savedWebStreams: [WebStreamInfo] {
        get { (defaults.array(forKey: "webStreams") as? [[String: Any]] ?? []).compactMap(WebStreamInfo.init) }
        set { defaults.set(newValue.map(\.asDictionary), forKey: "webStreams") }
    }

    /// The probe in flight, if any, kept alive until it answers.
    private var webProbe: WebStreamProbe?

    /// Adds an internet stream by its address: probes it for its name and format, then lists it.
    /// `completion` gets an error to show, or nil once it is in the list.
    func addWebStream(_ text: String, completion: @escaping (String?) -> Void) {
        guard webStreamsEnabled else {
            completion("Turn on Internet streams in Settings → Discovery first — it is in beta.")
            return
        }
        let probe = WebStreamProbe()
        webProbe = probe
        probe.run(text) { [weak self] result in
            guard let self else { return }
            self.webProbe = nil
            switch result {
            case .failure(let f):
                completion(f.message)
            case .success(let info):
                var saved = self.savedWebStreams
                saved.removeAll { $0.url == info.url }
                saved.append(info)
                self.savedWebStreams = saved
                self.ingest(info.description, deletion: false)
                self.append(log: "Added “\(info.name)” — \(info.codec), \(info.channels) ch, "
                          + String(format: "%.4g kHz", Double(info.sampleRate) / 1000) + ", from \(info.url).")
                completion(nil)
            }
        }
    }

    func cancelWebProbe() { webProbe = nil }

    /// Takes a station off the list for good.
    func removeWebStream(_ id: String) {
        guard let stream = streams.first(where: { $0.id == id })?.description, stream.source == .web else { return }
        unsubscribe(id, reason: "it was removed")
        savedWebStreams = savedWebStreams.filter { $0.description.id != id }
        streams.removeAll { $0.id == id }
        append(log: "Removed “\(stream.name)”.")
    }

    /// Takes a stream added from pasted SDP off the list.
    /// Nothing announces it, so nothing brings it back; it is not saved between launches.
    func removeManualStream(_ id: String) {
        guard let stream = streams.first(where: { $0.id == id })?.description, stream.source == .manual else { return }
        unsubscribe(id, reason: "it was removed")
        streams.removeAll { $0.id == id }
        lastSeenAt[id] = nil
        health[id] = nil
        openStreamIDs.remove(id)
        append(log: "Removed “\(stream.name)”.")
    }

    override func restoreWebStreams() {
        guard webStreamsEnabled else { return }
        for info in savedWebStreams { ingest(info.description, deletion: false) }
    }


    override func refreshNowPlaying() {
        var titles: [String: String] = [:]
        for (id, r) in receivers {
            if let web = r as? WebStreamReceiver, let title = web.nowPlaying { titles[id] = title }
        }
        if titles != nowPlaying { nowPlaying = titles }
    }


    // MARK: - Plugins

    func setPlugin(slot: Int, to info: PluginInfo?) {
        guard slotInfo.indices.contains(slot) else { return }
        // The graph is rebuilt around the new plugin, and a difference against a plugin that
        // has been replaced means nothing anyway.
        if deltaSlot == slot { deltaSlot = nil }
        slotInfo[slot] = info
        audio.setPlugin(slot: slot, to: info)
        append(log: info.map { "Insert \(slot + 1): \($0.name)." } ?? "Insert \(slot + 1) cleared.")
    }

    func toggleBypass(slot: Int) {
        guard slotBypassed.indices.contains(slot) else { return }
        slotBypassed[slot].toggle()
        // A bypassed plugin is out of circuit, so the difference it is making is nothing.
        if slotBypassed[slot], deltaSlot == slot { setDelta(slot: slot, false) }
        audio.setBypass(slot: slot, slotBypassed[slot])
    }

    /// Monitor only what this insert changed — `wet − dry`, Reaper's delta solo.
    func toggleDelta(slot: Int) {
        setDelta(slot: slot, deltaSlot != slot)
    }

    func setDelta(slot: Int, _ on: Bool) {
        guard slotInfo.indices.contains(slot) else { return }
        guard on else {
            guard deltaSlot == slot else { return }
            audio.setDelta(slot: slot, false)
            deltaSlot = nil
            append(log: "Insert \(slot + 1): delta off.")
            return
        }
        guard slotInfo[slot] != nil, !slotBypassed[slot], audio.isSlotLive(slot) else { return }

        let previous = deltaSlot
        guard let frames = audio.setDelta(slot: slot, true) else { return }
        deltaSlot = slot
        let name = slotInfo[slot]?.name ?? "plugin"
        let ms = Double(frames) / max(1, outputRate) * 1000

        if let previous, previous != slot {
            append(log: "Insert \(previous + 1): delta off — one insert at a time.")
        }
        if frames > 0 {
            append(log: String(format: "Insert %d (%@): delta on — you are hearing wet − dry, "
                             + "with the dry path delayed %.1f ms to match the plugin.",
                               slot + 1, name, ms))
        } else {
            // Worth saying every time rather than once: it is the difference between "this
            // plugin does nothing here" and "this plugin lies about its latency", and only the
            // person listening can tell which.
            append(log: "Insert \(slot + 1) (\(name)): delta on — you are hearing wet − dry. "
                 + "The plugin reports no latency, so nothing is being compensated; if it has "
                 + "any, the difference will comb-filter rather than null.")
        }
    }

    /// Which slots have already had their latency pointed out, so the log says it once.
    private var warnedInsertLatency: Set<Int> = []

    func setSlotMix(_ slot: Int, _ value: Double) {
        guard slotMix.indices.contains(slot) else { return }
        slotMix[slot] = min(1, max(0, value))
        audio.setMix(slot: slot, slotMix[slot])

        // A blend across a latent plugin used to comb-filter, because nothing delayed the dry
        // path to match it. It is now delayed (the delay line, doing the half of its job
        // that is not the subtraction), so this says what is happening rather than warning —
        // once per slot, because the number is worth knowing and the repetition is not.
        let latency = audio.slots[slot].latencySeconds
        guard slotMix[slot] > 0.001, slotMix[slot] < 0.999, latency > 0.0005,
              !warnedInsertLatency.contains(slot) else { return }
        warnedInsertLatency.insert(slot)
        let name = slotInfo[slot]?.name ?? "plugin"
        let ms = String(format: "%.1f", latency * 1000)
        append(log: "Insert \(slot + 1) (\(name)) reports \(ms) ms of latency; the dry path is "
             + "delayed to match, so the blend sums instead of comb-filtering. A plugin that "
             + "under-reports its latency will still comb — BYP is the only path with no "
             + "insert latency in it.")
    }

    /// Latency each loaded insert reports, in milliseconds — what the dry path is aligned by,
    /// and what the tooltips quote. Read live rather than published: it is only asked for while
    /// a tooltip is being built, and a plugin can change it (a linear-phase mode being switched
    /// on in its own window) without telling anyone.
    var slotLatencyMs: [Double] {
        audio.slots.map { $0.latencySeconds * 1000 }
    }

    func showPluginUI(slot: Int) { audio.slots[slot].showUI() }

    /// Level into or out of an insert's plugin, for its in → out meter.
    func slotLevel(_ slot: Int, output wantOutput: Bool) -> Float {
        audio.insertLevel(slot: slot, output: wantOutput)
    }

    /// Why each slot's plugin stopped by itself, if it did — its process ended.
    var slotFailure: [String?] = [nil, nil, nil]

    func reloadPlugin(slot: Int) {
        append(log: "Insert \(slot + 1): reloading \(slotInfo[slot]?.name ?? "plugin").")
        audio.reloadPlugin(slot: slot)
    }

    private func savePlugins() {
        for (i, info) in slotInfo.enumerated() {
            defaults.set(info?.id, forKey: "slot\(i).id")
            defaults.set(audio.slots[i].savedState, forKey: "slot\(i).state")
            defaults.set(slotBypassed[i], forKey: "slot\(i).bypass")
            defaults.set(slotMix[i], forKey: "slot\(i).mix")
        }
    }

    /// Idempotent: the plugin list arrives in two stages (see `start`), so this runs twice and
    /// must not reload a slot it has already filled.
    private func restorePlugins() {
        for i in 0..<slotInfo.count where slotInfo[i] == nil {
            guard let id = defaults.string(forKey: "slot\(i).id"),
                  let info = availablePlugins.first(where: { $0.id == id }) else { continue }
            slotBypassed[i] = defaults.bool(forKey: "slot\(i).bypass")
            slotMix[i] = defaults.object(forKey: "slot\(i).mix") as? Double ?? 1
            audio.setBypass(slot: i, slotBypassed[i])
            audio.setMix(slot: i, slotMix[i])
            slotInfo[i] = info
            let state = defaults.data(forKey: "slot\(i).state")
            audio.slots[i].load(info) { [weak self] error in
                if let error { self?.append(log: error); return }
                if let state { self?.audio.slots[i].restoreState(state) }
                self?.audio.rebuildChain()
            }
        }
    }


    /// The pinned reading, or nil when nothing is pinned.
    var pinnedReading: LoudnessReading? {
        switch pinnedLoudness {
        case .none:       return nil
        case .shortTerm:  return readouts.shortTerm
        case .window:     return readouts.window
        case .integrated: return readouts.integrated
        }
    }


    /// One quarter-second of history: the loudest bar now, and whether any stream's audio
    /// stopped arriving or ran out since the last sample.
    private func sampleHistory() {
        var peak: Float = 0
        for c in 0..<busChannels { peak = max(peak, outputPeak(c)) }
        let faults = receivers.values.reduce(UInt64(0)) { $0 + UInt64($1.gaps) + $1.underruns }
        let fault = faults > faultsSeen && faultsSeen > 0
        faultsSeen = faults
        levelHistory.push(metersActive ? peak : 0, fault: fault)
    }

}

/// The Mac's monitor bus, as the engine sees it.
extension AudioOutput: MonitorOutput {}
