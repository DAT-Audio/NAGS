import SwiftUI

/// One Sender plugin's send, which a project being opened can replace under an open window.
@Observable
public final class SenderSlot {
    public var send: GrabberSend
    public init(send: GrabberSend) { self.send = send }
}

/// "DAT Audio: Sender"'s window: the Sender's own controls, in a
/// column, sending the track the plugin sits on. No receiving here — that is the Grabber plugin's job.
///
/// The same `SendControls` and `SendSettingsSections` as Network Audio Sender and the Grabber's
/// Send, so a change to either reaches this too.
public struct SenderPluginView: View {
    let slot: SenderSlot
    @State private var showingSettings = false
    @State private var connecting = false
    @Environment(\.colorScheme) private var scheme

    public init(slot: SenderSlot) { self.slot = slot }
    public init(send: GrabberSend) { slot = SenderSlot(send: send) }

    public var body: some View {
        let send = slot.send
        let state = send.state
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Sender").font(.system(size: 13, weight: .semibold))
                GrabberSendPill(send: send)
                Spacer()
                // The connection guide: on this network, or somewhere else by Remote link.
                Button("Connect…") { connecting = true }
                    .controlSize(.small)
                    .help("Connect to a Grabber — on this network, or somewhere else by Remote link.")
                Button { showingSettings.toggle() } label: {
                    Image(systemName: showingSettings ? "xmark.circle" : "gearshape").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundStyle(Color.mutedLabel)
                .help(showingSettings ? "Back to sending" : "Settings: stream, resuming, auto-stop")
                .accessibilityLabel(showingSettings ? "Close settings" : "Settings")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if showingSettings {
                Form { SendSettingsSections() }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
            } else {
                PluginPassThrough()
                Divider().opacity(0.5)
                GrabberSendTab(send: send)
            }
        }
        .frame(minWidth: 330, minHeight: 300, alignment: .topLeading)
        .environment(state)
        .background(state.theme.surfaceWash(scheme))
        .preferredColorScheme(state.skin.style.appearance ?? state.appearance.colorScheme)
        .tint(state.theme.active(on: scheme))
        .toggleStyle(ThemedSwitchStyle(tint: state.theme.active(on: scheme)))
        .environment(\.skin, state.skin)
        .sheet(isPresented: $connecting) { ConnectToGrabber().environment(state) }
    }
}

/// What the plugin sends, said once, with the one switch only a plugin has.
private struct PluginPassThrough: View {
    @Environment(SenderState.self) var state

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 6) {
            Text("Sends this track's audio — what reaches the plugin — to the receivers you turn on. "
                 + "Never this Mac's own output, so nothing loops back.")
                .font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $state.passThrough) {
                Text("Pass the track through while sending").font(.system(size: 11))
            }
            .controlSize(.mini)
            .help(tooltip("On: the track carries on to its output as usual while it is sent. Off: while "
                        + "something is being sent, the track is silent in the DAW and heard only by "
                        + "the receivers.",
                          now: state.passThrough ? "on — the track carries on" : "off — silent here while sending"))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
