import SwiftUI
import AppKit

/// "Connect to a Grabber…": the main way to reach Network Audio Grabber on the same network, as
/// four short steps that tick themselves off. Offering, asking and allowing are the ordinary
/// controls of the main window; this only puts them in order and says what to do on the other
/// Mac. Below the steps, the other ways to connect, and when each is the right one.
struct ConnectToGrabber: View {
    @Environment(SenderState.self) var state
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var whereIsIt: Int
    /// `somewhereElse`: open on "Somewhere else" (the render harness).
    init(somewhereElse: Bool = false) { _whereIsIt = State(initialValue: somewhereElse ? 1 : 0) }

    private var stream: String { VBAN.wireName(state.streamName).isEmpty ? "Mac Audio" : VBAN.wireName(state.streamName) }
    private var connected: Bool { !state.listeners.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Connect to a Grabber over VBAN").font(.system(size: 15, weight: .semibold))
                Spacer()
                QuickStartLink(iconOnly: true).padding(.trailing, 6)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Label(TrustNotice.shortLine, systemImage: "lock.open")
                .font(.caption).foregroundStyle(.orange)
            // The one question first, as in the Grabber's guide.
            WhereQuestion(choice: $whereIsIt, tint: state.theme.active(on: scheme))
            if whereIsIt == 1 { somewhereElse } else { onThisNetwork }
        }
        .padding(18)
        .frame(width: 420)
    }

    // MARK: On this network — the steps as they were

    @ViewBuilder private var onThisNetwork: some View {
            Text("For Network Audio Grabber on the same network. Nothing to type. VBAN is simple, unicast "
               + "and works on any network, Wi-Fi included, which is why it is the one the Sender uses.")
                .font(.caption).foregroundStyle(Color.mutedLabel)
            step(1, done: nil,
                 "On the other Mac, open Network Audio Grabber. In Settings → Discovery, turn on VBAN.")
            step(2, done: state.offering, "Make this Mac findable by Grabbers.") {
                if !state.offering {
                    Button("Turn on") { state.offering = true }.controlSize(.small)
                }
            }
            step(3, done: !state.requests.isEmpty || connected,
                 "In the Grabber, press play on “\(stream)”.")
            step(4, done: connected, state.askFirst ? "Allow it here when it asks." : "It starts playing.") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(state.requests) { RequestRow(request: $0) }
                }
            }

            if connected {
                Label("Connected: \(state.listeners.map { $0.name ?? $0.ip }.joined(separator: ", ")) listening.",
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
            }

            Divider()
            ConnectionGuide()
    }

    // MARK: Somewhere else — the Remote link first, then a VPN, then by address

    @ViewBuilder private var somewhereElse: some View {
        let tint = state.theme.active(on: scheme)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(RemoteMethod.allCases, id: \.self) { method in
                MethodOption(method.title, tag: method.tag, summary: method.summary,
                             chosen: state.remoteMethod == method.rawValue, tint: tint,
                             choose: { withAnimation(.easeOut(duration: 0.15)) { state.remoteMethod = method.rawValue } }) {
                    switch method {
                    case .remoteLink:
                        RemoteLinkCard(sending: true, code: state.remoteCode, error: state.remoteCodeError,
                                       making: state.makingRemoteCode, tint: tint,
                                       make: { state.makeRemoteCode() }, link: { state.linkRemote($0) },
                                       framed: false, links: state.remoteLinkInfo, unlink: { state.unlinkRemote($0) },
                                       codeMadeAt: state.remoteCodeMadeAt, useHere: { whereIsIt = 0 },
                                       paused: state.remoteLinksPaused, resume: { state.resumeRemoteLinks() })
                    case .vpn:
                        VStack(alignment: .leading, spacing: 7) {
                            Text("With a VPN such as Tailscale on both Macs, the other place is part of this network — "
                                 + "encrypted, and nothing to open on a router. The Grabber then finds this Mac as usual; "
                                 + "if not, add it by its VPN address under Receivers.")
                                .font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Use On this network") { whereIsIt = 0 }.controlSize(.small)
                        }
                    case .byAddress:
                        VStack(alignment: .leading, spacing: 8) {
                            RemoteWarning(receivingEnd: false)
                            Text(verbatim: "Add the other network's outside address with + under Receivers; the router "
                                 + "there forwards UDP \(String(VBAN.port)) to the Grabber's Mac.")
                                .font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func step<Extra: View>(_ n: Int, done: Bool?, _ text: String,
                                   @ViewBuilder extra: () -> Extra = { EmptyView() }) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(done == true ? Color.green : Color.primary.opacity(0.08))
                if done == true {
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

/// A Grabber asking to listen: its name, as it reports it, and its address, which is proven.
struct RequestRow: View {
    @Environment(SenderState.self) var state
    let request: VBANOffer.Subscriber

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill").font(.system(size: 13)).foregroundStyle(.orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "\(request.name ?? "A Grabber") wants to listen")
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(verbatim: request.ip).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.mutedLabel)
            }
            Spacer(minLength: 6)
            Button("Deny") { state.decline(request) }.controlSize(.small)
            // No keyboard shortcut, on purpose: letting someone listen is a click, never a stray
            // Return meant for the address field.
            Button("Allow") { state.allow(request) }.controlSize(.small)
                // The answer being asked for, so it carries the weight; still no Return key.
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        // A card of its own above the receivers: someone is waiting on an answer.
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.40), lineWidth: 1))
        .help("The name is what that Grabber calls itself and can be anything; the address is where "
            + "it really is. Allowed Grabbers are remembered by address, under Settings.")
    }
}

/// Which way to connect, in a few plain lines. Shown under the steps and in Settings.
struct ConnectionGuide: View {
    @Environment(SenderState.self) var state

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Which way to connect").font(.system(size: 11, weight: .semibold))
            guide("Network Audio Grabber, same network",
                  "Connect… in the status bar has the steps: the Grabber finds this Mac by itself, and the audio goes only to Grabbers you allow.")
            guide("Network Audio Grabber over a VPN",
                  "Turn on Findable by Grabbers. In that Grabber, open Settings → Discovery and add this Mac's address, port \(VBANControl.controlPort):")
            let addresses = state.localAddresses
            if !addresses.isEmpty {
                Text(verbatim: addresses.joined(separator: "   "))
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.leading, 12)
            }
            guide("Any other VBAN receiver, such as Voicemeeter",
                  "Add its address with + beside Receivers. It receives the stream whether or not it asks, so only add receivers you mean to send to.")
        }
    }

    private func guide(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 11, weight: .medium))
            Text(text).font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
