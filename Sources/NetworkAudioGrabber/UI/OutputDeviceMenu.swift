import SwiftUI

/// The output device, chosen: the system default, which follows macOS as before, or one named device, which stays chosen
/// whatever the Mac's own setting does. Several devices at once is macOS's own Multi-Output
/// Device, made in Audio MIDI Setup and chosen here like any other.
///
/// The header's device label becomes this menu in both windows; Settings → Output has the same
/// choice as a picker (`OutputDevicePicker`). Not in a DAW, where the host is the output.
struct OutputDeviceMenu<Label: View>: View {
    @Environment(AppState.self) var state
    @ViewBuilder let label: () -> Label

    var body: some View {
        if AudioOutput.hostMode {
            label()
        } else {
            Menu {
                OutputDeviceChoices()
                Divider()
                Button("Play on several devices\u{2026}") { state.openAudioMIDISetup() }
                Button("Output settings\u{2026}") {
                    state.settingsPane = SettingsPane.output.rawValue
                    state.showSettings = true
                }
            } label: { label() }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
        }
    }
}

/// The choices themselves: System default, then every connected output device by name.
struct OutputDeviceChoices: View {
    @Environment(AppState.self) var state

    var body: some View {
        let options = state.outputDeviceOptions
        Picker("", selection: Binding(get: { state.outputDeviceUID ?? "" },
                                      set: { uid in state.chooseOutputDevice(options.first { $0.uid == uid }) })) {
            Text("System default \u{2014} \(state.systemDefaultOutputName)").tag("")
            Divider()
            ForEach(options) { option in
                Text("\(option.name)  \u{00B7}  \(option.channels) ch").tag(option.uid)
            }
            // The chosen device while it is unplugged, so the selection never shows blank.
            if let uid = state.outputDeviceUID, !options.contains(where: { $0.uid == uid }) {
                Text("\(state.outputDeviceChosenName) (not connected)").tag(uid)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

/// Settings → Output's Device row: the same choice as a pop-up.
struct OutputDevicePicker: View {
    @Environment(AppState.self) var state

    var body: some View {
        let options = state.outputDeviceOptions
        Picker("", selection: Binding(get: { state.outputDeviceUID ?? "" },
                                      set: { uid in state.chooseOutputDevice(options.first { $0.uid == uid }) })) {
            Text("System default \u{2014} \(state.systemDefaultOutputName)").tag("")
            Divider()
            ForEach(options) { option in
                Text("\(option.name)  \u{00B7}  \(option.channels) ch").tag(option.uid)
            }
            if let uid = state.outputDeviceUID, !options.contains(where: { $0.uid == uid }) {
                Text("\(state.outputDeviceChosenName) (not connected)").tag(uid)
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}
