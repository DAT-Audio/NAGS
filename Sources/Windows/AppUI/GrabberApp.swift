import Foundation
import WinSDK
import NetworkAudioEngine
import GrabberCore

// `nag-grabber` — the Windows Grabber, with a window.
//
// The same engine and output as `nag-grab`; only the front differs. Unlike the console it
// remembers its settings and its log between runs, as the Mac Grabber does — including what was
// playing, which it picks up again as those streams are found.

/// `nag-grabber`: the Grabber with a window. Its whole start-up, so the executable is one line.
public func runGrabberApp() -> Never {
    setvbuf(stdout, nil, _IONBF, 0)

    if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
        print("""
        nag-grabber — the Windows Grabber, with a window

          --help             this

        Settings, the log and what was playing are remembered between runs. `nag-grab` is the same
        Grabber without a window.
        """)
        exit(0)
    }

    // Opened from Explorer, this would otherwise sit behind a console window (see `nag-sender`).
    FreeConsole()
    // The window's thread is a COM single-threaded apartment with OLE: some plug-in editors use OLE.
    _ = OleInitialize(nil)
    // Per-monitor DPI, so text stays sharp on a 4K laptop and moving between screens rescales.
    _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT(bitPattern: -4))   // PER_MONITOR_AWARE_V2

    /// The log, kept between runs in the user's local app data — not beside the app, which may be
    /// somewhere it cannot write.
    func logFile() -> URL? {
        guard let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"] else { return nil }
        let folder = URL(fileURLWithPath: base).appendingPathComponent("Network Audio Grabber")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("activity-log.json")
    }

    // `--test`: a throwaway settings suite and no log file, so driving the window for a test leaves
    // the real settings — and what is remembered as playing — alone. SAP is off in it, so the only
    // streams listed are VBAN ones sent to this PC, and a test click cannot join one on the network.
    let testing = CommandLine.arguments.contains("--test")
    if testing { UserDefaults.standard.removePersistentDomain(forName: "app.networkaudiograbber.windows.test") }
    let defaults = UserDefaults(suiteName: testing ? "app.networkaudiograbber.windows.test" : "app.networkaudiograbber.windows")
        ?? .standard
    if testing {
        defaults.set(false, forKey: "sapEnabled")
        defaults.set(false, forKey: "ravennaEnabled")
        defaults.set(false, forKey: "danteEnabled")
        // Silent: a test plays this PC's own loopback back to it, which would feed back.
        defaults.set(0.0, forKey: "masterVolume")
    }
    let grabber = WindowsGrabber(defaults: defaults, logFile: testing ? nil : logFile())
    grabber.start()

    let window = GrabberWindow(grabber: grabber, view: ViewState(defaults: defaults), testing: testing)
    guard window.create() else {
        print("The window could not be made.")
        exit(1)
    }
    window.run()
    grabber.shutdown()
    exit(0)
}
