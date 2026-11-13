import SwiftUI

/// The connection guide's "Somewhere else": the other end is in
/// another location, across the internet. Three ways, as radio headers with one plain sentence
/// each; only the chosen one opens: the **Remote link** (recommended, the
/// default), a **VPN**, or **By address** — supported, and said plainly to be the advanced way:
/// an open port on a router, and audio crossing the internet unencrypted.
struct RemoteGuide: View {
    @Environment(AppState.self) var state
    let sending: Bool
    @State private var address = ""
    @State private var error: String?
    @State private var outside: String?
    @State private var lookupError: String?
    @State private var looking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(RemoteMethod.allCases, id: \.self) { method in
                MethodOption(method.title, tag: method.tag, summary: method.summary,
                             chosen: state.remoteMethod == method.rawValue, tint: state.tintActive,
                             choose: { withAnimation(.easeOut(duration: 0.15)) { state.remoteMethod = method.rawValue } }) {
                    switch method {
                    case .remoteLink: remoteLink
                    case .vpn: vpn
                    case .byAddress: byAddress
                    }
                }
            }
        }
    }

    /// The recommended way: this end's code, the other end's code, connected.
    @ViewBuilder private var remoteLink: some View {
        if sending, let send = state.send {
            RemoteLinkCard(sending: true, code: send.remoteCode, error: send.remoteCodeError,
                           making: send.makingRemoteCode, tint: state.tintActive,
                           make: { send.makeRemoteCode() }, link: { send.linkRemote($0) }, framed: false,
                           links: send.remoteLinkInfo, unlink: { send.unlinkRemote($0) },
                           codeMadeAt: send.remoteCodeMadeAt, useHere: { state.connectWhere = 0 },
                           paused: send.remoteLinksPaused, resume: { send.resumeRemoteLinks() })
        } else if !sending {
            RemoteLinkCard(sending: false, code: state.remoteCode, error: state.remoteCodeError,
                           making: state.makingRemoteCode, tint: state.tintActive,
                           make: { state.makeRemoteCode() }, link: { state.linkRemote($0) }, framed: false,
                           links: state.remoteLinkInfo, unlink: { state.unlinkRemote($0) },
                           codeMadeAt: state.remoteCodeMadeAt, useHere: { state.connectWhere = 0 })
            // The buffer test, where a link is set up — it was only in Settings → Playout, and not
            // found there.
            if !state.remoteLinks.isEmpty {
                Divider().padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Remote buffer").font(.system(size: 12, weight: .semibold))
                        Text(verbatim: "\(Int(state.remoteLatencyMs)) ms").font(.system(size: 12, design: .monospaced))
                        Spacer()
                    }
                    .help("For streams from somewhere else (REMOTE or VPN). Also in Settings → Playout.")
                    ConnectionTestRow()
                }
            }
        }
    }

    private var vpn: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(LocalizedStringKey("With a VPN such as Tailscale on both Macs, the other place is part of this network — "
                 + "encrypted, and nothing to open on a router. Streams are then found as usual; one that "
                 + "is not can be added by its VPN address."))
                .font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
            Button("Use On this network") { state.connectWhere = 0 }.controlSize(.small)
        }
    }

    private var byAddress: some View {
        VStack(alignment: .leading, spacing: 10) {
            RemoteWarning(receivingEnd: sending ? false : nil)
            if sending {
                section("A Grabber or other VBAN receiver somewhere else",
                        "Its router forwards UDP \(VBAN.port) to the receiving Mac or PC. Type the address "
                        + "of its network as the internet sees it, with :port if not \(VBAN.port).") {
                    field(placeholder: "203.0.113.40") { text in state.send?.addTarget(text) }
                }
            } else {
                section("A Network Audio Sender somewhere else",
                        "Its router forwards UDP \(VBANControl.controlPort) to that Mac, and **Findable by "
                        + "Grabbers** is on there. Type the address of its network as the internet sees it.") {
                    field(placeholder: "203.0.113.40") { text in state.addManualSender(text) }
                }
                section("Voicemeeter or any other VBAN sender somewhere else",
                        "It sends to this network's outside address, port \(VBAN.port), and this network's "
                        + "router forwards UDP \(VBAN.port) to this Mac"
                        + (localAddress.map { " (\($0) here)" } ?? "") + ".") {
                    EmptyView()
                }
            }
            outsideAddress
        }
    }

    /// This Mac on the chosen network, for the port forward (the harness's own in renders).
    private var localAddress: String? { state.vbanAddresses.first?.address }

    private var outsideAddress: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Button(looking ? "Finding…" : "Find this network's outside address") {
                    looking = true
                    lookupError = nil
                    OutsideAddress.lookup { result in
                        looking = false
                        switch result {
                        case .success(let ip): outside = ip
                        case .failure(let f): lookupError = f.description
                        }
                    }
                }
                .controlSize(.small).disabled(looking)
                if let outside {
                    Text(verbatim: outside).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
            }
            if let lookupError { Text(lookupError).font(.system(size: 10)).foregroundStyle(.orange) }
            Text("For the other end to type in. " + OutsideAddress.note)
                .font(.system(size: 9)).foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section<C: View>(_ title: String, _ text: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .semibold))
            Text(LocalizedStringKey(text)).font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
    }

    private func field(placeholder: String, add: @escaping (String) -> String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("", text: $address, prompt: Text(verbatim: placeholder))
                    .labelsHidden().plainEntry()
                    .textFieldStyle(.roundedBorder).frame(width: 180)
                    .onSubmit { commit(add) }
                Button("Add anyway") { commit(add) }
                    .controlSize(.small)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error { Text(error).font(.system(size: 10)).foregroundStyle(.orange) }
        }
    }

    private func commit(_ add: (String) -> String?) {
        error = add(address)
        if error == nil { address = "" }
    }
}
