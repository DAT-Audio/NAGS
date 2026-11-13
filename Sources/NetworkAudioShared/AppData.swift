import Foundation
import AppKit
import SwiftUI

/// Where Network Audio Grabber, Network Audio Sender and the DAT Audio plugins keep things on this
/// Mac, gathered so that leaving takes few steps:
///
/// - **Logs**: one folder, `~/Library/Application Support/Network Audio`, a file per app. (They
///   were a folder each, named by bundle identifier; old ones move here on first use.)
/// - **Settings**: macOS's own preferences files, `~/Library/Preferences/app.networkaudio….plist` —
///   where macOS puts them; every one starts `app.networkaudio`.
///
/// `removeEverything` clears all of it, for **Settings → Remove all settings…** and
/// `Tools/reset-prefs.sh`. DAW projects keep their plugins' own copies, which it cannot reach.
public enum AppData {
    public static var folder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Network Audio", isDirectory: true)
    }

    private static func logName(_ bundleID: String) -> String {
        switch bundleID {
        case "app.networkaudiograbber.monitor": "Network Audio Grabber log.json"
        case "app.networkaudiosender.send": "Network Audio Sender log.json"
        case "app.networkaudiograbber.au": "DAT Audio plugins log.json"
        default: "\(bundleID) log.json"
        }
    }

    /// The log file for an app, in the shared folder — moved there from where it used to be.
    public static func logFile(bundleID: String) -> URL? {
        guard let folder, let base = folder.deletingLastPathComponent() as URL? else { return nil }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(logName(bundleID))
        let oldFolder = base.appendingPathComponent(bundleID, isDirectory: true)
        let old = oldFolder.appendingPathComponent("activity-log.json")
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: file.path) { try? fm.moveItem(at: old, to: file) }
        if let left = try? fm.contentsOfDirectory(atPath: oldFolder.path), left.isEmpty { try? fm.removeItem(at: oldFolder) }
        return file
    }

    /// Every preferences domain the apps, their Send, the plugins and their self-tests use.
    public static func preferenceDomains() -> [String] {
        guard let prefs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Preferences"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: prefs.path) else { return [] }
        return names.filter { $0.hasSuffix(".plist") && ($0.hasPrefix("app.networkaudiograbber") || $0.hasPrefix("app.networkaudiosender")
                                                          || $0 == "NetworkAudioGrabber.plist" || $0 == "NetworkAudioSender.plist") }
            .map { String($0.dropLast(".plist".count)) }
    }

    /// Removes every setting and log, in both apps and the plugins. Returns how many things went.
    @discardableResult
    public static func removeEverything() -> Int {
        let fm = FileManager.default
        var count = 0
        let prefs = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?.appendingPathComponent("Preferences")
        for domain in preferenceDomains() {
            UserDefaults.standard.removePersistentDomain(forName: domain)      // through cfprefsd
            if let prefs { try? fm.removeItem(at: prefs.appendingPathComponent(domain + ".plist")) }
            count += 1
        }
        if let folder, fm.fileExists(atPath: folder.path) { try? fm.removeItem(at: folder); count += 1 }
        // The folders logs used to live in, if any are left.
        if let base = folder?.deletingLastPathComponent(),
           let names = try? fm.contentsOfDirectory(atPath: base.path) {
            for n in names where n.hasPrefix("app.networkaudiograbber") || n.hasPrefix("app.networkaudiosender") {
                try? fm.removeItem(at: base.appendingPathComponent(n)); count += 1
            }
        }
        return count
    }

    /// The other app, if it is running: it would write its settings straight back.
    public static func otherAppRunning() -> String? {
        let mine = Bundle.main.bundleIdentifier
        for (id, name) in [("app.networkaudiograbber.monitor", "Network Audio Grabber"),
                           ("app.networkaudiosender.send", "Network Audio Sender")] where id != mine {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty { return name }
        }
        return nil
    }
}

/// **Remove all settings…**, in both apps' Settings: for leaving, or starting afresh. Asks first,
/// then clears both apps, their Send and the plugins, and quits at once so nothing is written back.
public struct RemoveAllSettings: View {
    @State private var asking = false
    @State private var blocked: String?
    public init() {}

    public var body: some View {
        Section {
            HStack {
                Button("Remove all settings…", role: .destructive) {
                    blocked = AppData.otherAppRunning()
                    asking = true
                }
                Spacer()
            }
        } header: {
            Text("Starting afresh, or uninstalling")
        } footer: {
            Text("Removes every setting, favourite, saved target, link and log of Network Audio Grabber, "
               + "Network Audio Sender and the DAT Audio plugins on this Mac, then quits. To uninstall "
               + "after that, move the apps to the Trash (and the plugin, Network Audio Grabber.component in "
               + "~/Library/Audio/Plug-Ins/Components, if it is installed), then empty the Trash.")
                .font(.caption2).foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        .alert(blocked.map { "Quit \($0) first" } ?? "Remove all settings and quit?", isPresented: $asking) {
            if blocked == nil {
                Button("Remove and quit", role: .destructive) {
                    AppData.removeEverything()
                    exit(0)                   // straight away: a normal quit would save them again
                }
            }
            Button(blocked == nil ? "Cancel" : "OK", role: .cancel) {}
        } message: {
            Text(blocked.map { "\($0) is open, and would write its settings straight back. Quit it, then try again." }
                 ?? "Every setting, favourite, saved target, link and log of both apps and the plugins goes. "
                    + "Close any DAW project with a DAT Audio plugin first. This cannot be undone.")
        }
    }
}
