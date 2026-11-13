import SwiftUI

/// Everything the Grabber can receive, with the one
/// control each needs. Shown on an empty list at first launch, and kept in Settings → Sources
/// once streams have filled the list and the empty screen is gone.
struct SourcesGuide: View {
    @Environment(AppState.self) var state
    /// Narrower type and no icons: the compact window and the Settings pane.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            row("dot.radiowaves.left.and.right", "AES67 and RAVENNA",
                "Found by themselves, from any AES67 or RAVENNA device or software, including "
              + "the AES67 modes of Livewire+, Q-LAN and WheatNet. If none appear, check that the "
              + "network in the header is the audio network.")
            row("point.3.connected.trianglepath.dotted", "Dante, with AES67 turned on",
                "In Dante Controller, turn on AES67 for the device and give it a multicast AES67 "
              + "flow; it then appears by itself. Dante without AES67 can't be heard by this app.")
            row("macbook.and.iphone", "VBAN",
                "Network Audio Sender on another Mac, Voicemeeter and other VB-Audio apps, or any "
              + "VBAN sender pointed at this Mac. "
              + (state.vbanEnabled ? "VBAN is on." : "VBAN is off.")) {
                if !state.vbanEnabled {
                    Button("Turn on VBAN") { state.vbanEnabled = true }.controlSize(.small)
                }
                Button("Connect…") { state.connectGuideRequested = true }.controlSize(.small)
            }
            beta("antenna.radiowaves.left.and.right", "Internet radio",
                 "Icecast, SHOUTcast and plain HTTP streams in MP3, AAC or FLAC, by their web "
               + "address or an .m3u or .pls playlist.",
                 isOn: Bindable(state).webStreamsEnabled)
            beta("pc", "Scream",
                 "A free virtual sound card for Windows that sends the PC's audio over the network.",
                 isOn: Bindable(state).screamEnabled)
            beta("waveform.path", "RTP without PTP",
                 "PipeWire, PulseAudio, VLC and GStreamer senders, in L16 or L24, announced or "
               + "added by hand.",
                 isOn: Bindable(state).plainRTPEnabled)
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("A stream you know is there doesn't appear? Some devices send without "
                   + "advertising the stream on the network. Copy its SDP (a short text "
                   + "description of the stream, on the device's settings page) and paste it here.")
                    .font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
                Button("SDP Address…") { state.addStreamRequested = true }
                    .controlSize(.small).fixedSize()
            }
        }
    }

    private func row<Actions: View>(_ symbol: String, _ title: String, _ text: String,
                                    @ViewBuilder actions: () -> Actions = { EmptyView() }) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if !compact {
                Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(Color.mutedLabel)
                    .frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(text).font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) { actions() }
            }
        }
    }

    /// A beta kind: off by default, switched on right here as well as in Settings → Discovery.
    private func beta(_ symbol: String, _ title: String, _ text: String,
                      isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if !compact {
                Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(Color.mutedLabel)
                    .frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    BetaBadge()
                    Spacer(minLength: 8)
                    Toggle("", isOn: isOn).labelsHidden().controlSize(.mini)
                }
                Text(text).font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
