import SwiftUI

/// "Connect to a Sender over VBAN…": the Grabber's half of the Sender's "Connect to a Grabber".
/// Four short steps that tick themselves off, adding a Sender by address for a VPN, and which way
/// to connect for everything else. The controls are the ordinary ones (VBAN on, play, Add); this
/// puts them in order and says what to do on the other Mac.
struct ConnectToSender: View {
    @Environment(AppState.self) var state
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var error: String?
    /// Inside the Receive / Send window or the plug-in's sheet, where it would otherwise sit narrow
    /// and to the left, unlike the Send tab: full width, no Done of its own —
    /// the window or sheet around it has the way out.
    var embedded = false

    /// Streams a Network Audio Sender is offering, as the list has them.
    private var offered: [StreamDescription] {
        state.streams.map(\.description).filter { $0.source == .vban && state.isOfferedVBAN($0.id) }
    }
    private var asking: Bool { !state.vbanApprovals.isEmpty }
    private var receiving: Bool { offered.contains { state.isSubscribed($0.id) && state.vbanApprovals[$0.id] == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Connect to a Sender over VBAN").font(.system(size: 15, weight: .semibold))
                Spacer()
                if !embedded { Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            }
            Text("For Network Audio Sender on the same network. Nothing to type.")
                .font(.caption).foregroundStyle(Color.mutedLabel)
            Label(TrustNotice.shortLine, systemImage: "lock.open")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

            step(1, done: state.vbanEnabled, "Turn on VBAN here.") {
                if !state.vbanEnabled { Button("Turn on") { state.vbanEnabled = true }.controlSize(.small) }
            }
            step(2, done: !offered.isEmpty,
                 "On the other Mac, open Network Audio Sender and turn on Findable by Grabbers.")
            step(3, done: offered.contains { state.isSubscribed($0.id) },
                 offered.isEmpty ? "Its stream appears in the list here. Press play on it."
                                 : "Press play on “\(offered.map(\.name).joined(separator: "”, “"))” in the list.")
            step(4, done: receiving, "On the Sender, press Allow when it asks.") {
                if asking {
                    Text("Asking… the Sender's user has been asked to allow this Grabber.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if receiving {
                Label("Connected.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.green)
            }
            Text("This Grabber tells the Sender its name: \(AppState.receiverName(state.vbanReceiverName)). "
               + "Change it under Settings → Discovery.")
                .font(.caption2).foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Which way to connect").font(.system(size: 11, weight: .semibold))
                guide("Network Audio Sender over a VPN",
                      "Add it by address. It has to be offering, and may ask its user first.")
                HStack(spacing: 6) {
                    TextField("", text: $address, prompt: Text(verbatim: "192.0.2.20"))
                        .labelsHidden().plainEntry()
                        .textFieldStyle(.roundedBorder).frame(width: 170)
                        .onSubmit(add)
                    Button(RemoteAddresses.isRemote(RemoteAddresses.host(address)) ? "Add anyway" : "Add", action: add)
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || !state.vbanEnabled)
                }
                .padding(.leading, 12)
                if let error { Text(error).font(.caption).foregroundStyle(.orange).padding(.leading, 12) }
                // Outside this Mac's networks: allowed, and said to be the advanced way.
                if RemoteAddresses.isRemote(RemoteAddresses.host(address)) {
                    RemoteWarning(receivingEnd: false).padding(.leading, 12)
                }
                guide("Voicemeeter or any other VBAN sender",
                      "Point it at this Mac's address and port \(String(VBAN.port)) — Settings → Discovery lists them. "
                    + "It sends whether or not this Grabber asks.")
                guide("AES67, RAVENNA, or Dante in AES67 mode",
                      "Nothing to set: streams appear in the list by themselves.")
                // The beta receivers are off by default, so nothing else says they exist.
                if !betaOff.isEmpty {
                    guide("\(betaOff) (beta)",
                          "Off by default. Switch them on under Settings → Discovery.")
                }
            }
        }
        .padding(embedded ? 14 : 18)
        .frame(width: embedded ? nil : 440)
        .frame(maxWidth: embedded ? .infinity : nil, alignment: .leading)
    }

    /// The beta kinds of source still switched off, as a list in words.
    private var betaOff: String {
        let names = [(state.webStreamsEnabled, "Internet radio"), (state.screamEnabled, "Scream"),
                     (state.plainRTPEnabled, "RTP without PTP")].filter { !$0.0 }.map(\.1)
        return ListFormatter.localizedString(byJoining: names)
    }

    private func add() {
        error = state.addManualSender(address)
        if error == nil { address = "" }
    }

    private func guide(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 11, weight: .medium))
            Text(text).font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func step<Extra: View>(_ n: Int, done: Bool, _ text: String,
                                   @ViewBuilder extra: () -> Extra = { EmptyView() }) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(done ? Color.green : Color.primary.opacity(0.08))
                if done {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text(verbatim: "\(n)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.mutedLabel)
                }
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                extra()
            }
        }
    }
}
