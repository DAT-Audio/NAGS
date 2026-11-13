import SwiftUI

// MOCKUPS ONLY — wired to nothing. How connecting to another
// location would sit in the connection guide: one question first ("Where is the other end?"),
// then one recommended path (Remote link) and one advanced fallback (By address), and how a
// remote connection is marked on its row. Made-up names, documentation addresses, fake codes.

/// Which screen of the guide a mockup shows.
enum RemoteMockStep { case choose, here, elsewhere, elsewhereConnected, byAddress }

struct ConnectGuideRemoteMock: View {
    @Environment(AppState.self) var state
    @Environment(\.colorScheme) private var scheme
    let step: RemoteMockStep
    var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("", selection: .constant(sending ? 1 : 0)) {
                    Text("Receive").tag(0)
                    Text("Send").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                Spacer()
            }
            ConnectDirection(sending: sending)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    whereQuestion
                    switch step {
                    case .choose: EmptyView()
                    case .here: hereSummary
                    case .elsewhere, .elsewhereConnected, .byAddress: elsewhereGuide
                    }
                }
            }
        }
        .padding(16)
        .grabberLook(state)
        .background(state.surfaceWash(scheme))
    }

    // MARK: The one question

    private var chosen: Int? {
        switch step {
        case .choose: nil
        case .here: 0
        default: 1
        }
    }

    private var whereQuestion: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Where is the other end?").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 10) {
                choice(0, symbol: "house", title: "On this network",
                       text: "The same home, studio or office. Most streams here are found by themselves.")
                choice(1, symbol: "globe", title: "Somewhere else",
                       text: "Another building — home and work, say. Set up once with a code.")
            }
            Label("Already on a VPN such as Tailscale? Choose **On this network**: the VPN makes the other place part of it.",
                  systemImage: "info.circle")
                .font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func choice(_ tag: Int, symbol: String, title: String, text: String) -> some View {
        let on = chosen == tag
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(state.tintActive)
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12)).foregroundStyle(on ? state.tintActive : Color.mutedLabel)
            }
            Text(text).font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(on ? 0.08 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? state.tintActive : Color.primary.opacity(0.12), lineWidth: on ? 1.5 : 1))
    }

    // MARK: On this network — today's guide, folded to what it covers

    private var hereSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("On this network").font(.system(size: 13, weight: .semibold))
            bullet("checkmark.circle", "AES67, RAVENNA and Dante streams appear in the list by themselves.")
            bullet("1.circle", "A Network Audio Sender: turn on VBAN here, and Findable by Grabbers on the Sender.")
            bullet("2.circle", "Press play on it in the list, and allow it on the Sender if it asks.")
            bullet("plus.circle", "Anything that is not found — a Sender over a VPN, Voicemeeter, another VBAN device: add it by address.")
            Text("(Today's steps, unchanged, continue here.)").font(.system(size: 10)).italic()
                .foregroundStyle(Color.mutedLabel)
        }
    }

    // MARK: Somewhere else

    private var elsewhereGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            remoteLink
            byAddress
        }
    }

    private var remoteLink: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "link").foregroundStyle(state.tintActive)
                Text("Remote link").font(.system(size: 13, weight: .semibold))
                Chip(text: "RECOMMENDED", tint: state.tintActive, filled: true)
                Spacer()
            }
            Text("Between two Grabbers or Senders. No port to open on either router: both ends reach out at once, and only they are let in.")
                .font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
            step(1, "Make this Mac's code and send it to the other end — by message or email.") {
                HStack(spacing: 6) {
                    Text(verbatim: "NAG-7QK4-M2XD-9FTA")
                        .font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
                    Button("Copy") {}.controlSize(.small)
                }
            }
            Text("Making a code asks a public address server what this network's outside address is — nothing else is sent, and only when you press it.")
                .font(.system(size: 9)).foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 26)
            step(2, "Paste the other end's code.") {
                HStack(spacing: 6) {
                    Text(verbatim: "NAG-3HW8-QP2L-6ZRC")
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .frame(width: 190, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.2)))
                    Button(step == .elsewhereConnected ? "Connected" : "Connect") {}
                        .controlSize(.small).disabled(step == .elsewhereConnected)
                }
            }
            if step == .elsewhereConnected {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("Linked to “Home Laptop”").font(.system(size: 12, weight: .semibold))
                            RemoteBadge(encrypted: false)
                        }
                        Text("Not encrypted: someone able to see the traffic between the two places could listen. The encrypted link (SRT) is planned; this one then upgrades by itself.")
                            .font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.08)))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private var byAddress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: step == .byAddress ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(Color.mutedLabel)
                Text("By address").font(.system(size: 12, weight: .semibold))
                Chip(text: "ADVANCED", tint: .secondary)
                Spacer()
            }
            Text("For other VBAN gear — Voicemeeter, VBAN apps — or when a Remote link cannot connect.")
                .font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
            if step == .byAddress {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("**Not advised over the internet.** The receiving end has to open a port on its router (UDP 6980), which lets anyone on the internet send to it, and the audio crosses the internet unencrypted. Fine over a VPN, or for a short test.")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
                HStack(spacing: 6) {
                    Text("Their outside address").font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                    Text(verbatim: "203.0.113.40").font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .frame(width: 140, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.2)))
                    Text(verbatim: "6980").font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.2)))
                    Button("Add anyway") {}.controlSize(.small)
                }
                Text("To receive here instead: open UDP 6980 on this network's router to this Mac, and give the other end this network's outside address.")
                    .font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
    }

    private func step<C: View>(_ n: Int, _ text: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: "\(n)").font(.system(size: 11, weight: .bold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.primary.opacity(0.1)))
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Rows as they would read with remote connections among them: in the Grabber's list and in a
/// Sender's receivers.
struct RemoteRowsMock: View {
    @Environment(AppState.self) var state
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("In the Grabber's list").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.mutedLabel)
            VStack(spacing: 0) {
                row(name: "Live Room 1-8", source: "RAVENNA", remote: nil, status: "OK")
                Divider()
                row(name: "Example Stream A", source: "VBAN", remote: false, status: "OK")
                Divider()
                row(name: "Example Stream A", source: "VBAN", remote: true, status: "OK", note: "later, with SRT")
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.03)))
            Text("In a Sender's receivers").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.mutedLabel)
            VStack(spacing: 0) {
                receiver(name: "Control Room", address: "192.0.2.40", remote: nil, status: "Listening")
                Divider()
                receiver(name: "Home Laptop", address: "Remote link", remote: false, status: "Sending")
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.03)))
        }
        .padding(16)
        .grabberLook(state)
        .background(state.surfaceWash(scheme))
    }

    private func row(name: String, source: String, remote: Bool?, status: String, note: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "stop.circle.fill").font(.system(size: 15)).foregroundStyle(state.tintActive)
            Text(name).font(.system(size: 12, weight: .medium))
            if let remote { RemoteBadge(encrypted: remote) }
            if let note { Text(note).font(.system(size: 9)).italic().foregroundStyle(Color.mutedLabel) }
            Spacer()
            Chip(text: source, tint: .orange)
            Label(status, systemImage: "checkmark.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private func receiver(name: String, address: String, remote: Bool?, status: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: remote == nil ? "headphones" : "stop.circle.fill").font(.system(size: 13))
                .foregroundStyle(remote == nil ? Color.mutedLabel : state.tintActive)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 12, weight: .medium))
                    if let remote { RemoteBadge(encrypted: remote) }
                }
                Text(address).font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
            }
            Spacer()
            Label(status, systemImage: "arrow.up.forward.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }
}

// MARK: - MOCKUP: Broadcast on this network

/// The Send area's receivers header with **Broadcast…**, its sheet, and the row it makes.
struct BroadcastMock: View {
    @Environment(AppState.self) var state
    @Environment(\.colorScheme) private var scheme
    var wifi = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Receivers").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.mutedLabel)
                Spacer()
                Text("Findable by Grabbers").font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                Toggle("", isOn: .constant(false)).labelsHidden().controlSize(.mini)
                Button("Broadcast…") {}.controlSize(.small)
                Image(systemName: "plus").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.mutedLabel)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Broadcast on this network").font(.system(size: 13, weight: .semibold))
                Text("Every VBAN receiver on the network hears it — several Grabbers, Voicemeeter — with nothing to ask or type.")
                    .font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Network").font(.system(size: 11))
                    Picker("", selection: .constant(0)) {
                        Text(verbatim: wifi ? "en1 — Wi-Fi · 192.0.2.31" : "en0 — Wired · 192.0.2.30").tag(0)
                    }
                    .labelsHidden().frame(width: 240)
                }
                Label("Everyone on this network receives the audio. It is not encrypted, and stays on this network — broadcasts don't cross routers.",
                      systemImage: "info.circle")
                    .font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
                if wifi {
                    Label("Broadcasting on Wi-Fi slows the whole Wi-Fi down. Findable by Grabbers is mostly the better choice there.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Keep broadcasting when opened again", isOn: .constant(false))
                    .toggleStyle(.checkbox).font(.system(size: 11))
                HStack { Spacer(); Button("Cancel") {}; Button("Start broadcasting") {}.keyboardShortcut(.defaultAction) }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            // The row it makes.
            HStack(spacing: 8) {
                Image(systemName: "stop.circle.fill").font(.system(size: 15)).foregroundStyle(state.tintActive)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("Everyone on en0").font(.system(size: 12, weight: .medium))
                        Chip(text: "BCAST", tint: state.tintActive, filled: true)
                        ConnectionBadge(address: "192.0.2.30")
                    }
                    Text(verbatim: "broadcast 192.0.2.255").font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                }
                Spacer()
                Label("Sending", systemImage: "arrow.up.forward.circle").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.03)))
        }
        .padding(16)
        .grabberLook(state)
        .background(state.surfaceWash(scheme))
    }
}
