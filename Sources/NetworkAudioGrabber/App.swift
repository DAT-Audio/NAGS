import SwiftUI
import AppKit

struct NetworkAudioGrabberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("Network Audio Grabber") {
            ContentView()
                .environment(state)
                .onAppear { state.start() }
        }
        .windowResizability(.contentMinSize)
        .commands { commands }

        // Receive / Send, non-modal, beside the main window.
        Window("Receive / Send", id: ConnectSendWindow.id) {
            ConnectSendWindow().environment(state)
        }
        .windowResizability(.contentMinSize)
    }

    @CommandsBuilder private var commands: some Commands {
            CommandGroup(replacing: .newItem) { }
            // Our own About window, with the credits scrolling under the version.
            CommandGroup(replacing: .appInfo) {
                Button("About Network Audio Grabber") { AboutWindow.show(tint: state.tintActive) }
            }
            // Settings is part of the window rather than a window of its own, so ⌘, toggles the
            // pane in place. Replacing `.appSettings` keeps it where macOS puts it, at the top
            // of the app menu, instead of adding a second item somewhere else.
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
            // Both of these are wanted while another app is in front — a DAW, or whatever is
            // playing out — so they live in a menu rather than on a button in one of the two
            // layouts. A menu shortcut only fires while Network Audio Grabber is the active app; a
            // system-wide one would need Carbon's `RegisterEventHotKey`.
            CommandMenu("Monitor") {
                Button(state.viewMode == .full ? "Compact Window" : "Full Window") {
                    state.viewMode = state.viewMode.other
                }
                .keyboardShortcut("c", modifiers: [.command, .option])

                Divider()

                Button("Reset Loudness") { state.resetLoudness() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
            // No Help book, which would say "Help isn't available": the Quick Start Guide (the
            // illustrated page, opened in the browser), then the connection guide and the log.
            CommandGroup(replacing: .help) {
                Button(QuickStart.menuTitle) {
                    if !QuickStart.open() { state.append(log: "The Quick Start Guide is missing from this build.", .warning) }
                }
                Divider()
                Button("Connect to a Sender over VBAN\u{2026}") {
                    state.connectTab = 0
                    state.connectGuideRequested = true
                }
                Button("Send This Mac\u{2019}s Audio\u{2026}") {
                    state.connectTab = 1
                    state.connectGuideRequested = true
                }
                // The DAT Audio plug-ins, which this app carries: Install, Update or
                // Remove, whichever applies. Absent from a build without them inside.
                if let title = PluginInstaller.shared.menuTitle {
                    Divider()
                    Button(title) { PluginInstaller.shared.run() }
                }
                Divider()
                Button("Show Log") {
                    state.settingsPane = SettingsPane.log.rawValue
                    state.showSettings = true
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
