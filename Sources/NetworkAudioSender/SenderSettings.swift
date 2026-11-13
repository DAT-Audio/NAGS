import SwiftUI

/// Settings, in the window as the Grabber has them. One page: the Sender has four things worth
/// setting, and a sidebar of panes for four things would be the Grabber's lesson learned
/// backwards.
struct SenderSettings: View {
    @Environment(SenderState.self) var state
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "gearshape").font(.system(size: 12))
                    .foregroundStyle(state.theme.active(on: scheme))
                Text("Settings").font(.system(size: 14, weight: .semibold))
                Picker("", selection: Bindable(state).settingsShowsLog) {
                    Text("Settings").tag(false)
                    Text("Log").tag(true)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 140)
                .padding(.leading, 8)
                Spacer(minLength: 0)
                QuickStartLink().padding(.trailing, 6)
                Button("Done") { state.showSettings = false }
                    .controlSize(.small)
                    .help("Back to sending (⌘,)")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            if state.settingsShowsLog {
                ActivityLogView(log: state.activity).padding(14)
            } else {
            Form {
                SendSettingsSections()

                Section {
                    Toggle("Show dry/wet on inserts", isOn: Bindable(state).showInsertMix)
                } header: {
                    Text("Inserts")
                } footer: {
                    Text("The audio is sent after the inserts, so every target hears them. With "
                       + "nothing loaded they are out of the path entirely.")
                        .font(.caption2).foregroundStyle(Color.mutedLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    Toggle("Mute this Mac while sending", isOn: Bindable(state).muteThisMac)
                } header: {
                    Text("This Mac")
                } footer: {
                    Text("The audio still goes to every target; only this Mac's own output is silenced, "
                       + "and only while something is being sent.")
                        .font(.caption2).foregroundStyle(Color.mutedLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    ConnectionGuide()
                }

                Section("Theme") {
                    AppearanceControl(appearance: Bindable(state).appearance, skin: state.skin)
                    ColourSchemeControls(theme: Bindable(state).theme)
                }

                Explainer(title: "What is sent, and what is left out",
                          text: "Everything this Mac is playing to its output device, on that "
                              + "device's own channels (or mixed to stereo), **except the "
                              + "Grabber and this app** — so a Mac running both cannot send the "
                              + "Grabber's playback straight back out. Capture runs only while "
                              + "something is being sent, and macOS asks once for permission to "
                              + "record this Mac's audio.\n\nThe audio is plain VBAN, so it plays "
                              + "in the Grabber, Voicemeeter and VBAN Receptor alike, and is not "
                              + "encrypted on this network. A Remote link to another place is "
                              + "encrypted end to end; so is a VPN such as Tailscale.")

                RemoveAllSettings()

                // Last, and out of the way.
                Acknowledgements()
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            }
        }
    }
}
