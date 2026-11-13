import SwiftUI
import AppKit

/// `NetworkAudioGrabber --render <folder>` draws the interface into PNGs, light and dark, using
/// synthetic streams. Development tooling: it makes the layout reviewable without a display
/// and gives a quick visual diff after a UI change.
///
/// It renders through a real off-screen `NSWindow` rather than `ImageRenderer`, because
/// `ImageRenderer` cannot draw AppKit-backed controls — sliders, menus and text fields all
/// come out blank.
enum RenderPreview {
    @MainActor
    static func run(arguments: [String]) {
        let outDir = value(for: "--render", in: arguments) ?? NSTemporaryDirectory()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        // A throwaway preferences suite, so rendering previews leaves the real app untouched.
        let suite = "app.networkaudiograbber.preview"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let state = AppState(defaults: UserDefaults(suiteName: suite) ?? .standard)
        // The app's own colours in the docs, chosen here rather than left to the default: the
        // default follows the system accent, which differs from Mac to Mac.
        state.applyTheme(ThemePreset.harness)
        populate(state)

        // `--render <dir> --matrix`: every colour scheme in both appearances, the full and the
        // compact window each at its floor, a common size and a large one — for checking that
        // nothing is cut off or crowded anywhere.
        // `--render <dir> --devices`: the output device in the header, Settings → Output, and the
        // Grabber's Send with its Source line.
        if arguments.contains("--devices") {
            let dark = NSAppearance(named: .darkAqua)
            capture(ContentView().environment(state), size: fullSize, appearance: dark, to: "\(outDir)/devices-main.png")
            state.settingsPane = SettingsPane.output.rawValue
            state.showSettings = true
            capture(ContentView().environment(state), size: fullSize, appearance: dark, to: "\(outDir)/devices-settings-output.png")
            state.showSettings = false
            state.viewMode = .compact
            capture(ContentView().environment(state), size: CGSize(width: compactSize.width, height: 640),
                    appearance: dark, to: "\(outDir)/devices-compact.png")
            UserDefaults.standard.removePersistentDomain(forName: suite)
            exit(0)
        }
        // `--render <dir> --open-edges`: three playing rows open, two of them side by side.
        if arguments.contains("--open-edges") {
            state.openStreamIDs = ["233.252.0.10:5004", "233.252.0.12:5004", "233.252.0.11:5004"]
            capture(ContentView().environment(state), size: CGSize(width: fullSize.width, height: 860),
                    appearance: NSAppearance(named: .darkAqua), to: "\(outDir)/open-edges-dark.png")
            state.appearance = .light
            capture(ContentView().environment(state), size: CGSize(width: fullSize.width, height: 860),
                    appearance: NSAppearance(named: .aqua), to: "\(outDir)/open-edges-light.png")
            state.appearance = .dark
            state.settingsPane = SettingsPane.loudness.rawValue
            state.showSettings = true
            capture(ContentView().environment(state), size: fullSize, appearance: NSAppearance(named: .darkAqua),
                    to: "\(outDir)/settings-loudness-dark.png")
            UserDefaults.standard.removePersistentDomain(forName: suite)
            exit(0)
        }
        if arguments.contains("--matrix") {
            renderMatrix(state, outDir: outDir)
            UserDefaults.standard.removePersistentDomain(forName: suite)
            exit(0)
        }

        // `--render <dir> --hold <seconds>` keeps the window up instead of shooting it, so the
        // idle cost of the interface can be sampled with `ps` — synthetic meters, no audio
        // device, no sound. The point is comparability against an older build of the same
        // harness, which is the only way to answer "has this got slower".
        // `--render <dir> --modeswitch` exercises the one thing a screenshot cannot: whether a
        // window mode remembers the size it was left at. Three fixes to that bug were reasoned
        // about and shipped without a way to check them, and all three were wrong, so
        // this drives the real `ContentView` through compact → full → compact and prints the
        // window's content size at each step.
        if arguments.contains("--modeswitch") {
            state.metersActive = true
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700),
                                  styleMask: [.titled, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            let host = NSHostingView(rootView: ContentView().environment(state))
            host.autoresizingMask = [.width, .height]
            window.contentView = host
            window.orderFrontRegardless()

            func settle(_ seconds: Double) {
                window.displayIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(seconds))
            }
            func size() -> CGSize { window.contentRect(forFrameRect: window.frame).size }
            func report(_ label: String) {
                let s = size()
                print(String(format: "%-34@ %4.0f x %4.0f", label as NSString, s.width, s.height))
            }

            settle(1.5)
            report("launched, full")

            state.viewMode = .compact
            settle(1.5)
            // Stand in for the user dragging the window: the same notification the shaper
            // listens for, so the path under test is the one that runs in the app.
            window.setContentSize(CGSize(width: 372, height: 604))
            NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification,
                                            object: window)
            settle(1.0)
            report("compact, resized by hand")
            let wanted = size()

            state.viewMode = .full
            settle(1.5)
            // And the other direction: drag the full window too, so both modes have a size a
            // user chose rather than one mode being tested against a default.
            window.setContentSize(CGSize(width: 1204, height: 648))
            NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification,
                                            object: window)
            settle(1.0)
            report("full, resized by hand")
            let wantedFull = size()

            state.viewMode = .compact
            settle(1.5)
            let gotCompact = size()
            report("compact again")

            state.viewMode = .full
            settle(1.5)
            let gotFull = size()
            report("full again")

            func matches(_ a: CGSize, _ b: CGSize) -> Bool {
                abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
            }
            let compactOK = matches(gotCompact, wanted)
            let fullOK = matches(gotFull, wantedFull)
            if !compactOK {
                print(String(format: "FAIL compact — expected %.0f x %.0f, got %.0f x %.0f",
                             wanted.width, wanted.height, gotCompact.width, gotCompact.height))
            }
            if !fullOK {
                print(String(format: "FAIL full — expected %.0f x %.0f, got %.0f x %.0f",
                             wantedFull.width, wantedFull.height, gotFull.width, gotFull.height))
            }
            if compactOK && fullOK {
                print("PASS — both modes came back the size they were left at")
            }
            exit(compactOK && fullOK ? 0 : 1)
        }

        if let seconds = value(for: "--hold", in: arguments).flatMap(Double.init) {
            // Meters run, or the measurement is of a window with every timer stopped.
            state.metersActive = true
            // **Nothing open unless asked.** The screenshots want a row open; a measurement
            // wants the same window the build being compared against would draw, and an open
            // row adds a channel meter block and a 4 Hz timeline that the older build had no
            // equivalent of. `--open` measures that cost deliberately instead of by accident.
            if !arguments.contains("--open") { state.openStreamIDs = [] }
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.fullSize),
                                  styleMask: [.titled, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.contentView = NSHostingView(
                rootView: ContentView().environment(state)
                    .frame(width: Self.fullSize.width, height: Self.fullSize.height))
            window.orderFrontRegardless()
            print("holding the window for \(Int(seconds)) s — pid \(getpid())")
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
            exit(0)
        }

        for (name, appearance) in [("ui-light", NSAppearance(named: .aqua)),
                                   ("ui-dark", NSAppearance(named: .darkAqua))] {
            capture(ContentView().environment(state),
                    size: Self.fullSize,
                    appearance: appearance,
                    to: "\(outDir)/\(name).png")
        }
        // The full window at its own floor: the output is the flexible section, so this is the
        // shot that shows whether its readings still fit beside the meters.
        capture(ContentView().environment(state),
                size: CGSize(width: ContentView.fullMinimumWidth(for: state),
                             height: SignalPanel.minimumWindowHeight(
                                slots: state.slotInfo.count,
                                showMix: state.showInsertMix,
                                showLoudness: state.showLoudness,
                                showHistory: state.showLevelHistory,
                                insertsOpen: state.panelInsertsOpen)),
                appearance: NSAppearance(named: .darkAqua),
                to: "\(outDir)/full-floor.png")
        layoutShots(state, outDir: outDir)
        state.detailLevel = .detailed
        capture(ContentView().environment(state),
                size: Self.fullSize,
                appearance: NSAppearance(named: .darkAqua),
                to: "\(outDir)/ui-detailed.png")
        state.detailLevel = .simple
        state.viewMode = .compact
        capture(ContentView().environment(state),
                size: Self.compactSize,
                appearance: NSAppearance(named: .aqua),
                to: "\(outDir)/ui-compact.png")
        state.insertsOpen = true            // the chain open, for the UI comparison
        capture(ContentView().environment(state),
                size: CGSize(width: Self.compactSize.width, height: 700),
                appearance: NSAppearance(named: .darkAqua),
                to: "\(outDir)/ui-compact-dark.png")
        state.insertsOpen = false
        // Compact with Detailed: each row adds where it comes from.
        state.detailLevel = .detailed
        capture(ContentView().environment(state),
                size: CGSize(width: Self.compactSize.width, height: 700),
                appearance: NSAppearance(named: .darkAqua),
                to: "\(outDir)/ui-compact-detailed-dark.png")
        state.detailLevel = .simple
        // The compact window at its floor and stretched: the horizontal output meter takes its
        // length from the window, and a meter that does not follow a resize is a bug that only
        // a second width can show.
        capture(ContentView().environment(state),
                size: CGSize(width: 320, height: 560),
                appearance: NSAppearance(named: .darkAqua),
                to: "\(outDir)/compact-narrow.png")
        capture(ContentView().environment(state),
                size: CGSize(width: 560, height: 560),
                appearance: NSAppearance(named: .darkAqua),
                to: "\(outDir)/compact-wide.png")
        // Laid out wide, then shrunk — the user's path, and the only one that catches a meter
        // whose length is a layout pass behind the window.
        captureAfterResize(ContentView().environment(state),
                           from: CGSize(width: 560, height: 560),
                           to: CGSize(width: 330, height: 560),
                           appearance: NSAppearance(named: .darkAqua),
                           to: "\(outDir)/compact-shrunk.png")
        // And the other direction, which fails the other way round: bars that stay short of
        // the window instead of running past it.
        captureAfterResize(ContentView().environment(state),
                           from: CGSize(width: 330, height: 560),
                           to: CGSize(width: 560, height: 560),
                           appearance: NSAppearance(named: .darkAqua),
                           to: "\(outDir)/compact-grown.png")
        state.viewMode = .full

        // Settings, in both layouts: it takes over the stream list in the full window and the
        // monitor in the compact one, so neither of the shots above shows it.
        state.showSettings = true
        capture(ContentView().environment(state),
                size: Self.fullSize,
                appearance: NSAppearance(named: .aqua),
                to: "\(outDir)/ui-settings.png")
        state.viewMode = .compact
        capture(ContentView().environment(state),
                size: Self.compactSize,
                appearance: NSAppearance(named: .aqua),
                to: "\(outDir)/ui-settings-compact.png")
        state.viewMode = .full

        // Discovery with VBAN on, for its footer and explainer. The harness never calls
        // `start()`, so switching it on here opens no port.
        state.settingsPane = SettingsPane.discovery.rawValue
        state.vbanEnabled = true
        capture(ContentView().environment(state),
                size: Self.fullSize,
                appearance: NSAppearance(named: .aqua),
                to: "\(outDir)/ui-settings-discovery.png")
        // Tall enough to reach the Network Audio Sender section under the VBAN addresses.
        capture(ContentView().environment(state),
                size: CGSize(width: Self.fullSize.width, height: Self.fullSize.height + 520),
                appearance: NSAppearance(named: .aqua),
                to: "\(outDir)/ui-settings-discovery-sender.png")
        // Playout with VBAN on: its own buffer row appears under the AES67 one.
        state.settingsPane = SettingsPane.playout.rawValue
        capture(ContentView().environment(state),
                size: Self.fullSize,
                appearance: NSAppearance(named: .aqua),
                to: "\(outDir)/ui-settings-playout-vban.png")
        state.vbanEnabled = false
        // The connect-to-a-Sender sheet, on its own.
        capture(ConnectToSender().environment(state),
                size: CGSize(width: 440, height: 700),
                appearance: NSAppearance(named: .aqua),
                to: "\(outDir)/ui-connect-sender.png")
        // The log.
        state.settingsPane = SettingsPane.log.rawValue
        capture(ContentView().environment(state),
                size: Self.fullSize,
                appearance: NSAppearance(named: .aqua),
                to: "\(outDir)/ui-settings-log.png")
        // The colour-scheme picker, System colour scheme first.
        state.settingsPane = SettingsPane.theme.rawValue
        capture(ContentView().environment(state),
                size: Self.fullSize,
                appearance: NSAppearance(named: .aqua),
                to: "\(outDir)/ui-settings-theme.png")
        state.settingsPane = SettingsPane.playout.rawValue
        state.showSettings = false

        // The panel at each bus width. The preview's engine is stereo — only the views read
        // `busChannels` — but that is what these are for: the layout at 8 and 16 channels is
        // where the labels and the insert row run out of room.
        state.slotRefused = [true, true, false]
        for width in [4, 6, 8, 16] {
            state.busChannels = width
            capture(ContentView().environment(state),
                    size: Self.fullSize,
                    appearance: NSAppearance(named: .darkAqua),
                    to: "\(outDir)/bus-\(width).png")
        }
        state.busChannels = 2
        state.slotRefused = [false, false, false]
        capture(ContentView().environment(state),
                size: Self.fullSize,
                appearance: NSAppearance(named: .darkAqua),
                to: "\(outDir)/bus-2.png")

        // The compact window's folding sections, in the three arrangements worth keeping: the
        // shipped defaults, everything folded, and everything open.
        state.viewMode = .compact
        state.loudnessOpen = false; state.insertsOpen = false; state.streamsOpen = false
        capture(ContentView().environment(state),
                size: CGSize(width: 330, height: 322),
                appearance: NSAppearance(named: .darkAqua),
                to: "\(outDir)/fold-none.png")
        state.streamsOpen = true                        // the defaults
        capture(ContentView().environment(state),
                size: CGSize(width: 330, height: 518),
                appearance: NSAppearance(named: .darkAqua),
                to: "\(outDir)/fold-default.png")
        state.loudnessOpen = true; state.insertsOpen = true
        capture(ContentView().environment(state),
                size: Self.compactSize,
                appearance: NSAppearance(named: .darkAqua),
                to: "\(outDir)/fold-all.png")
        state.loudnessOpen = false; state.insertsOpen = false
        // Everything folded on an eight-channel bus, at exactly the height the window's floor
        // computes — which is where a scroll bar appears if the floor is a point too mean.
        state.streamsOpen = false
        state.busChannels = 8
        capture(ContentView().environment(state),
                size: CGSize(width: 330, height: 372),
                appearance: NSAppearance(named: .darkAqua),
                to: "\(outDir)/fold-none-8ch.png")
        state.streamsOpen = true

        // The compact window on a wide bus: one meter row per channel, in a fixed block.
        state.busChannels = 8
        capture(ContentView().environment(state),
                size: CGSize(width: 330, height: 560),
                appearance: NSAppearance(named: .darkAqua),
                to: "\(outDir)/fold-8ch.png")
        state.busChannels = 16
        capture(ContentView().environment(state),
                size: CGSize(width: 330, height: 560),
                appearance: NSAppearance(named: .darkAqua),
                to: "\(outDir)/fold-16ch.png")
        state.busChannels = 2
        // As narrow as the window now goes, with everything folded: the point where the
        // loudness summary and the insert rows have to give way rather than overflow.
        state.streamsOpen = true
        capture(ContentView().environment(state),
                size: CGSize(width: 330, height: 518),
                appearance: NSAppearance(named: .darkAqua),
                to: "\(outDir)/fold-narrow.png")
        state.viewMode = .full

        // The bus narrowed **in place**, which is the only way to catch a meter that keeps
        // pixels — or loses them — across a change of bar count. Two separate faults have
        // hidden here, and neither was visible in a freshly built window.
        state.busChannels = 16
        captureAfterChange(ContentView().environment(state),
                           size: Self.fullSize,
                           appearance: NSAppearance(named: .darkAqua),
                           change: { state.busChannels = 2 },
                           to: "\(outDir)/bus-narrowed.png")
        state.busChannels = 2

        // One shot with a custom accent pair, to show what theming does and does not touch.
        state.applyTheme(ThemePreset.all[0])
        capture(ContentView().environment(state),
                size: Self.fullSize,
                appearance: NSAppearance(named: .aqua),
                to: "\(outDir)/ui-theme.png")
        capture(ContentView().environment(state),
                size: Self.fullSize,
                appearance: NSAppearance(named: .darkAqua),
                to: "\(outDir)/ui-theme-dark.png")
        state.themeEnabled = false
        capture(ExpandedRowsPreview(state: state),
                size: CGSize(width: 900, height: 340),
                appearance: NSAppearance(named: .darkAqua),
                to: "\(outDir)/ui-rows.png")

        // The level history, filled with a made-up half minute and one dropout.
        state.showLevelHistory = true
        for i in 0..<LevelHistoryStore.capacity {
            let x = Double(i)
            // Programme between about −30 and −8 dBFS, as speech or a mix would sit.
            let db = -19 + 8 * sin(x / 5) + 3 * sin(x / 1.7)
            let v = Float(pow(10, db / 20))
            state.levelHistory.push(v, fault: i == 84)
        }
        state.showSettings = false
        state.panelInsertsOpen = true
        let historySize = CGSize(width: Self.fullSize.width, height: Self.fullSize.height + 60)
        capture(ContentView().environment(state), size: historySize,
                appearance: NSAppearance(named: .darkAqua), to: "\(outDir)/ui-history-dark.png")
        capture(ContentView().environment(state), size: historySize,
                appearance: NSAppearance(named: .aqua), to: "\(outDir)/ui-history-light.png")
        // The add-by-hand sheet, internet stream first.
        UserDefaults.standard.set("web", forKey: "addStreamKind")
        capture(ManualSDPSheet().environment(state), size: CGSize(width: 492, height: 260),
                appearance: NSAppearance(named: .darkAqua), to: "\(outDir)/ui-add-stream.png")
        UserDefaults.standard.removeObject(forKey: "addStreamKind")

        // Every section that folds, folded: headings and their one-line summaries. The output
        // does not fold.
        state.panelInsertsOpen = false
        capture(ContentView().environment(state), size: Self.fullSize,
                appearance: NSAppearance(named: .darkAqua), to: "\(outDir)/ui-panel-folded.png")
        state.showLevelHistory = false

        // Rea-Theme Default in both appearances and in its pane, and every choice the
        // picker offers, as a list.
        let reaperDefault = ThemePreset.reaperDefault
        state.applyTheme(reaperDefault)
        for (name, look) in [("ui-reaper-default-dark", NSAppearance(named: .darkAqua)),
                             ("ui-reaper-default-light", NSAppearance(named: .aqua))] {
            capture(ContentView().environment(state), size: Self.fullSize, appearance: look,
                    to: "\(outDir)/\(name).png")
        }
        state.showSettings = true
        state.settingsPane = SettingsPane.theme.rawValue
        capture(ContentView().environment(state), size: Self.fullSize,
                appearance: NSAppearance(named: .darkAqua), to: "\(outDir)/ui-settings-theme-reaper-default.png")
        state.showSettings = false
        capture(Form { ColourSchemeControls(theme: .constant(ThemeChoice(enabled: true,
                    primaryHex: reaperDefault.primary, secondaryHex: reaperDefault.secondary)),
                    listsChoices: true) }.formStyle(.grouped),
                size: CGSize(width: 520, height: 600), appearance: NSAppearance(named: .darkAqua),
                to: "\(outDir)/ui-theme-choices.png")

        // First launch on a quiet network: a fresh install, nothing announced, nothing added.
        let first = firstLaunchState()
        for (name, appearance) in [("first-launch-dark", NSAppearance(named: .darkAqua)),
                                   ("first-launch-light", NSAppearance(named: .aqua))] {
            capture(ContentView().environment(first), size: Self.fullSize,
                    appearance: appearance, to: "\(outDir)/\(name).png")
        }
        first.viewMode = .compact
        capture(ContentView().environment(first), size: Self.compactSize,
                appearance: NSAppearance(named: .darkAqua), to: "\(outDir)/first-launch-compact.png")
        first.viewMode = .full
        capture(ConnectToSender().environment(first), size: CGSize(width: 440, height: 580),
                appearance: NSAppearance(named: .darkAqua), to: "\(outDir)/first-connect.png")
        UserDefaults.standard.removePersistentDomain(forName: Self.firstSuite)

        UserDefaults.standard.removePersistentDomain(forName: suite)
        print("Wrote ui-light.png, ui-dark.png, ui-compact.png, ui-settings.png, "
            + "ui-settings-compact.png, ui-settings-discovery.png, ui-settings-playout-vban.png, ui-settings-theme.png, ui-theme.png, ui-theme-dark.png, ui-rows.png and "
            + "bus-2/4/6/8/16.png and bus-narrowed.png to \(outDir)")
        exit(0)
    }

    private static let firstSuite = "app.networkaudiograbber.preview-first"

    /// A fresh install on a quiet network, with made-up names only, as in `populate`.
    @MainActor
    private static func firstLaunchState() -> AppState {
        UserDefaults.standard.removePersistentDomain(forName: firstSuite)
        let first = AppState(defaults: UserDefaults(suiteName: firstSuite) ?? .standard)
        first.applyTheme(ThemePreset.harness)
        first.interfaces = [NetInterface(name: "en5", address: "192.0.2.20", kind: .wired)]
        first.selectedInterface = "en5"
        first.vbanAddressOverride = [NetInterface(name: "en5", address: "192.0.2.20", kind: .wired,
                                                  broadcast: "192.0.2.255")]
        first.vbanReceiverName = "Control Room"
        first.outputDeviceName = "Headphones"
        first.outputRate = 48000
        return first
    }

    /// The layout at its edges: two rows open, a shorter window, every bus width
    /// the output meters have to fit, the ignore list, Settings → Sources, and the compact window.
    @MainActor
    private static func layoutShots(_ state: AppState, outDir: String) {
        let dark = NSAppearance(named: .darkAqua)
        let savedOpen = state.openStreamIDs
        state.openStreamIDs.insert("233.252.0.11:5004")
        capture(ContentView().environment(state), size: fullSize, appearance: dark,
                to: "\(outDir)/ui-two-open.png")
        capture(ContentView().environment(state), size: CGSize(width: fullSize.width, height: 540),
                appearance: dark, to: "\(outDir)/ui-short.png")
        state.openStreamIDs = savedOpen
        for n in [6, 8, 12, 16] {
            state.busChannels = n
            capture(ContentView().environment(state), size: fullSize, appearance: dark,
                    to: "\(outDir)/ui-bus\(n).png")
        }
        state.busChannels = 2
        let ignore = state.streams.filter { ["Dub Stage 7.1", "Laptop VBAN"].contains($0.description.name) }
        state.ignoredStreams = Set(ignore.map(\.id))
        state.ignoredOpen = true
        capture(ContentView().environment(state), size: fullSize, appearance: dark,
                to: "\(outDir)/ui-ignored.png")
        // Gone and Ignored together: a gone stream sits above the ignored ones.
        let gone = state.streams.filter { $0.description.name == "Edit Suite Mac" }
        state.setPreviewGone(Set(gone.map(\.id)))
        capture(ContentView().environment(state), size: fullSize, appearance: dark,
                to: "\(outDir)/ui-gone.png")
        state.setPreviewGone([])
        state.ignoredOpen = false
        state.ignoredStreams = []
        // The stream filter as a row: wide, at the window's floor, where ‹ › appear.
        state.sourceFilterPlacementSetting = .row
        capture(ContentView().environment(state), size: fullSize, appearance: dark,
                to: "\(outDir)/ui-filter-row.png")
        let floor = ContentView.minimumSize(for: state)
        capture(ContentView().environment(state), size: CGSize(width: floor.width, height: fullSize.height),
                appearance: dark, to: "\(outDir)/ui-filter-row-narrow.png")
        state.sourceFilter = .dante
        capture(ContentView().environment(state), size: CGSize(width: floor.width, height: fullSize.height),
                appearance: dark, to: "\(outDir)/ui-filter-row-dante.png")
        state.sourceFilter = nil
        state.sourceFilterPlacementSetting = .sidebar
        state.showSettings = true
        state.settingsPane = SettingsPane.sources.rawValue
        capture(ContentView().environment(state), size: fullSize, appearance: dark,
                to: "\(outDir)/ui-settings-sources.png")
        state.showSettings = false
    }

    @MainActor
    private static func renderMatrix(_ state: AppState, outDir: String) {
        let themes: [(String, ThemePreset?)] = [("default", nil)]
            + ThemePreset.all.map { ($0.name.lowercased().replacingOccurrences(of: " & ", with: "-")
                                        .replacingOccurrences(of: " ", with: "-"), $0) }
        state.openStreamIDs.insert("233.252.0.11:5004")
        for (name, preset) in themes {
            if let preset { state.applyTheme(preset) } else { state.themeEnabled = false }
            for (look, appearance) in [("dark", NSAppearance(named: .darkAqua)), ("light", NSAppearance(named: .aqua))] {
                state.viewMode = .full
                let fullMin = ContentView.minimumSize(for: state)
                for (tag, size) in [("min", fullMin), ("mid", CGSize(width: 1280, height: 800)),
                                    ("big", CGSize(width: 1700, height: 1050))] {
                    capture(ContentView().environment(state), size: size, appearance: appearance,
                            to: "\(outDir)/\(name)-\(look)-full-\(tag).png")
                }
                state.viewMode = .compact
                let compactMin = ContentView.minimumSize(for: state)
                for (tag, size) in [("min", compactMin), ("tall", CGSize(width: compactMin.width, height: 980)),
                                    ("wide", CGSize(width: 520, height: max(compactMin.height, 720)))] {
                    capture(ContentView().environment(state), size: size, appearance: appearance,
                            to: "\(outDir)/\(name)-\(look)-compact-\(tag).png")
                }
                state.viewMode = .full
            }
        }
        print("Wrote the matrix to \(outDir)")
    }

    /// `--mockup-send <dir>`: where the Sender's controls could live in the Grabber —
    /// a Connect / Send window, a panel section, a strip under the list — and the Audio Unit's
    /// window in a plugin-sized frame.
    /// MOCKUPS: connecting to another location — the guide's first question, the Remote link,
    /// By address with its warning, and the badge on rows.
    @MainActor
    /// The quick-start guide's pictures: a clean list — no
    /// faults on show — and each window a first connection passes through. Made-up names and
    /// documentation addresses only. `Tools/annotate-guide.swift` draws the red marks after.
    static func guideShots(outDir: String) {
        let suite = "app.networkaudiograbber.preview.guide"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let state = AppState(defaults: UserDefaults(suiteName: suite) ?? .standard)
        state.applyTheme(ThemePreset.harness)
        let dark = NSAppearance(named: .darkAqua)
        state.interfaces = [NetInterface(name: "en5", address: "192.0.2.20", kind: .wired)]
        state.selectedInterface = "en5"
        state.vbanAddressOverride = [NetInterface(name: "en5", address: "192.0.2.20", kind: .wired,
                                                  broadcast: "192.0.2.255")]
        state.vbanReceiverName = "Control Room"
        for (name, group, channels, source) in [("Studio A 5.1 Bed", "233.252.0.11", 6, DiscoverySource.ravenna),
                                                ("Stagebox-1 TX 1-2", "233.252.0.12", 2, .dante),
                                                ("Dub Stage 7.1", "233.252.0.14", 8, .sap)] {
            state.ingest(sdp(name: name, group: group, channels: channels), source: source, deletion: false)
        }
        state.ingest(StreamDescription(name: "Edit Suite Mac", originAddress: "192.0.2.61",
                                       groupAddress: "192.0.2.61", port: 6981, payloadType: 0,
                                       encoding: .PCM16, sampleRate: 48000, channels: 2,
                                       ptimeMs: 256.0 / 48, ptpRef: nil, source: .vban, rawSDP: ""),
                     deletion: false)
        state.previewOffered = ["vban:192.0.2.61/Edit Suite Mac"]
        state.outputDeviceName = "Headphones"
        state.outputRate = 48000
        state.outputRunning = true
        // As in the app, which always has its Send — so the button reads Connect / Send… —
        // folded away until step 6.
        state.attachPreviewSend(GrabberSend.preview(suiteName: "app.networkaudiograbber.preview.guide.send", sending: false))
        state.sendOpen = false
        state.openStreamIDs = []
        let size = CGSize(width: fullSize.width, height: 560)
        // 1 — the list, nothing playing yet.
        capture(ContentView().environment(state), size: size, appearance: dark, to: "\(outDir)/g1-list.png")
        // 2 — one playing, and a Sender's stream asking its user.
        state.subscribed = ["233.252.0.11:5004"]
        state.previewDefaultMixes()
        state.health = ["233.252.0.11:5004": StreamHealth(receiving: true, lost: 0, underruns: 0)]
        state.previewMeters = PreviewMeters(
            outputL: 0.52, outputR: 0.61, outputHold: 0.78,
            channelPeaks: ["233.252.0.11:5004": [0.71, 0.66, 0.44, 0.18, 0.29, 0.26]],
            figures: ["233.252.0.11:5004": StreamFigures(packets: 128_390, bufferMs: 15.0, driftPPM: -7, peak: 0.71)],
            integrated: -22.8, shortTerm: -21.2, windowed: -23.1, momentary: -20.4)
        capture(ContentView().environment(state), size: size, appearance: dark, to: "\(outDir)/g2-playing.png")
        state.setPreviewSenderStates([:], approvals: ["vban:192.0.2.61/Edit Suite Mac": .waiting])
        capture(ContentView().environment(state), size: size, appearance: dark, to: "\(outDir)/g3-asking.png")
        state.setPreviewSenderStates([:])
        // 4 — the compact window.
        state.viewMode = .compact
        capture(ContentView().environment(state), size: CGSize(width: compactSize.width, height: 640),
                appearance: dark, to: "\(outDir)/g4-compact.png")
        state.viewMode = .full
        // 5 — Connect…, receiving, on this network.
        state.connectWhere = 0
        state.connectTab = 0
        capture(ConnectSendWindow().environment(state), size: CGSize(width: 500, height: 640),
                appearance: dark, to: "\(outDir)/g5-connect-receive.png")
        // 6 — the Grabber's Send: the section in the main window, then Connect…'s Send tab.
        state.sendOpen = true
        capture(ContentView().environment(state), size: CGSize(width: fullSize.width, height: 760),
                appearance: dark, to: "\(outDir)/g6-send-section.png")
        state.connectTab = 1
        capture(ConnectSendWindow().environment(state), size: CGSize(width: 500, height: 640),
                appearance: dark, to: "\(outDir)/g7-connect-send.png")
        // 7 — somewhere else: a Remote link, this end's code made.
        state.connectWhere = 1
        state.remoteMethod = 0
        state.send?.setPreviewRemoteCode(RemoteCode(role: .sending, address: "203.0.113.40", port: 6981))
        capture(ConnectSendWindow().environment(state), size: CGSize(width: 500, height: 780),
                appearance: dark, to: "\(outDir)/g8-remote-send.png")
        state.connectTab = 0
        state.setPreviewRemoteCode(RemoteCode(role: .receiving, address: "203.0.113.50", port: 6980))
        capture(ConnectSendWindow().environment(state), size: CGSize(width: 500, height: 780),
                appearance: dark, to: "\(outDir)/g9-remote-receive.png")
        // 8 — Settings: View (Simple / Detailed, and the window), and Send's Grabbers list
        // with one denied, as the Sender's settings show it.
        state.connectTab = 0; state.connectWhere = 0
        state.sendOpen = false
        state.showSettings = true
        state.settingsPane = SettingsPane.view.rawValue
        capture(ContentView().environment(state), size: CGSize(width: fullSize.width, height: 560),
                appearance: dark, to: "\(outDir)/g10-settings-view.png")
        state.send?.setPreviewDenied(ip: "192.0.2.77", name: "Booth Mac")
        state.settingsPane = SettingsPane.send.rawValue
        capture(ContentView().environment(state), size: CGSize(width: fullSize.width, height: 900),
                appearance: dark, to: "\(outDir)/g11-settings-send.png")
        state.showSettings = false
        UserDefaults.standard.removePersistentDomain(forName: suite)
        UserDefaults.standard.removePersistentDomain(forName: suite + ".send")
    }

    @MainActor
    static func remoteMockups(outDir: String) {
        let suite = "app.networkaudiograbber.preview"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let state = AppState(defaults: UserDefaults(suiteName: suite) ?? .standard)
        state.applyTheme(ThemePreset.harness)
        let dark = NSAppearance(named: .darkAqua), light = NSAppearance(named: .aqua)
        let size = CGSize(width: 520, height: 820)
        // Broadcast on this network, wired and Wi-Fi.
        for (look, appearance) in [("dark", dark), ("light", light)] {
            for wifi in [false, true] {
                capture(BroadcastMock(wifi: wifi).environment(state), size: CGSize(width: 520, height: 470),
                        appearance: appearance, to: "\(outDir)/broadcast-\(wifi ? "wifi" : "wired")-\(look).png")
            }
        }
        for (look, appearance) in [("dark", dark), ("light", light)] {
            for (step, name) in [(RemoteMockStep.choose, "1-choose"), (.here, "2-here"), (.elsewhere, "3-elsewhere"),
                                 (.elsewhereConnected, "4-connected"), (.byAddress, "5-by-address")] {
                capture(ConnectGuideRemoteMock(step: step).environment(state), size: size, appearance: appearance,
                        to: "\(outDir)/remote-\(name)-\(look).png")
            }
            capture(ConnectGuideRemoteMock(step: .elsewhere, sending: true).environment(state), size: size,
                    appearance: appearance, to: "\(outDir)/remote-6-send-tab-\(look).png")
            capture(RemoteRowsMock().environment(state), size: CGSize(width: 620, height: 330), appearance: appearance,
                    to: "\(outDir)/remote-7-rows-\(look).png")
        }
        // As built: the real window, somewhere else chosen, both tabs; and the main window with a
        // stream and a receiver in another location, badged.
        populate(state)
        state.attachPreviewSend(GrabberSend.preview(suiteName: "app.networkaudiograbber.preview.send", sending: true, statuses: true))
        RemoteAddresses.harnessDocumentationIsRemote = true
        state.ingest(StreamDescription(name: "Example Stream A", originAddress: "203.0.113.40",
                                       groupAddress: "203.0.113.40", port: 6980, payloadType: 0,
                                       encoding: .PCM16, sampleRate: 48000, channels: 2,
                                       ptimeMs: 256.0 / 48, ptpRef: nil, source: .vban, rawSDP: ""),
                     deletion: false)
        state.setPreviewRemoteCode(RemoteCode(role: .receiving, address: "203.0.113.40", port: 6980))
        state.send?.setPreviewRemoteCode(RemoteCode(role: .sending, address: "203.0.113.40", port: 6981))
        state.setPreviewRemoteLinks(["203.0.113.60:6981"])
        state.send?.setPreviewRemoteLinks(["203.0.113.60:6980", "203.0.113.61:6980"])
        for (look, appearance) in [("dark", dark), ("light", light)] {
            state.connectWhere = 1
            for tab in [0, 1] {
                state.connectTab = tab
                capture(ConnectSendWindow().environment(state), size: CGSize(width: 500, height: 860),
                        appearance: appearance, to: "\(outDir)/built-remote-\(tab == 0 ? "receive" : "send")-\(look).png")
            }
            // The other two methods, opened.
            state.connectWhere = 1
            state.connectTab = 0
            for (m, name) in [(1, "vpn"), (2, "address")] {
                state.remoteMethod = m
                capture(ConnectSendWindow().environment(state), size: CGSize(width: 500, height: 860),
                        appearance: appearance, to: "\(outDir)/built-method-\(name)-\(look).png")
            }
            state.remoteMethod = 0
            state.connectWhere = 0
            state.connectTab = 0
            capture(ConnectSendWindow().environment(state), size: CGSize(width: 500, height: 860),
                    appearance: appearance, to: "\(outDir)/built-here-receive-\(look).png")
            capture(ContentView().environment(state), size: CGSize(width: fullSize.width, height: 860),
                    appearance: appearance, to: "\(outDir)/built-badges-main-\(look).png")
            state.viewMode = .compact
            state.compactTab = 1
            capture(ContentView().environment(state), size: CGSize(width: compactSize.width, height: 760),
                    appearance: appearance, to: "\(outDir)/built-badges-compact-send-\(look).png")
            state.compactTab = 0
            state.viewMode = .full
        }
        // Later rounds: the Playout pane with a test result, the Log pane's
        // Remove all settings, a VPN stream beside local and remote ones at the narrowest width,
        // a paused link, and the plugin's connect sheet.
        state.ingest(StreamDescription(name: "Home Laptop VPN", originAddress: "100.64.0.10",
                                       groupAddress: "100.64.0.10", port: 6980, payloadType: 0,
                                       encoding: .PCM16, sampleRate: 48000, channels: 2,
                                       ptimeMs: 256.0 / 48, ptpRef: nil, source: .vban, rawSDP: ""),
                     deletion: false)
        state.setPreviewConnectionTest(.done(.init(streamName: "Example Stream A", spreadMs: 31, worstMs: 58,
                                                   lostPercent: 0.2, suggestedMs: 65)))
        state.send?.setPreviewLinksPaused(true)
        for (look, appearance) in [("dark", dark), ("light", light)] {
            state.showSettings = true
            for pane in ["playout", "log"] {
                state.settingsPane = pane
                capture(ContentView().environment(state), size: CGSize(width: fullSize.width, height: 860),
                        appearance: appearance, to: "\(outDir)/later-settings-\(pane)-\(look).png")
            }
            state.showSettings = false
            capture(ContentView().environment(state),
                    size: CGSize(width: ContentView.minimumSize(for: state).width, height: 860),
                    appearance: appearance, to: "\(outDir)/later-narrowest-\(look).png")
            state.connectWhere = 1
            state.connectTab = 1
            state.remoteMethod = 0
            capture(ConnectSendWindow().environment(state), size: CGSize(width: 500, height: 860),
                    appearance: appearance, to: "\(outDir)/later-link-paused-\(look).png")
            state.connectTab = 0
            state.connectWhere = 0
        }
        state.send?.setPreviewLinksPaused(false)
        state.setPreviewConnectionTest(.idle)
        RemoteAddresses.harnessDocumentationIsRemote = false
        state.attachPreviewSend(nil)
        UserDefaults.standard.removePersistentDomain(forName: "app.networkaudiograbber.preview.send")
        UserDefaults.standard.removePersistentDomain(forName: suite)
        print("Wrote the remote mockups to \(outDir)")
    }

    @MainActor
    static func sendMockups(outDir: String) {
        let suite = "app.networkaudiograbber.preview"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let state = AppState(defaults: UserDefaults(suiteName: suite) ?? .standard)
        state.applyTheme(ThemePreset.harness)
        populate(state)
        let dark = NSAppearance(named: .darkAqua), light = NSAppearance(named: .aqua)

        // Version 1: Connect / Send window, both tabs; the main window with the indicator.
        state.previewSendLayout = "window"
        capture(ContentView().environment(state), size: fullSize, appearance: dark,
                to: "\(outDir)/send-1-main.png")
        for (tab, name) in [(false, "connect"), (true, "send")] {
            capture(ConnectSendWindowMock(sendTab: tab).environment(state), size: CGSize(width: 480, height: 600),
                    appearance: dark, to: "\(outDir)/send-1-window-\(name).png")
        }
        capture(ConnectSendWindowMock(sendTab: true).environment(state), size: CGSize(width: 480, height: 600),
                appearance: light, to: "\(outDir)/send-1-window-send-light.png")
        state.viewMode = .compact
        capture(ContentView().environment(state), size: compactSize, appearance: dark,
                to: "\(outDir)/send-1-compact.png")
        state.viewMode = .full

        // Version 2: a Send section in the panel, folded and open.
        for layout in ["panel", "panel-open"] {
            state.previewSendLayout = layout
            capture(ContentView().environment(state), size: CGSize(width: fullSize.width, height: 760),
                    appearance: dark, to: "\(outDir)/send-2-\(layout).png")
        }
        // Version 3: a strip under the list, closed and open.
        for layout in ["strip", "strip-open"] {
            state.previewSendLayout = layout
            capture(ContentView().environment(state), size: CGSize(width: fullSize.width, height: 760),
                    appearance: dark, to: "\(outDir)/send-3-\(layout).png")
        }
        // Round 2: the taller section along the bottom, folded and open.
        for layout in ["bottom", "bottom-open"] {
            state.previewSendLayout = layout
            capture(ContentView().environment(state), size: CGSize(width: fullSize.width, height: 760),
                    appearance: dark, to: "\(outDir)/send-4-\(layout).png")
        }
        state.previewSendLayout = nil

        // As built: the bottom section, the Receive / Send window, the compact tabs.
        let sendSuite = "app.networkaudiograbber.preview.send"
        for (sending, tag) in [(true, "sending"), (false, "idle")] {
            state.attachPreviewSend(GrabberSend.preview(suiteName: sendSuite, sending: sending))
            for (look, appearance) in [("dark", dark), ("light", light)] {
                state.sendOpen = true
                capture(ContentView().environment(state), size: CGSize(width: fullSize.width, height: 820),
                        appearance: appearance, to: "\(outDir)/built-main-\(tag)-\(look).png")
                for tab in [0, 1] {
                    state.connectTab = tab
                    capture(ConnectSendWindow().environment(state), size: CGSize(width: 480, height: 620),
                            appearance: appearance, to: "\(outDir)/built-window-\(tab == 0 ? "receive" : "send")-\(tag)-\(look).png")
                }
                state.viewMode = .compact
                for tab in [0, 1] {
                    state.compactTab = tab
                    capture(ContentView().environment(state), size: CGSize(width: compactSize.width, height: 720),
                            appearance: appearance, to: "\(outDir)/built-compact-\(tab == 0 ? "receive" : "send")-\(tag)-\(look).png")
                }
                state.compactTab = 0
                state.viewMode = .full
            }
        }
        state.sendOpen = false
        capture(ContentView().environment(state), size: CGSize(width: fullSize.width, height: 760),
                appearance: dark, to: "\(outDir)/built-main-folded-dark.png")
        // Auto-stop's states: a stream on the list, targets in Send; then the panes.
        state.attachPreviewSend(GrabberSend.preview(suiteName: sendSuite, sending: true, statuses: true))
        state.sendOpen = true
        state.autoStopStreams = true
        state.setPreviewAutoStop("233.252.0.15:5004", minutes: 15)
        for (look, appearance) in [("dark", dark), ("light", light)] {
            capture(ContentView().environment(state), size: CGSize(width: fullSize.width, height: 820),
                    appearance: appearance, to: "\(outDir)/built-autostop-main-\(look).png")
            state.viewMode = .compact
            state.compactTab = 0
            capture(ContentView().environment(state), size: CGSize(width: compactSize.width, height: 720),
                    appearance: appearance, to: "\(outDir)/built-autostop-compact-\(look).png")
            state.viewMode = .full
            state.showSettings = true
            for pane in ["playout", "send"] {
                state.settingsPane = pane
                capture(ContentView().environment(state), size: CGSize(width: fullSize.width, height: 820),
                        appearance: appearance, to: "\(outDir)/built-settings-\(pane)-\(look).png")
            }
            state.showSettings = false
        }
        state.clearAutoStop("233.252.0.15:5004")
        state.autoStopStreams = false
        state.attachPreviewSend(nil)
        UserDefaults.standard.removePersistentDomain(forName: sendSuite)
        UserDefaults.standard.removePersistentDomain(forName: suite)

        // The Audio Unit's window: host mode, a plugin-sized frame, the filter row.
        AudioOutput.hostMode = true
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let plugin = AppState(defaults: UserDefaults(suiteName: suite) ?? .standard)
        plugin.applyTheme(ThemePreset.harness)
        populate(plugin)
        plugin.outputDeviceName = "DAW"
        for (name, size) in [("plugin-full", CGSize(width: ContentView.fullMinimumWidth(for: plugin), height: 660)),
                             ("plugin-900", CGSize(width: 900, height: 600)),
                             ("plugin-760", CGSize(width: 760, height: 560))] {
            capture(ContentView().environment(plugin), size: size, appearance: dark,
                    to: "\(outDir)/\(name).png")
        }
        // The Grabber plugin's connect sheet, somewhere else chosen.
        plugin.connectWhere = 1
        capture(PluginConnectSheet().environment(plugin), size: CGSize(width: 460, height: 620),
                appearance: dark, to: "\(outDir)/plugin-connect-sheet-dark.png")
        plugin.connectWhere = 0
        // The split: the Receiver opens compact, with no Send; the Sender's window.
        let openSize = CGSize(width: CompactView.pluginOpenWidth, height: 660)
        for (look, appearance) in [("dark", dark), ("light", light)] {
            capture(ContentView().environment(plugin), size: openSize, appearance: appearance,
                    to: "\(outDir)/plugin-receiver-\(look).png")
            let sender = GrabberSend.preview(suiteName: "app.networkaudiograbber.preview.send", sending: true, track: true)
            capture(SenderPluginView(send: sender), size: CGSize(width: CompactView.pluginOpenWidth, height: 560),
                    appearance: appearance, to: "\(outDir)/plugin-sender-\(look).png")
        }
        UserDefaults.standard.removePersistentDomain(forName: "app.networkaudiograbber.preview.send")
        UserDefaults.standard.removePersistentDomain(forName: suite)
        print("Wrote the send and plugin mockups to \(outDir)")
    }

    static let fullSize = CGSize(width: 1260, height: 660)
    static let compactSize = CGSize(width: 380, height: 560)

    @MainActor
    /// Renders a window, changes something, and shoots it **without rebuilding the window** —
    /// the only way to catch a view that keeps pixels from a state it no longer has.
    private static func captureAfterChange<V: View>(_ view: V, size: CGSize,
                                                    appearance: NSAppearance?,
                                                    change: @escaping () -> Void,
                                                    to path: String) {
        let window = ActiveLookingWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.orderFrontRegardless()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(2.0))
        change()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(2.0))
        window.displayIfNeeded()
        if let png = WindowShot.png(of: window) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        window.orderOut(nil)
    }

    /// **A window that is laid out and then made smaller**, which is the one thing `capture`
    /// cannot show: it pins the content to a fixed frame in a window that never resizes, so
    /// every shot is a first layout. A meter that keeps a stale length through a resize looks
    /// perfect in all of them and wrong in the app, where going from the full window to the
    /// compact one — or dragging the edge — is always a resize of an existing layout.
    ///
    /// The hosting view autoresizes with the window here, as it does in the real app.
    private static func captureAfterResize<V: View>(_ view: V, from: CGSize, to size: CGSize,
                                                    appearance: NSAppearance?, to path: String) {
        let window = ActiveLookingWindow(contentRect: NSRect(origin: .zero, size: from),
                              styleMask: [.titled, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = appearance
        let host = NSHostingView(rootView: view)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        window.orderFrontRegardless()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(2.0))

        window.setContentSize(size)
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        window.displayIfNeeded()

        if let png = WindowShot.png(of: window) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        window.orderOut(nil)
    }

    private static func capture<V: View>(_ view: V, size: CGSize,
                                         appearance: NSAppearance?, to path: String) {
        let window = ActiveLookingWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.setFrameOrigin(NSPoint(x: 0, y: 0))
        window.orderFrontRegardless()
        window.displayIfNeeded()

        // SwiftUI needs several passes before a LazyVStack inside a ScrollView is fully laid out.
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        window.displayIfNeeded()

        // The window server sees the whole composited layer tree, which `cacheDisplay` does not.
        if let png = WindowShot.png(of: window) {
            try? png.write(to: URL(fileURLWithPath: path))
            window.orderOut(nil)
            return
        }

        // Fall back to drawing the layer tree directly if the window server declines.
        if let content = window.contentView, let layer = content.layer,
           let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds),
           let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            layer.render(in: ctx.cgContext)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
        }
        window.orderOut(nil)
    }

    /// Synthetic streams covering every row variation: surround fold-down, Dante, discrete
    /// multichannel, a favourite, and one discovered but not being listened to.
    @MainActor
    private static func populate(_ state: AppState) {
        // A made-up interface, never this Mac's: the toolbar shows its name and Settings shows
        // its address, and a screenshot must carry neither. 192.0.2.0/24 is reserved for
        // documentation, so it cannot be anyone's real network.
        state.interfaces = [NetInterface(name: "en5", address: "192.0.2.20", kind: .wired)]
        state.selectedInterface = "en5"
        state.vbanAddressOverride = [
            NetInterface(name: "en5", address: "192.0.2.20", kind: .wired,
                         broadcast: "192.0.2.255"),
            NetInterface(name: "en0", address: "198.51.100.20", kind: .wifi,
                         broadcast: "198.51.100.255"),
            NetInterface(name: "utun4", address: "203.0.113.20", kind: .vpn),
        ]
        // Never the Mac's own name, which is the default: the images go in the documentation.
        state.vbanReceiverName = "Control Room"
        _ = state.addManualSender("203.0.113.30")          // VBAN is still off: asks nobody
        _ = state.addManualSender("203.0.113.31:6981")
        state.previewOffered = ["vban:192.0.2.61/Edit Suite Mac"]
        state.setPreviewSenderStates(["203.0.113.30:6981": true],
                                     approvals: ["vban:192.0.2.61/Edit Suite Mac": .waiting])
        let samples: [(String, String, Int, DiscoverySource)] = [
            ("Live Room 1-8", "233.252.0.10", 8, .ravenna),
            ("Studio A 5.1 Bed", "233.252.0.11", 6, .ravenna),
            ("Stagebox-1 TX 1-2", "233.252.0.12", 2, .dante),
            ("Edit Bay 3 Monitor", "233.252.0.13", 6, .sap),
            ("Dub Stage 7.1", "233.252.0.14", 8, .ravenna),
            ("Ref Mix (manual)", "233.252.0.15", 2, .manual),
        ]
        for (name, group, channels, source) in samples {
            state.ingest(sdp(name: name, group: group, channels: channels), source: source, deletion: false)
        }
        // VBAN describes itself in its packet headers rather than an SDP, so it goes in as a
        // description — the same path `VBANListener` feeds.
        state.ingest(StreamDescription(name: "Laptop VBAN", originAddress: "192.0.2.60",
                                       groupAddress: "192.0.2.60", port: 6980, payloadType: 0,
                                       encoding: .PCM16, sampleRate: 48000, channels: 2,
                                       ptimeMs: 256.0 / 48, ptpRef: nil, source: .vban,
                                       rawSDP: ""),
                     deletion: false)
        // A Network Audio Sender's offered stream, waiting for its user to allow this Grabber.
        state.ingest(StreamDescription(name: "Edit Suite Mac", originAddress: "192.0.2.61",
                                       groupAddress: "192.0.2.61", port: 6981, payloadType: 0,
                                       encoding: .PCM16, sampleRate: 48000, channels: 2,
                                       ptimeMs: 256.0 / 48, ptpRef: nil, source: .vban,
                                       rawSDP: ""),
                     deletion: false)
        // The beta receivers on, so the shots show what they add.
        state.plainRTPEnabled = true
        state.webStreamsEnabled = true
        // An internet station, on a reserved example domain, playing, with a title.
        let station = WebStreamInfo(url: "https://radio.example.org/live.aac", name: "Example Radio",
                                    codec: "AAC", sampleRate: 44100, channels: 2, bitrate: 128)
        state.ingest(station.description, deletion: false)
        state.nowPlaying[station.description.id] = "Test Artist - A Song Title"
        state.favourites = ["233.252.0.10:5004"]
        state.subscribed = ["233.252.0.10:5004", "233.252.0.11:5004", "233.252.0.12:5004"]
        // As they would be on joining, so a 7.1 bed shows its fold-down rather than `Ch 1/2`.
        state.previewDefaultMixes()
        // A stream that could not be joined, so the shots show the fault on its row.
        state.joinFailures["233.252.0.13:5004"] = AppState.plainJoinFailure("bind failed: Address already in use", port: 5004)
        state.health = [
            "233.252.0.10:5004": StreamHealth(receiving: true, lost: 0, underruns: 0),
            "233.252.0.11:5004": StreamHealth(receiving: true, lost: 2, underruns: 0),
            "233.252.0.12:5004": StreamHealth(receiving: false, lost: 0, underruns: 0),
        ]
        state.danteDevices = [DanteDevice(name: "Stagebox-1", address: "192.0.2.44"),
                              DanteDevice(name: "Stagebox-2", address: "192.0.2.45")]
        state.outputDeviceName = "Headphones"
        state.outputRate = 48000
        state.outputRunning = true
        // Meters read live from the audio engine in normal use, so the harness injects levels.
        state.previewMeters = PreviewMeters(
            outputL: 0.52, outputR: 0.61, outputHold: 0.78,
            channelPeaks: [
                "233.252.0.10:5004": [0.62, 0.48, 0.31, 0.55, 0.22, 0.40, 0.12, 0.35],
                "233.252.0.11:5004": [0.71, 0.66, 0.44, 0.18, 0.29, 0.26],
                "233.252.0.12:5004": [0.34, 0.30],
            ],
            // One reading on target, one a little over, one a little under, so the deviation
            // dots in the shot show all three colours doing something.
            figures: [
                "233.252.0.10:5004": StreamFigures(packets: 128_400, bufferMs: 15.2,
                                                   driftPPM: 18, peak: 0.42),
                "233.252.0.11:5004": StreamFigures(packets: 128_390, bufferMs: 15.0,
                                                   driftPPM: -7, peak: 0.71),
            ],
            integrated: -22.8, shortTerm: -21.2, windowed: -23.1, momentary: -20.4,
            blocksMeasured: 1_800)
        // The readout falls more slowly than the bars, so it sits above them in a still frame.
        state.previewMeters?.outputReadout = 0.68
        // Synthetic entries: a real Audio Unit scan blocks here, because AppState has already
        // opened an AVAudioEngine and this path has no run loop spinning yet.
        state.availablePlugins = [
            PluginInfo(name: "SoundID Reference", manufacturer: "Sonarworks",
                       type: 0x61756678, subType: 1, manufacturerCode: 1, hasCustomView: true),
            PluginInfo(name: "Pro-Q 4", manufacturer: "FabFilter",
                       type: 0x61756678, subType: 2, manufacturerCode: 2, hasCustomView: true),
        ]
        state.slotInfo[0] = state.availablePlugins.first
        // Two inserts and their dry/wet, so the shots show what a loaded chain looks like
        // rather than one plugin and two empty slots (asked for with the UI mockups).
        state.slotInfo[1] = state.availablePlugins.last
        state.slotMix[1] = 0.6
        state.showInsertMix = true
        // Nothing is really instantiated here, so say the slots are live or the screenshots
        // show Δ permanently disabled — it is greyed until a plugin is actually wired.
        state.slotLive = [state.slotInfo[0] != nil, state.slotInfo[1] != nil, false]
        // A row open, or the shots never show the block the list exists to reveal.
        state.openStreamIDs = ["233.252.0.10:5004"]
        // Show the channel-solo strip in the shot: the rear pair of the 7.1 stream, which is
        // the case that prompted the feature.
        state.soloChannels("233.252.0.10:5004", named: ["Lrs", "Rrs"])
        // One muted stream as well, so a shot shows both halves of the grey rule: bars that are
        // reaching the output in colour, bars that are not in grey.
        state.userMuted = ["233.252.0.11:5004"]
        // And a stream solo on top, which is the case that used to put a stray "M" on every
        // other stream and a second one on the muted stream.
        state.soloed = "233.252.0.10:5004"
        // The readouts are formatted by the 0.25 s tick, which this harness never starts, so
        // ask for them once directly or the shot captures a panel full of −∞.
        state.refreshReadouts()
        // Synthetic, like everything here: documentation addresses and made-up names.
        state.activity.add(.note, "Opened Network Audio Grabber.")
        state.activity.add(.note, "Discovery: SAP + RAVENNA + Dante on en5 (192.0.2.20).")
        state.activity.add(.note, "Found Live Room 1-8 — 233.252.0.10:5004 (L24 · 8 ch · 48 kHz · 1 ms) via RAVENNA")
        state.activity.add(.request, "Joining “Live Room 1-8” — RAVENNA, group 233.252.0.10:5004.")
        state.activity.add(.done, "Receiving “Live Room 1-8” — L24 · 8 ch · 48 kHz · 1 ms.")
        state.activity.add(.request, "Joining “Edit Suite Mac” — VBAN from Network Audio Sender at 192.0.2.61.")
        state.activity.add(.request, "Waiting for the Sender at 192.0.2.61 to allow this Grabber — its user has been asked.")
        state.activity.add(.warning, "No packets from Stagebox-1 TX 1-2 on en5. If the sender is on another NIC, pick it in the network menu.")
        state.activity.add(.stopped, "Stopped “Ref Mix (manual)” — you stopped it.")
        state.activity.add(.failed, "Timed out: no answer from the Sender at 203.0.113.31:6981 after 15 s. Is it running and offering? Still asking, less often.")
    }

    private static func sdp(name: String, group: String, channels: Int) -> String {
        """
        v=0\r
        o=- 1 1 IN IP4 192.0.2.99\r
        s=\(name)\r
        c=IN IP4 \(group)/32\r
        t=0 0\r
        m=audio 5004 RTP/AVP 98\r
        a=rtpmap:98 L24/48000/\(channels)\r
        a=ptime:1\r
        a=ts-refclk:ptp=IEEE1588-2008:00-00-5E-EF-10-00-00-01:0\r
        a=recvonly\r
        """
    }

    private static func value(for flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

/// Rows forced open, so the expanded detail can be reviewed too.
private struct ExpandedRowsPreview: View {
    let state: AppState

    var body: some View {
        VStack(spacing: 4) {
            ForEach(state.streams.prefix(3)) { stream in
                StreamRowView(stream: stream.description)
            }
            Spacer()
        }
        .padding(10)
        .environment(state)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
