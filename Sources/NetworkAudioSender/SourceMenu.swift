import SwiftUI
import AppKit

/// The Source menu: what the
/// Sender — or the Grabber's Send — sends. System audio output (all apps) is the default, as
/// before; or the apps ticked in the Chosen apps sheet; or one input device, whole.
struct SourceMenu: View {
    @Environment(SenderState.self) var state
    /// The header's compact form, or the panel's fuller one.
    var compact = false
    @State private var choosingApps = false

    var body: some View {
        Menu {
            Button { state.sendSource = .system } label: {
                Label("System audio output \u{2014} all apps", systemImage: tick(state.sendSource == .system))
            }
            Button { choosingApps = true } label: {
                Label("Chosen apps\u{2026}", systemImage: tick({ if case .apps = state.sendSource { return true }; return false }()))
            }
            Divider()
            Section("An input device, whole") {
                let devices = InputDeviceCapture.inputDevices()
                if devices.isEmpty { Text("No input devices") }
                ForEach(devices) { device in
                    Button { state.sendSource = .input(uid: device.uid, name: device.name) } label: {
                        Label("\(device.name)  \u{00B7}  \(device.channels) ch",
                              systemImage: tick(state.sendSource == .input(uid: device.uid, name: device.name)))
                    }
                }
            }
        } label: {
            Label(compact ? state.sourceShort : "Source: " + state.sourceShort, systemImage: state.sourceSymbol)
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help(tooltip)
        .sheet(isPresented: $choosingApps) { ChosenAppsSheet().environment(state) }
    }

    private func tick(_ on: Bool) -> String { on ? "checkmark" : "" }

    private var tooltip: String {
        switch state.sendSource {
        case .system:
            return "Sending everything this Mac plays (except this app and the Grabber), on "
                + "\(state.outputDeviceName). Click to send chosen apps or an input device instead."
        case .apps:
            return "Sending only \(state.sourceDescription). Click to change."
        case .input(_, let name):
            return "Sending \(name), at its own channel count. Click to change."
        }
    }
}

/// Chosen apps: tick the apps to send. Remembered by bundle identifier, so an app ticked while
/// closed is picked up whenever it runs. A browser's sound comes from its helper processes,
/// which are included with it.
struct ChosenAppsSheet: View {
    @Environment(SenderState.self) var state
    @Environment(\.dismiss) private var dismiss
    @State private var apps: [RunningAudioApp] = []
    @State private var chosen: Set<String> = []
    /// Chosen when the sheet opened: their rows stay while it is open, ticked or not.
    @State private var chosenAtOpen: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Send these apps").font(.system(size: 14, weight: .semibold))
            Text("Only their sound is sent; everything else on this Mac is left out. Ticked apps are "
               + "remembered, and picked up again whenever they run. A browser's sound plays from its "
               + "helper processes, which are included with it.")
                .font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows, id: \.bundleID) { row in
                        Toggle(isOn: Binding(get: { chosen.contains(row.bundleID) },
                                             set: { on in if on { chosen.insert(row.bundleID) } else { chosen.remove(row.bundleID) } })) {
                            HStack(spacing: 8) {
                                if let icon = row.icon {
                                    Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                                } else {
                                    Image(systemName: "app").frame(width: 20, height: 20)
                                }
                                Text(row.name).font(.system(size: 13))
                                Spacer(minLength: 6)
                                if row.playing {
                                    Circle().fill(Color.green).frame(width: 7, height: 7).help("Playing sound now")
                                } else if !row.running {
                                    Text("not running").font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.vertical, 3)
                        .opacity(row.running ? 1 : 0.55)
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 320)
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text("playing sound now").font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(chosen.isEmpty ? "Choose apps" : "Send \(chosen.count) app\(chosen.count == 1 ? "" : "s")") {
                    // Running apps first, then the ones ticked while closed, in list order.
                    state.sendSource = .apps(rows.map(\.bundleID).filter(chosen.contains))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear {
            apps = RunningAudioApp.list()
            if case .apps(let ids) = state.sendSource { chosen = Set(ids); chosenAtOpen = Set(ids) }
        }
    }

    /// Running apps, then chosen apps that are not running.
    private var rows: [(bundleID: String, name: String, icon: NSImage?, playing: Bool, running: Bool)] {
        let running = apps.map { ($0.bundleID, $0.name, $0.icon, $0.playing, true) }
        let runningIDs = Set(apps.map(\.bundleID))
        let absent = chosenAtOpen.union(chosen).subtracting(runningIDs).sorted().map { id -> (String, String, NSImage?, Bool, Bool) in
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            return (id, RunningAudioApp.name(of: id), url.map { NSWorkspace.shared.icon(forFile: $0.path) }, false, false)
        }
        return (running + absent).map { (bundleID: $0.0, name: $0.1, icon: $0.2, playing: $0.3, running: $0.4) }
    }
}
