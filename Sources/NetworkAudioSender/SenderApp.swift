import SwiftUI
import AppKit

struct NetworkAudioSenderApp: App {
    @NSApplicationDelegateAdaptor(SenderAppDelegate.self) private var delegate
    @State private var state = SenderState()

    var body: some Scene {
        WindowGroup("Network Audio Sender") {
            SenderView()
                .environment(state)
                .onAppear {
                    state.start()
                    delegate.onQuit = { [weak state] in state?.shutdown() }
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 480, height: 560)
        .commands {
            CommandGroup(replacing: .newItem) { }
            // Our own About window, with the credits scrolling under the version.
            CommandGroup(replacing: .appInfo) {
                Button("About Network Audio Sender") {
                    let dark = NSApp.keyWindow?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .aqua
                    AboutWindow.show(tint: state.theme.active(on: dark ? .dark : .light))
                }
            }
            // Settings is part of the window, as in the Grabber, so ⌘, toggles it in place.
            CommandGroup(replacing: .appSettings) {
                Button(state.showSettings ? "Close Settings" : "Settings\u{2026}") {
                    state.showSettings.toggle()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            // The header's appearance button, also here: a menu
            // item can be found by searching Help, and says all three choices at once.
            CommandGroup(before: .toolbar) {
                Picker("Appearance", selection: Bindable(state).appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                }
                // A scheme with its own look sets the appearance itself (see `AppearanceControl`).
                .disabled(state.skin.style.appearance != nil)
                Divider()
            }
            // No Help book: the Quick Start Guide, the connection guide and the log, as the Grabber.
            CommandGroup(replacing: .help) {
                Button(QuickStart.menuTitle) {
                    if !QuickStart.open() { state.note(.warning, "The Quick Start Guide is missing from this build.") }
                }
                Divider()
                Button("Connect to a Grabber over VBAN\u{2026}") { state.connectGuideRequested = true }
                Button("Show Log") {
                    state.settingsShowsLog = true
                    state.showSettings = true
                }
            }
        }
    }
}

final class SenderAppDelegate: NSObject, NSApplicationDelegate {
    var onQuit: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Stop capturing before the process goes, so the tap and its private device are torn down
    /// rather than left for the system to clean up.
    func applicationWillTerminate(_ notification: Notification) { onQuit?() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
