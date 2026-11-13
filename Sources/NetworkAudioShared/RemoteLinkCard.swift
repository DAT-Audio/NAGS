import SwiftUI
import AppKit

/// The Remote link, as the connection guides show it: the
/// recommended way to reach another location — two steps, a code each way, no port to open.
/// One view for both ends and both apps; the end's own state is handed in.
public struct RemoteLinkCard: View {
    let sending: Bool
    let code: RemoteCode?
    let error: String?
    let making: Bool
    let tint: Color
    let make: () -> Void
    let link: (String) -> String?
    /// False inside a `MethodOption`, which already says what it is.
    let framed: Bool
    /// The other ends linked so far ("address:port"), and how to end one: any number.
    let links: [RemoteLinkInfo]
    let unlink: (String) -> Void
    /// When this end's code was made: it is good for about 15 minutes.
    let codeMadeAt: Date?
    /// Switches the guide to On this network, for a code from behind the same router.
    let useHere: (() -> Void)?
    /// Stop sending paused the links; Resume lets them in again (the sending end).
    let paused: Bool
    let resume: (() -> Void)?
    @State private var pasted = ""
    @State private var linkError: String?
    @State private var justLinked = false

    public init(sending: Bool, code: RemoteCode?, error: String?, making: Bool, tint: Color,
                make: @escaping () -> Void, link: @escaping (String) -> String?, framed: Bool = true,
                links: [RemoteLinkInfo] = [], unlink: @escaping (String) -> Void = { _ in },
                codeMadeAt: Date? = nil, useHere: (() -> Void)? = nil,
                paused: Bool = false, resume: (() -> Void)? = nil) {
        self.sending = sending; self.code = code; self.error = error; self.making = making
        self.tint = tint; self.make = make; self.link = link; self.framed = framed
        self.links = links; self.unlink = unlink; self.codeMadeAt = codeMadeAt; self.useHere = useHere
        self.paused = paused; self.resume = resume
    }

    static let codeLife: TimeInterval = 15 * 60

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if framed {
                HStack(spacing: 6) {
                    Image(systemName: "link").foregroundStyle(tint)
                    Text("Remote link").font(.system(size: 13, weight: .semibold))
                    Chip(text: "RECOMMENDED", tint: tint, filled: true)
                    Spacer()
                }
            }
            Text(sending
                 ? "With a Grabber at the other place — or several, one link each. Both ends do both steps."
                 : "With a Network Audio Sender, or a Grabber's Send, at the other place — or several, one link each. Both ends do both steps.")
                .font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
            step(1, "Make this end's code, and send it to the other end — by message or email. The same code does for every other end.") {
                HStack(spacing: 6) {
                    if let code {
                        // 51 characters since the secret went in: smaller, and free
                        // to wrap rather than be cut, since it's copied, not read.
                        Text(verbatim: code.text)
                            .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code.text, forType: .string)
                        }
                        .controlSize(.small)
                    } else {
                        Button(making ? "Making…" : "Make this end's code", action: make)
                            .controlSize(.small).disabled(making)
                    }
                }
            }
            if let error { Text(error).font(.system(size: 10)).foregroundStyle(.orange).padding(.leading, 26) }
            // How long the code is good for; a new one once it lapses.
            if code != nil, let made = codeMadeAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let left = Self.codeLife - context.date.timeIntervalSince(made)
                    HStack(spacing: 6) {
                        if left > 0 {
                            Text(verbatim: "Good for about \(max(1, Int(left / 60 + 0.5))) more minutes, to be pasted at the other end.")
                                .font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                        } else {
                            Text("This code has lapsed.").font(.system(size: 10)).foregroundStyle(.orange)
                            Button("Make a new one", action: make).controlSize(.mini).disabled(making)
                        }
                    }
                }
                .padding(.leading, 26)
            }
            Text(OutsideAddress.note)
                .font(.system(size: 9)).foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 26)
            step(2, links.isEmpty ? "Paste the other end's code." : "Paste another end's code, to link one more.") {
                HStack(spacing: 6) {
                    TextField("", text: $pasted, prompt: Text(verbatim: "NAG-…"))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced)).frame(minWidth: 220, maxWidth: .infinity)
                        .onSubmit(connect)
                        .onChange(of: pasted) { _, _ in linkError = nil; justLinked = false }
                    Button("Connect", action: connect)
                        .controlSize(.small)
                        .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let linkError {
                VStack(alignment: .leading, spacing: 5) {
                    Text(linkError).font(.system(size: 10)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if linkError == RemoteLinkInfo.sameRouter, let useHere {
                        Button("Use On this network", action: useHere).controlSize(.small)
                    }
                }
                .padding(.leading, 26)
            }
            if !links.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    // Says what the links are doing, not only that they were made: "Linked" over
                    // "Waiting for the other end" read as two answers.
                    let connected = links.filter(\.connected).count
                    HStack(spacing: 6) {
                        Image(systemName: paused ? "pause.circle.fill"
                              : connected == 0 ? "hourglass.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(paused || connected == 0 ? Color.orange : Color.green)
                        Text(paused ? "Paused"
                             : connected == 0 ? (links.count == 1 ? "Waiting for the other end" : "Waiting for the other ends")
                             : connected == links.count ? (links.count == 1 ? "Connected" : "Connected to \(links.count)")
                             : "Connected to \(connected) of \(links.count)")
                            .font(.system(size: 12, weight: .semibold))
                        RemoteBadge(encrypted: true)
                        if paused, let resume {
                            Spacer()
                            Button("Resume", action: resume).controlSize(.small)
                        }
                    }
                    if paused {
                        Text("Stop sending paused these links: nobody is let in until Resume.")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                    }
                    ForEach(links, id: \.self) { link in
                        HStack(spacing: 6) {
                            Circle().fill(link.connected ? Color.green : Color.orange).frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(verbatim: link.name ?? link.key).font(.system(size: 11, weight: .medium))
                                Text(verbatim: (link.name != nil ? link.key + " · " : "")
                                     + (link.connected ? "Connected" : "Linked here — waiting for the other end to paste this end's code"))
                                    .font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                            }
                            Spacer()
                            Button("Unlink") { unlink(link.key) }.controlSize(.mini)
                                .help("End this link: no longer let in, and no longer asked.")
                        }
                    }
                    // A link can go quiet if the other end's router gave it a new port on reopening.
                    if links.contains(where: { !$0.connected }), !paused {
                        Text("If one stays waiting after either end was reopened, swap new codes.")
                            .font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if justLinked {
                        Text(sending ? "Let in. Its row appears under Receivers when it plays the stream."
                                     : "The stream appears in the list, marked REMOTE, once the other end has pasted this end's code too.")
                            .font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Sealed end to end (`RemoteSeal`): the codes' secrets are the keys.
                    Text("Encrypted end to end: only the two ends that swapped codes can hear it, or send to it.")
                        .font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(paused || !links.contains(where: \.connected) ? Color.orange.opacity(0.08) : Color.green.opacity(0.08)))
                .help("Each link lets in exactly the address and port its code gave, and no one else.")
            }
        }
        .padding(framed ? 12 : 0)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(framed ? 0.04 : 0)))
    }

    private func connect() {
        linkError = link(pasted)
        justLinked = linkError == nil
        if justLinked { pasted = "" }
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
}
