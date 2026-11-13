import Foundation
import WinSDK
import NetworkAudioEngine
import GrabberCore
import WindowsInserts

/// One plug-in as the menus list it.
struct PluginEntry: Equatable {
    let id: String
    let name: String
    let vendor: String
}

/// The three insert slots as the window sees them — the Mac's `slotInfo`, `slotBypassed`,
/// `slotMix`, `deltaSlot` and the rest of `AppState`'s plugin members — over the VST3 chain in
/// the output (`WASAPIOutput.inserts`) and the catalog of what is installed.
final class InsertsModel {
    let slotCount = 3
    private let catalog = VST3Catalog()
    private let chain: VST3InsertChain
    private let defaults: UserDefaults
    private let logLine: (String, ActivityLog.Kind) -> Void
    /// How wide what the inserts process is, and what that width is called in the words.
    let width: () -> Int
    let widthName: String
    let showMix: () -> Bool
    /// The rate it runs at, for saying a latency in milliseconds.
    var rate: () -> Double = { 48000 }
    private var restored = false
    private var refusedSeen: [Bool] = [false, false, false]
    private var failedSeen: [Bool] = [false, false, false]

    /// The Grabber's: its output's chain, on its monitor bus.
    convenience init(grabber: WindowsGrabber, showMix: @escaping () -> Bool) {
        self.init(chain: grabber.wasapi.inserts, defaults: grabber.defaults, width: { grabber.busChannels },
                  widthName: "output bus beside the meters", showMix: showMix) { [weak grabber] text, kind in grabber?.append(log: text, kind) }
        rate = { [weak grabber] in grabber?.outputRate ?? 48000 }
    }

    init(chain: VST3InsertChain, defaults: UserDefaults, width: @escaping () -> Int, widthName: String,
         showMix: @escaping () -> Bool, log: @escaping (String, ActivityLog.Kind) -> Void) {
        self.chain = chain
        self.defaults = defaults
        self.width = width
        self.widthName = widthName
        self.showMix = showMix
        logLine = log
    }

    private(set) var available: [PluginEntry] = []
    private(set) var scanning = false

    /// The list from the cache at once, then a fresh look in the background (in a separate
    /// process, so a plug-in that crashes while being looked at cannot take the app with it).
    func start() {
        publish(catalog.loadCached())
        restore()
        rescan(force: false)
        // `--test --insert "Name"`: a plug-in in slot 1 without a menu, for checking the panel.
        let args = CommandLine.arguments
        if args.contains("--test"), let i = args.firstIndex(of: "--insert"), i + 1 < args.count,
           let entry = available.first(where: { $0.name == args[i + 1] }) {
            setPlugin(0, entry)
        }
    }

    func rescan() { rescan(force: true) }

    private func rescan(force: Bool) {
        guard !scanning else { return }
        scanning = true
        let started = Date()
        catalog.scanInBackground(force: force) { [weak self] plugins in
            guard let self else { return }
            self.scanning = false
            self.publish(plugins)
            self.say(String(format: "Found %d VST3 effects in %.1f s.", plugins.count, Date().timeIntervalSince(started))
                                + (self.catalog.problems.isEmpty ? "" : " \(self.catalog.problems.count) plug-in file(s) were left out: they closed the scanner when looked at."))
            self.restore()
        }
    }

    /// What the menus offer, and the catalog entries behind them.
    private var infos: [String: VST3PluginInfo] = [:]

    private func say(_ text: String, _ kind: ActivityLog.Kind = .note) { logLine(text, kind) }

    private func publish(_ plugins: [VST3PluginInfo]) {
        guard !plugins.isEmpty || infos.isEmpty else { return }
        available = plugins.map { PluginEntry(id: $0.id, name: $0.name, vendor: $0.vendor) }
        infos = Dictionary(plugins.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// The slots as they were left, once. Saved slots carry where their plug-in was, so they load
    /// even before the scan has finished.
    private func restore() {
        guard !restored else { return }
        restored = true
        for problem in chain.restore(from: defaults, catalog: catalog) { say(problem, .warning) }
        for i in 0..<slotCount where chain.info(i) != nil {
            say("Insert \(i + 1): \(chain.info(i)!.name).")
        }
    }

    /// From the window's quarter-second beat: faults, restarts, and what changed for the log.
    func tick() {
        chain.poll()
        for i in 0..<slotCount {
            let refused = chain.isRefused(i)
            if refused && !refusedSeen[i] {
                let name = chain.info(i)?.name ?? "plug-in"
                let width = self.width()
                say("Insert \(i + 1) (\(name)) is held out of circuit: it will not take a \(width)-channel bus. Narrow the "
                               + "\(self.widthName), or use a plug-in that handles \(width) channels — it is not being applied to part of the bus, "
                               + "because that would not be what you are hearing.", .warning)
            }
            refusedSeen[i] = refused
            let failed = chain.failure(i) != nil
            if failed && !failedSeen[i] {
                say("Insert \(i + 1) (\(chain.info(i)?.name ?? "plug-in")) stopped responding and was taken out of the chain; "
                               + "the audio carries on without it. Reload it from the insert.", .failed)
            }
            failedSeen[i] = failed
        }
    }

    func shutdown() {
        chain.save(to: defaults)
        chain.closeAllEditors()
    }

    // MARK: - What the panel reads

    func info(_ slot: Int) -> PluginEntry? {
        chain.info(slot).map { PluginEntry(id: $0.id, name: $0.name, vendor: $0.vendor) }
    }
    func isLive(_ slot: Int) -> Bool { chain.isLive(slot) }
    func isBypassed(_ slot: Int) -> Bool { chain.isBypassed(slot) }
    func isRefused(_ slot: Int) -> Bool { chain.isRefused(slot) }
    func failure(_ slot: Int) -> String? { chain.failure(slot) }
    func latencyMs(_ slot: Int) -> Double { chain.latencyMs(slot) }
    func level(_ slot: Int, output: Bool) -> Float { chain.level(slot: slot, output: output) }
    var mix: [Double] { (0..<slotCount).map { chain.mix($0) } }
    var deltaSlot: Int? { chain.deltaSlot }

    // MARK: - What the panel does

    func setPlugin(_ slot: Int, _ entry: PluginEntry?) {
        let info = entry.flatMap { infos[$0.id] ?? catalog.plugin(id: $0.id) }
        if let problem = chain.load(slot: slot, info: info) {
            say(problem, .failed)
        } else {
            say(info.map { "Insert \(slot + 1): \($0.name)." } ?? "Insert \(slot + 1) cleared.")
        }
        chain.save(to: defaults)
    }

    func toggleBypass(_ slot: Int) {
        chain.setBypass(slot: slot, !chain.isBypassed(slot))
        chain.save(to: defaults)
    }

    func setMix(_ slot: Int, _ value: Double) {
        chain.setMix(slot: slot, value)
    }

    /// Monitor only what this insert changes — `wet − dry`, Reaper's delta solo.
    func toggleDelta(_ slot: Int) {
        let on = chain.deltaSlot != slot
        let previous = chain.deltaSlot
        guard let frames = chain.setDelta(slot: slot, on) else {
            if !on { say("Insert \(slot + 1): delta off.") }
            return
        }
        if let previous, previous != slot { say("Insert \(previous + 1): delta off — one insert at a time.") }
        let name = chain.info(slot)?.name ?? "plug-in"
        if frames > 0 {
            say(String(format: "Insert %d (%@): delta on — you are hearing wet − dry, with the dry path delayed %.1f ms to match the plug-in.",
                                       slot + 1, name, Double(frames) / max(1, rate()) * 1000))
        } else {
            say("Insert \(slot + 1) (\(name)): delta on — you are hearing wet − dry. The plug-in reports no latency, so nothing is "
                           + "being compensated; if it has any, the difference will comb-filter rather than null.")
        }
    }

    func reload(_ slot: Int) {
        say("Insert \(slot + 1): reloading \(chain.info(slot)?.name ?? "plug-in").")
        if let problem = chain.reload(slot: slot) { say(problem, .failed) }
    }

    func openEditor(_ slot: Int, parent: HWND?) {
        if !chain.openEditor(slot: slot, parent: parent) {
            say("Insert \(slot + 1) (\(chain.info(slot)?.name ?? "plug-in")) has no window of its own.", .warning)
        }
    }
}
