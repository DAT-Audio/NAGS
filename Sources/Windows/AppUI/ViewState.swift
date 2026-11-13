import Foundation
import NetworkAudioEngine
import GrabberCore

/// What the Mac keeps on `AppState` for its windows rather than in the engine — the layout, the
/// folds, the look, the meter rate — kept under **the Mac's own keys**, so the two read the same
/// way and a setting means the same thing in both.
final class ViewState {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        showInsertMix = bool("showInsertMix", true)
        showLevelHistory = bool("showLevelHistory", true)
        pinnedLoudness = defaults.string(forKey: "pinnedLoudness").flatMap(LoudnessPin.init(rawValue:)) ?? .integrated
        loudnessOpen = bool("loudnessOpen", false)
        insertsOpen = bool("insertsOpen", false)
        panelInsertsOpen = bool("panelInsertsOpen", false)
        streamsOpen = bool("streamsOpen", true)
        showPanel = bool("showPanel", true)
        showSourceBar = bool("showSourceBar", true)
        sendOpen = bool("sendOpen", true)
        compactTab = defaults.integer(forKey: "compactTab")
        sourceFilterRow = defaults.string(forKey: "sourceFilterPlacement") == "row"
        panelWidth = defaults.object(forKey: "win.panelWidth") as? Double ?? PanelLayout.width
        sidebarWidth = defaults.object(forKey: "win.sidebarWidth") as? Double ?? 164
        streamWidth = defaults.object(forKey: "win.streamWidth") as? Double ?? 0
        viewMode = ViewMode(rawValue: defaults.string(forKey: "viewMode") ?? "") ?? .full
        meterHz = defaults.object(forKey: "meterHz") as? Int ?? 30
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .dark
        // The Mac's `ThemeChoice.stored`: never set means the system's colours, with Graphite &
        // Amber waiting for when a scheme is switched on.
        if let enabled = defaults.object(forKey: "themeEnabled") as? Bool {
            themeEnabled = enabled
            themePrimaryHex = defaults.string(forKey: "themePrimaryHex") ?? ThemePreset.previousFallback.primary
            themeSecondaryHex = defaults.string(forKey: "themeSecondaryHex") ?? ThemePreset.previousFallback.secondary
        } else {
            themeEnabled = false
            themePrimaryHex = defaults.string(forKey: "themePrimaryHex") ?? ThemePreset.standard.primary
            themeSecondaryHex = defaults.string(forKey: "themeSecondaryHex") ?? ThemePreset.standard.secondary
        }
    }

    var showInsertMix: Bool { didSet { defaults.set(showInsertMix, forKey: "showInsertMix") } }
    var showLevelHistory: Bool {
        didSet { defaults.set(showLevelHistory, forKey: "showLevelHistory"); if !showLevelHistory { history.clear() } }
    }
    var pinnedLoudness: LoudnessPin { didSet { defaults.set(pinnedLoudness.rawValue, forKey: "pinnedLoudness") } }
    var loudnessOpen: Bool { didSet { defaults.set(loudnessOpen, forKey: "loudnessOpen") } }
    var insertsOpen: Bool { didSet { defaults.set(insertsOpen, forKey: "insertsOpen") } }
    var panelInsertsOpen: Bool { didSet { defaults.set(panelInsertsOpen, forKey: "panelInsertsOpen") } }
    var streamsOpen: Bool { didSet { defaults.set(streamsOpen, forKey: "streamsOpen") } }
    var showPanel: Bool { didSet { defaults.set(showPanel, forKey: "showPanel") } }
    var showSourceBar: Bool { didSet { defaults.set(showSourceBar, forKey: "showSourceBar") } }
    var sendOpen: Bool { didSet { defaults.set(sendOpen, forKey: "sendOpen") } }
    var compactTab: Int { didSet { defaults.set(compactTab, forKey: "compactTab") } }
    var sourceFilterRow: Bool { didSet { defaults.set(sourceFilterRow ? "row" : "sidebar", forKey: "sourceFilterPlacement") } }
    /// Widths dragged by hand, so the Stream column is not squeezed too narrow in the Detailed
    /// view. `streamWidth` 0 means "whatever is left"; above it, the signal
    /// panel and then the sidebar give way to it, down to their narrowest.
    var panelWidth: Double { didSet { defaults.set(panelWidth, forKey: "win.panelWidth") } }
    var sidebarWidth: Double { didSet { defaults.set(sidebarWidth, forKey: "win.sidebarWidth") } }
    var streamWidth: Double { didSet { defaults.set(streamWidth, forKey: "win.streamWidth") } }
    static let panelRange = 236.0...440.0
    static let sidebarRange = 140.0...280.0

    var viewMode: ViewMode { didSet { defaults.set(viewMode.rawValue, forKey: "viewMode") } }
    var meterHz: Int { didSet { defaults.set(meterHz, forKey: "meterHz") } }
    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    var themeEnabled: Bool { didSet { defaults.set(themeEnabled, forKey: "themeEnabled") } }
    var themePrimaryHex: String { didSet { defaults.set(themePrimaryHex, forKey: "themePrimaryHex") } }
    var themeSecondaryHex: String { didSet { defaults.set(themeSecondaryHex, forKey: "themeSecondaryHex") } }

    /// Not remembered, as on the Mac: an app that reopens into its own settings has lost its place.
    var showSettings = false
    var settingsPane: SettingsPane = .playout
    var showLog = false
    var showAvailable = false

    var skin: Skin { Skin.forScheme(enabled: themeEnabled, primary: themePrimaryHex, secondary: themeSecondaryHex) }

    /// The preset these colours are, if any.
    var preset: ThemePreset? {
        (ThemePreset.all + ThemePreset.looks).first {
            $0.primary.caseInsensitiveCompare(themePrimaryHex) == .orderedSame
                && $0.secondary.caseInsensitiveCompare(themeSecondaryHex) == .orderedSame
        }
    }

    func windowSize(for mode: ViewMode) -> (Double, Double) {
        let w = defaults.object(forKey: "window.\(mode.rawValue).w") as? Double
        let h = defaults.object(forKey: "window.\(mode.rawValue).h") as? Double
        switch mode {
        case .full: return (w ?? 1280, h ?? 740)
        case .compact: return (w ?? 380, h ?? 600)
        }
    }

    func rememberWindowSize(_ mode: ViewMode, _ w: Double, _ h: Double) {
        guard w > 100, h > 100 else { return }
        defaults.set(w, forKey: "window.\(mode.rawValue).w")
        defaults.set(h, forKey: "window.\(mode.rawValue).h")
    }

    // MARK: - Readouts (the Mac's `Readouts`, formatted on the tick)

    let readouts = Readouts()
    let history = LevelHistory()
    private var faultsSeen: UInt64 = 0

    /// Four times a second, from the window's timer.
    func refresh(from g: WindowsGrabber) {
        func reading(_ value: Double, _ target: Double, provisional: Bool = false) -> LoudnessReading {
            guard value.isFinite else { return LoudnessReading() }
            let delta = value - target
            let band: LoudnessReading.Band = abs(delta) < 1 ? .onTarget : (abs(delta) < 3 ? .near : .off)
            return LoudnessReading(value: String(format: "%.1f", value).replacingOccurrences(of: "-", with: "−"),
                                   delta: String(format: "%+.1f", delta).replacingOccurrences(of: "-", with: "−"),
                                   deviation: (delta * 10).rounded() / 10, band: band, provisional: provisional)
        }
        let peak = g.outputPeakMax
        readouts.outputMax = peak > 0.0002
            ? String(format: "%.1f", 20 * log10(Double(peak))).replacingOccurrences(of: "-", with: "−") : "−∞"
        readouts.shortTerm = reading(g.loudnessShortTerm, g.targetShortTerm)
        readouts.window = reading(g.loudnessWindowed, g.targetWindow)
        readouts.integrated = reading(g.loudnessIntegrated, g.targetIntegrated, provisional: g.loudnessBlocks < 30)

        if showLevelHistory {
            var level: Float = 0
            for c in 0..<g.busChannels { level = max(level, g.outputPeak(c)) }
            let faults = g.subscribed.reduce(UInt64(0)) { sum, id in
                let h = g.health[id]
                return sum + (h?.lost ?? 0) + (h?.underruns ?? 0)
            }
            let fault = faults > faultsSeen && faultsSeen > 0
            faultsSeen = faults
            history.push(g.metersActive ? level : 0, fault: fault)
        }
    }

    func pinnedReading() -> LoudnessReading? {
        switch pinnedLoudness {
        case .none: return nil
        case .shortTerm: return readouts.shortTerm
        case .window: return readouts.window
        case .integrated: return readouts.integrated
        }
    }
}

struct LoudnessReading: Equatable {
    var value = "−∞"
    var delta: String?
    var deviation: Double?
    var band: Band = .none
    var provisional = false
    enum Band { case none, onTarget, near, off }

    func colour(_ p: Palette) -> Colour {
        switch band {
        case .none: return p.secondary
        case .onTarget: return p.green
        case .near: return p.soloText
        case .off: return p.warning
        }
    }
}

final class Readouts {
    var outputMax = "−∞"
    var shortTerm = LoudnessReading()
    var window = LoudnessReading()
    var integrated = LoudnessReading()
}

/// The last 30 seconds of the output peak, a quarter-second a sample (the Mac's
/// `LevelHistoryStore`).
final class LevelHistory {
    static let capacity = 120
    private(set) var peaks = [Float](repeating: 0, count: capacity)
    private(set) var faults = [Bool](repeating: false, count: capacity)
    private(set) var head = 0
    private(set) var filled = 0

    func push(_ peak: Float, fault: Bool) {
        peaks[head] = peak
        faults[head] = fault
        head = (head + 1) % Self.capacity
        filled = min(Self.capacity, filled + 1)
    }

    func clear() {
        peaks = [Float](repeating: 0, count: Self.capacity)
        faults = [Bool](repeating: false, count: Self.capacity)
        head = 0; filled = 0
    }
}

/// Settings' panes, in the Mac's order and words.
enum SettingsPane: String, CaseIterable {
    case sources, playout, send, foldDown, discovery, output, inserts, loudness, theme, view, log, credits

    var title: String {
        switch self {
        case .sources: return "Sources"
        case .playout: return "Playout"
        case .send: return "Send"
        case .foldDown: return "Fold-down"
        case .discovery: return "Discovery"
        case .output: return "Output"
        case .inserts: return "Inserts"
        case .loudness: return "Loudness"
        case .theme: return "Theme"
        case .view: return "View"
        case .log: return "Log"
        case .credits: return "Credits"
        }
    }

    /// Segoe Fluent Icons code points.
    var glyph: String {
        switch self {
        case .sources: return "\u{E8FD}"
        case .playout: return "\u{E916}"
        case .send: return "\u{E8B6}"
        case .foldDown: return "\u{E8AB}"
        case .discovery: return "\u{EC05}"
        case .output: return "\u{E767}"
        case .inserts: return "\u{E9E9}"
        case .loudness: return "\u{E9D9}"
        case .theme: return "\u{E790}"
        case .view: return "\u{E737}"
        case .log: return "\u{E9F9}"
        case .credits: return "\u{E82D}"
        }
    }

    var subtitle: String {
        switch self {
        case .sources: return "Every kind of stream the Grabber can play, and how each arrives."
        case .playout: return "How much buffer sits between the network and the output, and when a quiet stream stops."
        case .send: return "This Grabber's own Send: its stream, resuming, and auto-stop."
        case .foldDown: return "What happens to 5.1 and 7.1 streams on a stereo monitor."
        case .discovery: return "Which announcements the app listens for."
        case .output: return "The device the monitor bus plays out to."
        case .inserts: return "VST3 plug-ins on the monitor bus, and where they are found."
        case .loudness: return "LUFS readings and the targets they are judged against."
        case .theme: return "Light, dark or the system's, and an optional colour scheme on top."
        case .view: return "Window layout, stream list density and meter refresh rate."
        case .log: return "What the app did, and why: requests, results and changes."
        case .credits: return "Trademarks, licences, and the specifications the app was written from."
        }
    }
}
