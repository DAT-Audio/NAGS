import SwiftUI

/// The settings every Send has — the Sender app's, and the Grabber's own Send (Settings → Send
/// there) — so both are one set of controls.
public struct SendSettingsSections: View {
    @Environment(SenderState.self) var state
    public init() {}

    public var body: some View {
        Section("Stream") {
            LabeledContent("Name") {
                StreamNameField().labelsHidden()
            }
            LabeledContent("Quality") {
                Picker("", selection: Bindable(state).dataType) {
                    Text("16-bit").tag(VBAN.DataType.int16)
                    Text("24-bit").tag(VBAN.DataType.int24)
                }
                .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 180)
            }
            // A track is sent as wide as the host gives it; only the Mac's output has a choice.
            if !state.sendsTrack {
            // What to send: system audio, chosen apps or an input device.
            LabeledContent("Source") { SourceMenu() }
            LabeledContent("Channels") {
                if state.sendSource.isInput {
                    // An input device goes as it is.
                    Text("The device's own: \(state.captureChannels) ch")
                        .font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                } else {
                Picker("", selection: Bindable(state).stereoOnly) {
                    Text("Match output").tag(false)
                    Text("Stereo").tag(true)
                }
                .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 200)
                .help(tooltip("Match output sends as many channels as the output device "
                              + "has — six on a 5.1 device, eight on a 7.1. Stereo mixes "
                              + "everything down to two.",
                              now: state.stereoOnly ? "stereo" : "matching the output device"))
                }
            }
            }
        }

        Section {
            Toggle("Resume sending when opened", isOn: Bindable(state).resumeSending)
        } header: {
            Text("Targets")
        } footer: {
            Text("Every target is remembered; ★ pins it to the top. With this on, sending picks up "
               + "with whatever it was sending to when it was last "
               + (state.sendsTrack ? "closed." : "quit."))
                .font(.caption2).foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
        }

        // Who may listen (in every Sender's settings, the Grabber's Send too).
        Section {
            Toggle("Ask before a new Grabber listens", isOn: Bindable(state).askFirst)
                .help(tooltip("With the offer on, a Grabber you have not allowed before has to "
                            + "wait for you to press Allow. Off, any Grabber on the network can "
                            + "listen as soon as it presses play.",
                              now: state.askFirst ? "asks first" : "anyone may listen"))
            ForEach(state.allowedGrabbers.keys.sorted(), id: \.self) { ip in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield").font(.system(size: 11))
                        .foregroundStyle(Color.mutedLabel)
                    Text(verbatim: state.allowedGrabbers[ip].flatMap { $0.isEmpty ? nil : $0 } ?? "Grabber")
                        .font(.system(size: 12))
                    Text(verbatim: ip).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.mutedLabel)
                    Spacer()
                    Button("Remove") { state.revoke(ip) }.controlSize(.small)
                        .help("Stop it listening now; it has to ask again next time.")
                }
            }
            // Denied this session: changing your mind needs no relaunch.
            ForEach(state.deniedGrabbers) { grabber in
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised").font(.system(size: 11))
                        .foregroundStyle(Color.mutedLabel)
                    Text(verbatim: grabber.name ?? "Grabber").font(.system(size: 12))
                    Text(verbatim: grabber.ip).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.mutedLabel)
                    Text("Denied").font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                    Spacer()
                    Button("Allow") { state.allowDenied(grabber) }.controlSize(.small)
                        .help("Let it listen after all — it is let in the next time it asks, within 20 seconds.")
                }
            }
        } header: {
            Text("Grabbers")
        } footer: {
            Text(state.allowedGrabbers.isEmpty && state.deniedGrabbers.isEmpty
                 ? "Grabbers you allow are listed here. One you deny is refused until you allow it here, or until this is next opened."
                 : "A Grabber allowed on one of its Mac's addresses is let in from the others too. The name "
                   + "is what each Grabber calls itself. Denied ones are refused until you allow them here, "
                   + "or until this is next opened.")
                .font(.caption2).foregroundStyle(Color.mutedLabel)
        }

        Section {
            Toggle("Stop sending to receivers that can't be reached", isOn: Bindable(state).autoStopSends)
            LabeledContent("After") {
                Picker("", selection: Bindable(state).autoStopSendsMinutes) {
                    ForEach(SenderState.autoStopChoices, id: \.self) { m in
                        Text(verbatim: SenderState.minutesText(m)).tag(m)
                    }
                }
                .labelsHidden().frame(maxWidth: 120)
            }
            .disabled(!state.autoStopSends)
        } header: {
            Text("Auto-stop")
        } footer: {
            Text("Off, a target is sent to until you stop it, however long that is. On, each target is "
               + "stopped once this Mac has been unable to reach it — the host is off or has left the "
               + "network — for the time chosen, and its row says Timed out. A Grabber listening "
               + "through \u{201C}Findable by Grabbers\u{201D} that goes away is let go after 15 seconds either way. A receiver in another place, reached across the internet, can't be told to be unreachable, so it is sent to until stopped.")
                .font(.caption2).foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The Grabber's Settings → Send: its Send's own settings, apart from the Sender app's.
public struct GrabberSendSettings: View {
    let send: GrabberSend
    public init(send: GrabberSend) { self.send = send }

    public var body: some View {
        Form { SendSettingsSections() }
            .formStyle(.grouped)
            .environment(send.state)
    }
}
