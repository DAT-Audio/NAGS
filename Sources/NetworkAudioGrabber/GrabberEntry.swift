import Foundation
import AppKit
// The controls, theme, meters and VBAN wire format shared with the Sender. Re-exported here so
// every file in the Grabber sees them as it did when they lived in this target.
@_exported import NetworkAudioShared
// Network Audio Sender's own state and views, for the Grabber's Send area.
@_exported import NetworkAudioSenderCore

/// The Grabber's entry point. The Grabber's code is a library, so the app and
/// the Audio Unit plugin (`NetworkAudioGrabberAU`) are built from the same sources; the app's
/// executable only calls this.
public enum GrabberEntry {
    public static func main() {
        // `--probe` runs the discovery and receive path headlessly in the terminal, which is the
        // quickest way to tell whether a stream problem is the network or this app. Everything else
        // launches the normal SwiftUI app.
        if CommandLine.arguments.contains("--probe") {
            Probe.run(arguments: CommandLine.arguments)
        } else if CommandLine.arguments.contains("--check-installer") {
            MainActor.assumeIsolated { InstallerCheck.run() }
        } else if let i = CommandLine.arguments.firstIndex(of: "--render-about"), i + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { InstallerCheck.renderAbout(to: CommandLine.arguments[i + 1]) }
        } else if CommandLine.arguments.contains("--checkdefaults") {
            DefaultsCheck.run()
        } else if CommandLine.arguments.contains("--fuzzcheck") {
            FuzzCheck.run(arguments: CommandLine.arguments)
        } else if CommandLine.arguments.contains("--checkvban") {
            VBANCheck.run()
        } else if CommandLine.arguments.contains("--selftest") {
            MainActor.assumeIsolated { SelfTest.run(arguments: CommandLine.arguments) }
        } else if CommandLine.arguments.contains("--mockup-adopt") {
            MainActor.assumeIsolated { AdoptMockups.run(arguments: CommandLine.arguments) }
        } else if CommandLine.arguments.contains("--mockup-sender") {
            MainActor.assumeIsolated { SenderCompare.run(arguments: CommandLine.arguments) }
        } else if CommandLine.arguments.contains("--mockup-compare") {
            MainActor.assumeIsolated { UICompare.run(arguments: CommandLine.arguments) }
        } else if CommandLine.arguments.contains("--mockup-ui") {
            // UI proposals from the review, to compare. Dev tooling.
            MainActor.assumeIsolated { UIMockups.run(arguments: CommandLine.arguments) }
        } else if CommandLine.arguments.contains("--mockup-headers") {
            // Header proposals for both apps, at real size. Dev tooling.
            MainActor.assumeIsolated { HeaderMockups.run(arguments: CommandLine.arguments) }
        } else if CommandLine.arguments.contains("--mockup") {
            // Layout proposals for the full window, wired to nothing. Dev tooling, like `--render`.
            MainActor.assumeIsolated { MockupPreview.run(arguments: CommandLine.arguments) }
        } else if let i = CommandLine.arguments.firstIndex(of: "--remote-code"), i + 3 < CommandLine.arguments.count {
            // Dev tool: a Remote link code for a given end, address and port (local tests).
            let a = CommandLine.arguments
            let role: RemoteCode.Role = a[i + 1] == "sending" ? .sending : .receiving
            print(RemoteCode(role: role, address: a[i + 2], port: UInt16(a[i + 3]) ?? 0).text)
            exit(0)
        } else if CommandLine.arguments.contains("--outside-address") {
            // Dev tool: the Find button's lookup, from the command line (one STUN request).
            OutsideAddress.lookup { result in
                switch result {
                case .success(let ip): print("Outside address: \(ip)")
                case .failure(let f): print("Failed: \(f)")
                }
                exit(0)
            }
            RunLoop.main.run()
        } else if let i = CommandLine.arguments.firstIndex(of: "--guide-shots"), i + 1 < CommandLine.arguments.count {
            // The quick-start guide's pictures.
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)
                app.finishLaunching()
                RenderPreview.guideShots(outDir: CommandLine.arguments[i + 1])
                exit(0)
            }
        } else if let i = CommandLine.arguments.firstIndex(of: "--mockup-remote"), i + 1 < CommandLine.arguments.count {
            // Mockups of connecting to another location.
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)
                app.finishLaunching()
                RenderPreview.remoteMockups(outDir: CommandLine.arguments[i + 1])
                exit(0)
            }
        } else if let i = CommandLine.arguments.firstIndex(of: "--mockup-send"), i + 1 < CommandLine.arguments.count {
            // Mockups of Send inside the Grabber, and of the plugin's window.
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)
                app.finishLaunching()
                RenderPreview.sendMockups(outDir: CommandLine.arguments[i + 1])
                exit(0)
            }
        } else if CommandLine.arguments.contains("--render") {
            // ImageRenderer is main-actor bound; top-level code here is not, so hop explicitly.
            MainActor.assumeIsolated { RenderPreview.run(arguments: CommandLine.arguments) }
        } else {
            NetworkAudioGrabberApp.main()
        }
    }
}
