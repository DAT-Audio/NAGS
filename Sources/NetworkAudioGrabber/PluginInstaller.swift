import AppKit
import Observation

/// Help → Install DAW Plug-ins (beta)… (the disk image offers the plug-ins too). The Grabber carries the DAT Audio plug-ins inside itself
/// (`Contents/Library/Audio/Plug-Ins/Components`, put there by `build.sh`) and copies them into
/// the user's own Components folder. No password and no Terminal: the app has already been
/// allowed to open, and the copy is cleared of the "downloaded" flag a DAW cannot ask about.
///
/// The menu item says what it will do: Install, Update (this Grabber carries a newer build than
/// the one installed) or Remove; and only explains when the plug-ins are installed for all users
/// (from the disk image), which needs Finder and a password to change.
@Observable @MainActor
final class PluginInstaller {
    static let shared = PluginInstaller()

    static let bundleID = "app.networkaudiograbber.au"
    static let bundleName = "Network Audio Grabber.component"

    enum Status: Equatable {
        case notCarried                  // a build without the plug-ins inside: no menu item
        case notInstalled
        case installed                   // in the user's folder, this build or newer
        case older(installed: Int)       // in the user's folder, older than this build
        case allUsersOnly                // only in /Library, from the disk image
    }

    private(set) var status: Status = .notCarried

    private init() {
        refresh()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PluginInstaller.shared.refresh() }
        }
    }

    var carried: URL? {
        if let c = Self.testCarried { return c }
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Audio/Plug-Ins/Components/\(Self.bundleName)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    static var userFolder: URL {
        testFolders?.user ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Audio/Plug-Ins/Components")
    }
    static var allUsersFolder: URL { testFolders?.allUsers ?? URL(fileURLWithPath: "/Library/Audio/Plug-Ins/Components") }
    /// For `--check-installer` only: folders under a temporary directory, so the check never
    /// touches the real Components folders.
    static var testFolders: (user: URL, allUsers: URL)?
    static var testCarried: URL?

    var menuTitle: String? {
        switch status {
        case .notCarried: return nil
        case .notInstalled: return "Install DAW Plug-ins (beta)\u{2026}"
        case .installed: return "Remove DAW Plug-ins\u{2026}"
        case .older: return "Update DAW Plug-ins\u{2026}"
        case .allUsersOnly: return "DAW Plug-ins (beta)\u{2026}"
        }
    }

    func refresh() {
        guard let carried, let mine = Self.version(of: carried) else { status = .notCarried; return }
        let inUser = Self.ours(in: Self.userFolder)
        if let newest = inUser.compactMap({ Self.version(of: $0) }).max() {
            status = newest < mine ? .older(installed: newest) : .installed
        } else if !Self.ours(in: Self.allUsersFolder).isEmpty {
            status = .allUsersOnly
        } else {
            status = .notInstalled
        }
    }

    /// The menu item: asks, then does it.
    func run() {
        refresh()
        switch status {
        case .notCarried: return
        case .notInstalled, .older: confirmInstall()
        case .installed: confirmRemove()
        case .allUsersOnly: explainAllUsers()
        }
    }

    // MARK: - Steps

    private func confirmInstall() {
        let a = NSAlert()
        let updating: Bool = { if case .older = status { return true }; return false }()
        a.messageText = updating ? "Update the DAW plug-ins?" : "Install the DAW plug-ins?"
        a.informativeText = "Three Audio Unit plug-ins \u{2014} Grabber, Grabber (effect) and Sender \u{2014} for DAWs "
            + "such as Logic and REAPER. They\u{2019}re beta.\n\nThey go in your Components folder:\n"
            + "~/Library/Audio/Plug-Ins/Components\n\nQuit your DAW first, then open it again to find them "
            + "under DAT Audio."
            + (Self.ours(in: Self.allUsersFolder).isEmpty ? "" :
                "\n\nA copy for all users is also installed, from the disk image. Remove it with Finder from "
                + "/Library/Audio/Plug-Ins/Components so that DAWs see only one.")
        a.icon = icon
        a.addButton(withTitle: updating ? "Update" : "Install")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do {
            try install()
            refresh()
            let done = NSAlert()
            done.messageText = updating ? "DAW plug-ins updated" : "DAW plug-ins installed"
            done.informativeText = "Open your DAW and let it rescan. In Logic, if they don\u{2019}t appear: Settings "
                + "\u{2192} Plug-in Manager \u{2192} Reset & Rescan Selection."
            done.icon = icon
            done.addButton(withTitle: "OK")
            done.addButton(withTitle: "Show in Finder")
            if done.runModal() == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([Self.userFolder.appendingPathComponent(Self.bundleName)])
            }
        } catch {
            fail("The plug-ins could not be installed", error)
        }
    }

    private func confirmRemove() {
        let a = NSAlert()
        a.messageText = "Remove the DAW plug-ins?"
        a.informativeText = "The DAT Audio plug-ins are moved from your Components folder to the Bin. Quit your "
            + "DAW first. DAW projects that use them will open without them."
        a.icon = icon
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do {
            for url in Self.ours(in: Self.userFolder) { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            refresh()
        } catch {
            fail("The plug-ins could not be removed", error)
        }
    }

    private func explainAllUsers() {
        let a = NSAlert()
        a.messageText = "The DAW plug-ins are installed for all users"
        a.informativeText = "They were installed from the disk image into /Library/Audio/Plug-Ins/Components. To "
            + "update or remove them, use Finder there (it asks for your password), or remove them and install "
            + "them here for yourself instead."
        a.icon = icon
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Show in Finder")
        if a.runModal() == .alertSecondButtonReturn, let first = Self.ours(in: Self.allUsersFolder).first {
            NSWorkspace.shared.activateFileViewerSelecting([first])
        }
    }

    private func fail(_ title: String, _ error: Error) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = error.localizedDescription
        a.runModal()
    }

    /// The plug-ins' own icon (the Grabber's with a plug badge), read from the bundle: Finder
    /// shows any plug-in bundle as a blank page, whatever icon it carries.
    private var icon: NSImage? {
        carried.flatMap { NSImage(contentsOf: $0.appendingPathComponent("Contents/Resources/DATAudioPlugins.icns")) }
    }

    // MARK: - Files

    /// Copies the carried plug-ins into the user's folder: beside the old copy first, then swapped
    /// in, so a failure leaves what was there. Any older copy of ours (by bundle identifier,
    /// whatever its file name) goes to the Bin.
    func install() throws {
        guard let carried else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: Self.userFolder, withIntermediateDirectories: true)
        let dest = Self.userFolder.appendingPathComponent(Self.bundleName)
        let staging = Self.userFolder.appendingPathComponent(".\(Self.bundleName).installing")
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: carried, to: staging)
        Self.clearQuarantine(staging)
        for old in Self.ours(in: Self.userFolder) { try fm.trashItem(at: old, resultingItemURL: nil) }
        try fm.moveItem(at: staging, to: dest)
    }

    /// The copy inherits the app's "downloaded" flag; a DAW cannot show the Open Anyway question
    /// for a plug-in, so the flag goes.
    private static func clearQuarantine(_ url: URL) {
        let name = "com.apple.quarantine"
        removexattr(url.path, name, XATTR_NOFOLLOW)
        guard let e = FileManager.default.enumerator(atPath: url.path) else { return }
        while let rel = e.nextObject() as? String {
            removexattr(url.appendingPathComponent(rel).path, name, XATTR_NOFOLLOW)
        }
    }

    /// Our plug-in bundles in a folder, found by bundle identifier, not by name.
    static func ours(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return items.filter { url in
            url.pathExtension == "component" && !url.lastPathComponent.hasPrefix(".")
                && (info(of: url)?["CFBundleIdentifier"] as? String) == bundleID
        }
    }

    static func version(of bundle: URL) -> Int? {
        (info(of: bundle)?["CFBundleVersion"] as? String).flatMap(Int.init)
    }

    /// Read from the file each time: `Bundle` caches, and the copy may just have changed.
    private static func info(of bundle: URL) -> [String: Any]? {
        NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
    }
}
