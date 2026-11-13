import AppKit
import SwiftUI

/// `--check-installer`: Help → Install DAW Plug-ins, end to end, against folders in a temporary
/// directory (never the real Components folders): status, install, the download flag cleared,
/// "older" detection, all-users-only detection. `--render-about <dir>`: the About and Licences
/// windows' views drawn off screen, dark and light, for review without a screen.
@MainActor
enum InstallerCheck {
    static func run() {
        setvbuf(stdout, nil, _IONBF, 0)
        var failures = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "PASS  " : "FAIL  ") + name); if !ok { failures += 1 } }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("nag-installer-check-\(UUID().uuidString)")
        let user = root.appendingPathComponent("user"), all = root.appendingPathComponent("all")
        defer { try? fm.removeItem(at: root) }
        try? fm.createDirectory(at: all, withIntermediateDirectories: true)

        let built = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Audio/Plug-Ins/Components/\(PluginInstaller.bundleName)")
        guard fm.fileExists(atPath: built.path) else { print("FAIL  this build carries no plug-ins"); exit(1) }
        // A copy carrying the download flag, as a downloaded app's would.
        let carried = root.appendingPathComponent("carried/\(PluginInstaller.bundleName)")
        try? fm.createDirectory(at: carried.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.copyItem(at: built, to: carried)
        setxattr(carried.path, "com.apple.quarantine", "0083;00000000;Test;", 19, 0, 0)
        PluginInstaller.testFolders = (user, all)
        PluginInstaller.testCarried = carried

        let p = PluginInstaller.shared
        p.refresh()
        check("nothing installed: offers Install", p.status == .notInstalled && p.menuTitle?.hasPrefix("Install") == true)
        do { try p.install() } catch { print("      \(error)") }
        p.refresh()
        let dest = user.appendingPathComponent(PluginInstaller.bundleName)
        check("installed into the user folder", fm.fileExists(atPath: dest.appendingPathComponent("Contents/Info.plist").path))
        check("installed: offers Remove", p.status == .installed && p.menuTitle?.hasPrefix("Remove") == true)
        check("download flag cleared", getxattr(dest.path, "com.apple.quarantine", nil, 0, 0, 0) < 0)
        check("no staging copy left", !((try? fm.contentsOfDirectory(atPath: user.path)) ?? []).contains { $0.hasPrefix(".") })

        // An older build installed under another name: found by identifier, offered as Update.
        try? fm.removeItem(at: dest)
        let old = user.appendingPathComponent("DAT Audio Plug-ins.component")
        try? fm.copyItem(at: carried, to: old)
        let plist = old.appendingPathComponent("Contents/Info.plist")
        if let d = NSMutableDictionary(contentsOf: plist) { d["CFBundleVersion"] = "1"; d.write(to: plist, atomically: true) }
        p.refresh()
        check("older copy under another name: offers Update", p.status == .older(installed: 1) && p.menuTitle?.hasPrefix("Update") == true)
        try? fm.removeItem(at: old)

        // Only in the all-users folder (from the disk image).
        try? fm.copyItem(at: carried, to: all.appendingPathComponent("DAT Audio Plug-ins.component"))
        p.refresh()
        check("all users only: explains rather than installs", p.status == .allUsersOnly)

        PluginInstaller.testFolders = nil
        PluginInstaller.testCarried = nil
        print(failures == 0 ? "All passed." : "\(failures) failed.")
        exit(failures == 0 ? 0 : 1)
    }

    static func renderAbout(to dir: String) {
        for (name, appearance) in [("dark", NSAppearance(named: .darkAqua)!), ("light", NSAppearance(named: .aqua)!)] {
            let about = NSHostingView(rootView: AboutView(tint: (ThemeColors.active(hex: ThemePreset.standard.secondary) ?? .orange)))
            about.appearance = appearance
            about.frame = NSRect(x: 0, y: 0, width: 340, height: about.fittingSize.height)
            save(about, to: "\(dir)/about-\(name).png", background: appearance)
            let lic = NSHostingView(rootView: LicencesView(entries: LicenceFiles.entries(), tint: (ThemeColors.active(hex: ThemePreset.standard.secondary) ?? .orange)))
            lic.appearance = appearance
            lic.frame = NSRect(x: 0, y: 0, width: 800, height: 460)
            save(lic, to: "\(dir)/licences-\(name).png", background: appearance)
        }
        // The credits move by themselves: the About window on screen for a few seconds.
        CreditsScrolling.testIgnoresVisibility = true
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 520), styleMask: [.titled],
                         backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: AboutView(tint: .orange))
        w.orderFrontRegardless()
        func scroller(_ v: NSView) -> NSScrollView? {
            if let s = v as? NSScrollView, s.documentView is FlippedViewMarker { return s }
            for sub in v.subviews { if let f = scroller(sub) { return f } }
            return nil
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let start = scroller(w.contentView!)?.contentView.bounds.origin.y ?? -1
        RunLoop.main.run(until: Date().addingTimeInterval(5))   // 2.5 s hold, then ~2.5 s at 20 pt/s
        let later = scroller(w.contentView!)?.contentView.bounds.origin.y ?? -1
        print(String(format: "Credits scroll: %.0f → %.0f points over 5 s (%@)", start, later,
                     NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? "Reduce motion is on: should stay" :
                     "window visibility ignored for this check"))
        print("Rendered to \(dir)")
        exit(0)
    }

    private static func save(_ view: NSView, to path: String, background: NSAppearance) {
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = background
        window.backgroundColor = background.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
