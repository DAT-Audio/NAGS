import Foundation
import WinSDK
import NetworkAudioEngine
import GrabberCore

/// The Receive / Send window (the Mac's `ConnectSendWindow`): "Connect / Send…" on the list bar
/// opens it beside the list. Each tab says first which way the audio goes, then asks where the
/// other end is — here, the guide or the Send controls; somewhere else, the Remote link, a VPN,
/// or by address.
final class ConnectWindow {
    unowned let owner: GrabberWindow
    private(set) var surface: Surface!
    var hwnd: HWND? { surface.hwnd }

    var tab = 0
    var whereChoice = 0
    var remoteMethod: Int {
        get { owner.grabber.defaults.integer(forKey: "remoteMethod") }
        set { owner.grabber.defaults.set(newValue, forKey: "remoteMethod") }
    }
    var addressDraft = ""
    var addressError: String?
    var linkDraft = ""
    var linkError: String?
    var justLinked = false
    var outside: String?
    var lookupError: String?
    var looking = false
    var guideAddress = ""
    var guideError: String?

    init(owner: GrabberWindow) {
        self.owner = owner
        surface = Surface(paint: { [unowned self] c, r in self.owner.drawConnect(c, r, self) },
                          minimum: { (460, 520) })
    }

    func show(tab: Int) {
        self.tab = tab
        if surface.hwnd == nil {
            guard owner.makeWindow(surface, title: "Connect / Send — Network Audio Grabber", width: 520, height: 680) else { return }
        }
        ShowWindow(hwnd, SW_SHOW)
        SetForegroundWindow(hwnd)
        InvalidateRect(hwnd, nil, false)
    }
}

extension GrabberWindow {
    func drawConnect(_ c: Canvas, _ client: RECT, _ cw: ConnectWindow) {
        let pad = c.s(16)
        var y = client.top + pad
        let left = client.left + pad, right = client.right - pad
        // Receive / Send, the Quick Start Guide, and the Sending pill.
        let seg = RECT(x: left, y: y, width: c.s(200), height: c.s(24))
        for (i, r) in c.segmented(["Receive", "Send"], seg, selected: cw.tab).enumerated() {
            hit(r, "cwtab-\(i)") { _ in cw.tab = i }
        }
        let qf = c.font(11)
        let qs = "Quick Start Guide"
        let qr = RECT(left: right - c.width(qs, qf) - c.s(18), top: y, right: right, bottom: y + c.s(24))
        c.icon("\u{E897}", RECT(x: qr.left, y: qr.top, width: c.s(14), height: qr.height), size: 10, c.p.active)
        c.text(qs, RECT(left: qr.left + c.s(18), top: qr.top, right: qr.right, bottom: qr.bottom), qf, isHover("cwqs") ? c.p.text : c.p.active)
        hit(qr, "cwqs") { [unowned self] _ in self.open(besideApp: "QUICK-START.html") }
        drawSendingPill(c, right: qr.left - c.s(10), centreY: y + c.s(12)) { cw.tab = 1 }
        y = seg.bottom + c.s(12)

        // Which way the audio goes, said before anything else.
        let sending = cw.tab == 1
        let dirText = sending ? "For another Grabber, Voicemeeter or any VBAN receiver. Everything this PC plays goes to the receivers you turn on — "
                                + "including what this Grabber plays, so don't send to a Grabber whose stream you are playing here."
                              : "For a computer running Network Audio Sender. Its stream appears in this Grabber's list; AES67, RAVENNA and Dante need nothing here."
        let dirH = c.wrappedHeight(dirText, width: right - left - c.s(52), c.font(11)) + c.s(40)
        let dir = RECT(left: left, top: y, right: right, bottom: y + dirH)
        c.round(dir, 8, c.p.label, alpha: 0.05)
        c.icon(sending ? "\u{E898}" : "\u{E896}", RECT(x: dir.left + c.s(10), y: dir.top + c.s(10), width: c.s(24), height: c.s(24)), size: 20, c.p.active)
        c.text(sending ? "Send this PC's audio to other receivers" : "Receive from Network Audio Sender on another computer",
               RECT(left: dir.left + c.s(44), top: dir.top + c.s(10), right: dir.right - c.s(10), bottom: dir.top + c.s(28)), c.font(13, .semibold), c.p.text)
        c.wrapped(dirText, RECT(left: dir.left + c.s(44), top: dir.top + c.s(30), right: dir.right - c.s(10), bottom: dir.bottom), c.font(11), c.p.muted)
        y = dir.bottom + c.s(12)

        // Where is the other end?
        c.text("Where is the other end?", RECT(left: left, top: y, right: right, bottom: y + c.s(18)), c.font(12, .semibold), c.p.text)
        y += c.s(22)
        let cardW = (right - left - c.s(10)) / 2
        for (i, (glyph, title, text)) in [("\u{E80F}", "On this network", "The same home, studio or office. Most streams here are found by themselves."),
                                          ("\u{E774}", "Somewhere else", "Another building — home and work, say — across the internet.")].enumerated() {
            let card = RECT(x: left + Int32(i) * (cardW + c.s(10)), y: y, width: cardW, height: c.s(70))
            let on = cw.whereChoice == i
            c.round(card, 8, c.p.label, alpha: on ? 0.08 : 0.03, border: on ? c.p.active : c.p.label, borderAlpha: on ? 1 : 0.12,
                    borderWidth: on ? 1.5 : 1)
            c.icon(glyph, RECT(x: card.left + c.s(9), y: card.top + c.s(8), width: c.s(14), height: c.s(16)), size: 12, c.p.active)
            c.text(title, RECT(left: card.left + c.s(28), top: card.top + c.s(8), right: card.right - c.s(24), bottom: card.top + c.s(24)), c.font(12, .semibold), c.p.text)
            let radio = RECT(x: card.right - c.s(21), y: card.top + c.s(10), width: c.s(12), height: c.s(12))
            c.ellipse(radio, nil, border: on ? c.p.active : c.p.muted, borderWidth: 1.2)
            if on { c.ellipse(radio.inset(by: c.s(3)), c.p.active) }
            c.wrapped(text, RECT(left: card.left + c.s(9), top: card.top + c.s(28), right: card.right - c.s(9), bottom: card.bottom), c.font(10), c.p.muted)
            hit(card, "cwwhere-\(i)") { _ in cw.whereChoice = i }
        }
        y += c.s(76)
        y += c.rich("Already on a VPN such as Tailscale? Choose **On this network**: the VPN makes the other place part of it.",
                    RECT(left: left, top: y, right: right, bottom: y + c.s(40)), size: 10, c.p.muted) + c.s(8)

        let content = RECT(left: client.left, top: y, right: client.right, bottom: client.bottom - c.s(8))
        if cw.whereChoice == 0 && sending {
            c.round(RECT(left: left, top: content.top, right: right, bottom: content.bottom), 8, c.p.label, alpha: 0.03)
            drawSendTab(c, RECT(left: left, top: content.top, right: right, bottom: content.bottom), compact: false)
            return
        }
        let offset = beginScroll("connect-\(cw.tab)-\(cw.whereChoice)", content, c)
        var cy = content.top - offset
        if cw.whereChoice == 0 {
            cy = drawReceiveGuide(c, RECT(left: left, top: cy, right: right, bottom: cy), cw)
        } else {
            cy = drawRemoteGuide(c, RECT(left: left, top: cy, right: right, bottom: cy), cw, sending: sending)
        }
        endScroll("connect-\(cw.tab)-\(cw.whereChoice)", content: cy - (content.top - offset) + c.s(8), c)
    }

    // MARK: - On this network, receiving (the Mac's `ConnectToSender`)

    private func drawReceiveGuide(_ c: Canvas, _ r: RECT, _ cw: ConnectWindow) -> Int32 {
        let left = r.left + c.s(12), right = r.right - c.s(12)
        var y = r.top + c.s(12)
        let offered = grabber.streams.map(\.description).filter { $0.source == .vban && grabber.isOfferedVBAN($0.id) }
        let asking = !grabber.vbanApprovals.isEmpty
        let receiving = offered.contains { grabber.isSubscribed($0.id) && grabber.vbanApprovals[$0.id] == nil }
        // The card's heading, as the Mac's `ConnectToSender`.
        c.text("Connect to a Sender over VBAN", RECT(left: left, top: y, right: right, bottom: y + c.s(20)), c.font(15, .semibold), c.p.text)
        y += c.s(26)
        c.text("For Network Audio Sender on the same network. Nothing to type.", RECT(left: left, top: y, right: right, bottom: y + c.s(16)),
               c.font(11), c.p.muted)
        y += c.s(20)
        y += c.wrapped("Not encrypted: use this on a network you trust, such as at home, in a studio or an office.",
                       RECT(left: left + c.s(18), top: y, right: right, bottom: y + c.s(40)), c.font(11), c.p.warning) + c.s(10)
        c.icon("\u{E785}", RECT(x: left, y: y - c.s(26), width: c.s(14), height: c.s(14)), size: 10, c.p.warning)

        func step(_ n: Int, done: Bool, _ text: String, button: (String, () -> Void)? = nil, extra: String? = nil) {
            let dot = RECT(x: left, y: y, width: c.s(18), height: c.s(18))
            c.ellipse(dot, done ? c.p.green : c.p.label, alpha: done ? 1 : 0.08)
            if done { c.icon("\u{E73E}", dot, size: 9, .white) }
            else { c.text("\(n)", dot, c.font(10, .semibold), c.p.muted, align: .centre) }
            let tx = dot.right + c.s(10)
            y += c.wrapped(text, RECT(left: tx, top: y + c.s(1), right: right, bottom: y + c.s(60)), c.font(12), c.p.text) + c.s(4)
            if let (title, action) = button {
                let w = c.buttonWidth(title)
                let b = RECT(x: tx, y: y, width: w, height: c.s(20))
                c.button(title, b, hover: isHover("step-\(n)"))
                hit(b, "step-\(n)") { _ in action() }
                y += c.s(24)
            }
            if let extra {
                y += c.wrapped(extra, RECT(left: tx, top: y, right: right, bottom: y + c.s(40)), c.font(11), c.p.warning) + c.s(4)
            }
            y += c.s(8)
        }
        step(1, done: grabber.vbanEnabled, "Turn on VBAN here.",
             button: grabber.vbanEnabled ? nil : ("Turn on", { [unowned self] in self.grabber.vbanEnabled = true }))
        step(2, done: !offered.isEmpty, "On the other computer, open Network Audio Sender and turn on Findable by Grabbers.")
        step(3, done: offered.contains { grabber.isSubscribed($0.id) },
             offered.isEmpty ? "Its stream appears in the list here. Press play on it."
                             : "Press play on “\(offered.map(\.name).joined(separator: "”, “"))” in the list.")
        step(4, done: receiving, "On the Sender, press Allow when it asks.",
             extra: asking ? "Asking… the Sender's user has been asked to allow this Grabber." : nil)
        if receiving {
            c.icon("\u{E73E}", RECT(x: left, y: y, width: c.s(14), height: c.s(16)), size: 10, c.p.green)
            c.text("Connected.", RECT(left: left + c.s(18), top: y, right: right, bottom: y + c.s(16)), c.font(12, .medium), c.p.green)
            y += c.s(22)
        }
        y += c.wrapped("This Grabber tells the Sender its name: \(GrabberEngine.receiverName(grabber.vbanReceiverName)). Change it under Settings → Discovery.",
                       RECT(left: left, top: y, right: right, bottom: y + c.s(40)), c.font(10), c.p.muted) + c.s(10)
        c.hline(y, left, right, c.p.divider)
        y += c.s(10)
        c.text("Which way to connect", RECT(left: left, top: y, right: right, bottom: y + c.s(16)), c.font(11, .semibold), c.p.text)
        y += c.s(20)
        func guide(_ title: String, _ text: String) {
            c.text(title, RECT(left: left, top: y, right: right, bottom: y + c.s(15)), c.font(11, .medium), c.p.text)
            y += c.s(15)
            y += c.wrapped(text, RECT(left: left, top: y, right: right, bottom: y + c.s(60)), c.font(11), c.p.muted) + c.s(8)
        }
        guide("Network Audio Sender over a VPN", "Add it by address. It has to be offering, and may ask its user first.")
        let fieldRect = RECT(x: left + c.s(12), y: y, width: c.s(170), height: c.s(22))
        fieldFrames["guideaddr"] = fieldRect
        c.field(fieldKey == "guideaddr" ? "" : cw.guideAddress, fieldRect, placeholder: "192.0.2.20", hover: isHover("guideaddr"))
        let commit: (String) -> Void = { [unowned self] text in
            cw.guideAddress = text
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            cw.guideError = self.grabber.addManualSender(text)
            if cw.guideError == nil { cw.guideAddress = "" }
        }
        hit(fieldRect, "guideaddr") { [unowned self] _ in self.beginField("guideaddr", frame: fieldRect, text: cw.guideAddress, commit: commit) }
        let remote = RemoteAddresses.isRemote(RemoteAddresses.host(cw.guideAddress))
        let addTitle = remote ? "Add anyway" : "Add"
        let aw = c.buttonWidth(addTitle)
        let add = RECT(x: fieldRect.right + c.s(6), y: y + c.s(1), width: aw, height: c.s(20))
        let canAdd = grabber.vbanEnabled
        c.button(addTitle, add, hover: isHover("guideadd"), enabled: canAdd)
        hit(add, "guideadd") { [unowned self] _ in
            guard canAdd else { return }
            if self.fieldKey == "guideaddr" { self.commitField() } else { commit(cw.guideAddress) }
        }
        y = fieldRect.bottom + c.s(6)
        if let error = cw.guideError {
            y += c.wrapped(error, RECT(left: left + c.s(12), top: y, right: right, bottom: y + c.s(40)), c.font(11), c.p.warning) + c.s(4)
        }
        if remote { y = drawRemoteWarning(c, RECT(left: left + c.s(12), top: y, right: right, bottom: y), receivingEnd: false) }
        y += c.s(6)
        guide("Voicemeeter or any other VBAN sender",
              "Point it at this PC's address and port \(VBAN.port) — Settings → Discovery lists them. It sends whether or not this Grabber asks.")
        guide("AES67, RAVENNA, or Dante in AES67 mode", "Nothing to set: streams appear in the list by themselves.")
        let betaOff = [(grabber.screamEnabled, "Scream"), (grabber.plainRTPEnabled, "RTP without PTP")].filter { !$0.0 }.map(\.1)
        if !betaOff.isEmpty {
            guide("\(betaOff.joined(separator: " and ")) (beta)", "Off by default. Switch them on under Settings → Discovery.")
        }
        return y
    }

    func drawRemoteWarning(_ c: Canvas, _ r: RECT, receivingEnd: Bool?) -> Int32 {
        let text = "**\(RemoteAddresses.warningTitle)** " + RemoteAddresses.warning(receivingEnd: receivingEnd)
        let h = c.wrappedHeight(text.replacingOccurrences(of: "**", with: ""), width: r.width - c.s(36), c.font(11)) + c.s(20)
        let box = RECT(left: r.left, top: r.top, right: r.right, bottom: r.top + h)
        c.round(box, 6, Colour(1, 0.58, 0), alpha: 0.12)
        c.icon("\u{E7BA}", RECT(x: box.left + c.s(9), y: box.top + c.s(9), width: c.s(14), height: c.s(14)), size: 11, c.p.warning)
        c.rich(text, RECT(left: box.left + c.s(30), top: box.top + c.s(9), right: box.right - c.s(9), bottom: box.bottom), size: 11, c.p.text)
        return box.bottom + c.s(8)
    }

    // MARK: - Somewhere else (the Mac's `RemoteGuide`)

    private func drawRemoteGuide(_ c: Canvas, _ r: RECT, _ cw: ConnectWindow, sending: Bool) -> Int32 {
        var y = r.top
        let methods: [(String, String?, String)] = [
            ("Remote link", "RECOMMENDED", "Swap a code with the other end. Encrypted, and nothing to set up on a router."),
            ("VPN", nil, "Already use Tailscale or similar? The other place is then part of your network."),
            ("By address", nil, "For other VBAN senders and receivers, such as Voicemeeter. Needs a port opened on a router."),
        ]
        for (i, (title, tag, summary)) in methods.enumerated() {
            let chosen = cw.remoteMethod == i
            let headH = c.wrappedHeight(summary, width: r.width - c.s(50), c.font(11)) + c.s(34)
            // Draw the details first into a measured height: lay out, then box.
            let detailTop = y + headH + 1
            var detailBottom = detailTop
            if chosen {
                let inner = RECT(left: r.left + c.s(12), top: detailTop + c.s(10), right: r.right - c.s(12), bottom: detailTop)
                switch i {
                case 0: detailBottom = drawRemoteLink(c, inner, cw, sending: sending) + c.s(10)
                case 1: detailBottom = drawVPNOption(c, inner, cw) + c.s(10)
                default: detailBottom = drawByAddress(c, inner, cw, sending: sending) + c.s(10)
                }
            }
            let box = RECT(left: r.left, top: y, right: r.right, bottom: chosen ? detailBottom : y + headH)
            c.round(box, 8, c.p.label, alpha: chosen ? 0.05 : 0.02, border: chosen ? c.p.active : c.p.label,
                    borderAlpha: chosen ? 0.8 : 0.12, borderWidth: chosen ? 1.5 : 1)
            let radio = RECT(x: box.left + c.s(10), y: y + c.s(11), width: c.s(13), height: c.s(13))
            c.ellipse(radio, nil, border: chosen ? c.p.active : c.p.muted, borderWidth: 1.2)
            if chosen { c.ellipse(radio.inset(by: c.s(3)), c.p.active) }
            let tf = c.font(12, .semibold)
            c.text(title, RECT(left: radio.right + c.s(9), top: y + c.s(9), right: radio.right + c.s(9) + c.width(title, tf) + 2, bottom: y + c.s(26)), tf, c.p.text)
            if let tag { _ = c.chip(tag, x: radio.right + c.s(15) + c.width(title, tf), centreY: y + c.s(17), tint: c.p.active, filled: true) }
            c.wrapped(summary, RECT(left: radio.right + c.s(9), top: y + c.s(27), right: box.right - c.s(10), bottom: y + headH), c.font(11), c.p.muted)
            hit(RECT(left: box.left, top: y, right: box.right, bottom: y + headH), "method-\(i)") { _ in cw.remoteMethod = i }
            if chosen { c.hline(y + headH, box.left + c.s(1), box.right - c.s(1), c.p.hairline) }
            y = box.bottom + c.s(8)
        }
        return y
    }

    /// The Remote link card: this end's code, the other end's code, connected.
    private func drawRemoteLink(_ c: Canvas, _ r: RECT, _ cw: ConnectWindow, sending: Bool) -> Int32 {
        let s = send?.sender
        let code: RemoteCode? = sending ? s?.remoteCode : grabber.remoteCode
        let error: String? = sending ? s?.remoteCodeError : grabber.remoteCodeError
        let making = sending ? (s?.makingRemoteCode ?? false) : grabber.makingRemoteCode
        let links: [RemoteLinkInfo] = sending ? (s?.remoteLinkInfo ?? []) : grabber.remoteLinkInfo
        let madeAt: Date? = sending ? s?.remoteCodeMadeAt : grabber.remoteCodeMadeAt
        let paused = sending ? (s?.remoteLinksPaused ?? false) : false
        let make: () -> Void = { [unowned self] in if sending { s?.makeRemoteCode() } else { self.grabber.makeRemoteCode() } }
        let link: (String) -> String? = { [unowned self] text in sending ? s?.linkRemote(text) : self.grabber.linkRemote(text) }
        let unlink: (String) -> Void = { [unowned self] key in if sending { s?.unlinkRemote(key) } else { self.grabber.unlinkRemote(key) } }

        let left = r.left, right = r.right
        var y = r.top
        y += c.wrapped(sending ? "With a Grabber at the other place — or several, one link each. Both ends do both steps."
                               : "With a Network Audio Sender, or a Grabber's Send, at the other place — or several, one link each. Both ends do both steps.",
                       RECT(left: left, top: y, right: right, bottom: y + c.s(40)), c.font(11), c.p.muted) + c.s(9)
        func stepHead(_ n: Int, _ text: String) {
            let dot = RECT(x: left, y: y, width: c.s(18), height: c.s(18))
            c.ellipse(dot, c.p.label, alpha: 0.1)
            c.text("\(n)", dot, c.font(11, .bold), c.p.text, align: .centre)
            y += c.wrapped(text, RECT(left: left + c.s(26), top: y + c.s(1), right: right, bottom: y + c.s(60)), c.font(11), c.p.text) + c.s(6)
        }
        stepHead(1, "Make this end's code, and send it to the other end — by message or email. The same code does for every other end.")
        let x0 = left + c.s(26)
        if let code {
            let mono = c.font(11)
            let h = c.wrappedHeight(code.text, width: right - x0 - c.s(80), mono) + c.s(8)
            let box = RECT(left: x0, top: y, right: right - c.s(66), bottom: y + h)
            c.round(box, 5, c.p.label, alpha: 0.07)
            c.wrapped(code.text, RECT(left: box.left + c.s(8), top: box.top + c.s(4), right: box.right - c.s(8), bottom: box.bottom), mono, c.p.text)
            let cb = RECT(x: right - c.s(58), y: y, width: c.s(58), height: c.s(20))
            c.button("Copy", cb, hover: isHover("copycode"))
            hit(cb, "copycode") { [unowned self] _ in self.copyToClipboard(code.text) }
            y = box.bottom + c.s(6)
            if let made = madeAt {
                let left = 15 * 60 - Date().timeIntervalSince(made)
                if left > 0 {
                    c.text("Good for about \(max(1, Int(left / 60 + 0.5))) more minutes, to be pasted at the other end.",
                           RECT(left: x0, top: y, right: right, bottom: y + c.s(14)), c.font(10), c.p.muted)
                    y += c.s(16)
                } else {
                    c.text("This code has lapsed.", RECT(left: x0, top: y, right: x0 + c.s(130), bottom: y + c.s(18)), c.font(10), c.p.warning)
                    let w = c.buttonWidth("Make a new one", size: 10)
                    let b = RECT(x: x0 + c.s(130), y: y, width: w, height: c.s(18))
                    c.button("Make a new one", b, hover: isHover("remake"), enabled: !making, size: 10)
                    hit(b, "remake") { _ in if !making { make() } }
                    y += c.s(22)
                }
            }
        } else {
            let title = making ? "Making…" : "Make this end's code"
            let w = c.buttonWidth(title)
            let b = RECT(x: x0, y: y, width: w, height: c.s(20))
            c.button(title, b, hover: isHover("makecode"), enabled: !making)
            hit(b, "makecode") { _ in if !making { make() } }
            y += c.s(26)
        }
        if let error { y += c.wrapped(error, RECT(left: x0, top: y, right: right, bottom: y + c.s(40)), c.font(10), c.p.warning) + c.s(4) }
        y += c.wrapped(OutsideAddress.note, RECT(left: x0, top: y, right: right, bottom: y + c.s(40)), c.font(9), c.p.muted) + c.s(10)

        stepHead(2, links.isEmpty ? "Paste the other end's code." : "Paste another end's code, to link one more.")
        let fieldRect = RECT(left: x0, top: y, right: right - c.s(84), bottom: y + c.s(22))
        fieldFrames["linkcode"] = fieldRect
        c.field(fieldKey == "linkcode" ? "" : cw.linkDraft, fieldRect, placeholder: "NAG-…", hover: isHover("linkcode"))
        let commit: (String) -> Void = { text in
            cw.linkDraft = text
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            cw.linkError = link(text)
            cw.justLinked = cw.linkError == nil
            if cw.justLinked { cw.linkDraft = "" }
        }
        hit(fieldRect, "linkcode") { [unowned self] _ in
            cw.linkError = nil; cw.justLinked = false
            self.beginField("linkcode", frame: fieldRect, text: cw.linkDraft, commit: commit)
        }
        let cbw = c.buttonWidth("Connect")
        let connectB = RECT(x: right - cbw, y: y + c.s(1), width: cbw, height: c.s(20))
        c.button("Connect", connectB, hover: isHover("linkgo"))
        hit(connectB, "linkgo") { [unowned self] _ in if self.fieldKey == "linkcode" { self.commitField() } else { commit(cw.linkDraft) } }
        y = fieldRect.bottom + c.s(6)
        if let e = cw.linkError {
            y += c.wrapped(e, RECT(left: x0, top: y, right: right, bottom: y + c.s(60)), c.font(10), c.p.warning) + c.s(4)
            if e == RemoteLinkInfo.sameRouter {
                let w = c.buttonWidth("Use On this network")
                let b = RECT(x: x0, y: y, width: w, height: c.s(20))
                c.button("Use On this network", b, hover: isHover("usehere"))
                hit(b, "usehere") { _ in cw.whereChoice = 0 }
                y += c.s(26)
            }
        }
        if !links.isEmpty {
            let connected = links.filter(\.connected).count
            let status = paused ? "Paused" : connected == 0 ? (links.count == 1 ? "Waiting for the other end" : "Waiting for the other ends")
                : connected == links.count ? (links.count == 1 ? "Connected" : "Connected to \(links.count)") : "Connected to \(connected) of \(links.count)"
            let good = !paused && connected > 0
            var lines = Int32(links.count) * c.s(30) + c.s(64)
            if paused { lines += c.s(16) }
            let box = RECT(left: left, top: y, right: right, bottom: y + lines)
            c.round(box, 6, good ? c.p.green : Colour(1, 0.58, 0), alpha: 0.08)
            var ly = box.top + c.s(8)
            c.icon(good ? "\u{E73E}" : (paused ? "\u{E769}" : "\u{E823}"), RECT(x: box.left + c.s(8), y: ly, width: c.s(14), height: c.s(16)), size: 11,
                   good ? c.p.green : c.p.warning)
            c.text(status + "  ·  encrypted", RECT(left: box.left + c.s(28), top: ly, right: box.right - c.s(80), bottom: ly + c.s(16)), c.font(12, .semibold), c.p.text)
            if paused, sending, let s {
                let w = c.buttonWidth("Resume")
                let b = RECT(x: box.right - c.s(8) - w, y: ly - c.s(2), width: w, height: c.s(20))
                c.button("Resume", b, hover: isHover("resumelinks"))
                hit(b, "resumelinks") { _ in s.resumeRemoteLinks() }
                ly += c.s(18)
                c.text("Stop sending paused these links: nobody is let in until Resume.", RECT(left: box.left + c.s(28), top: ly, right: box.right, bottom: ly + c.s(14)),
                       c.font(10), c.p.warning)
            }
            ly += c.s(22)
            for l in links {
                c.ellipse(RECT(x: box.left + c.s(10), y: ly + c.s(9), width: c.s(6), height: c.s(6)), l.connected ? c.p.green : c.p.warning)
                c.text(l.name ?? l.key, RECT(left: box.left + c.s(22), top: ly, right: box.right - c.s(70), bottom: ly + c.s(15)), c.font(11, .medium), c.p.text)
                c.text((l.name != nil ? l.key + " · " : "") + (l.connected ? "Connected" : "Linked here — waiting for the other end to paste this end's code"),
                       RECT(left: box.left + c.s(22), top: ly + c.s(14), right: box.right - c.s(70), bottom: ly + c.s(28)), c.font(10), c.p.muted)
                let w = c.buttonWidth("Unlink", size: 10)
                let b = RECT(x: box.right - c.s(8) - w, y: ly + c.s(4), width: w, height: c.s(18))
                c.button("Unlink", b, hover: isHover("unlink-\(l.key)"), size: 10)
                hit(b, "unlink-\(l.key)", tip: "End this link: no longer let in, and no longer asked.") { _ in unlink(l.key) }
                ly += c.s(30)
            }
            c.text("Encrypted end to end: only the two ends that swapped codes can hear it, or send to it.",
                   RECT(left: box.left + c.s(10), top: ly, right: box.right - c.s(8), bottom: ly + c.s(14)), c.font(10), c.p.muted)
            y = box.bottom + c.s(6)
            if cw.justLinked {
                y += c.wrapped(sending ? "Let in. Its row appears under Receivers when it plays the stream."
                                       : "The stream appears in the list, marked REMOTE, once the other end has pasted this end's code too.",
                               RECT(left: left, top: y, right: right, bottom: y + c.s(40)), c.font(10), c.p.muted) + c.s(4)
            }
        }
        if !sending && !grabber.remoteLinks.isEmpty {
            c.hline(y + c.s(4), left, right, c.p.divider)
            y += c.s(10)
            c.text("Remote buffer  \(Int(grabber.remoteLatencyMs)) ms", RECT(left: left, top: y, right: right, bottom: y + c.s(16)), c.font(12, .semibold), c.p.text)
            hit(RECT(left: left, top: y, right: right, bottom: y + c.s(16)), "remotebuffer",
                tip: "For streams from somewhere else (REMOTE or VPN). Also in Settings → Playout.")
            y += c.s(20)
            let remote = grabber.playingRemoteStreams
            let title: String
            if case .running = grabber.connectionTest { title = "Testing…" } else { title = "Test the connection" }
            let w = c.buttonWidth(title)
            let b = RECT(x: left, y: y, width: w, height: c.s(20))
            c.button(title, b, hover: isHover("ctest2"), enabled: !remote.isEmpty)
            hit(b, "ctest2") { [unowned self] _ in if let id = remote.first?.id { self.grabber.testConnection(id) } }
            y += c.s(26)
        }
        return y
    }

    private func drawVPNOption(_ c: Canvas, _ r: RECT, _ cw: ConnectWindow) -> Int32 {
        var y = r.top
        y += c.rich("With a VPN such as Tailscale on both computers, the other place is part of this network — encrypted, and nothing to open on a "
                    + "router. Streams are then found as usual; one that is not can be added by its VPN address.",
                    RECT(left: r.left, top: y, right: r.right, bottom: y + c.s(80)), size: 11, c.p.muted) + c.s(6)
        let w = c.buttonWidth("Use On this network")
        let b = RECT(x: r.left, y: y, width: w, height: c.s(20))
        c.button("Use On this network", b, hover: isHover("vpnhere"))
        hit(b, "vpnhere") { _ in cw.whereChoice = 0 }
        return b.bottom
    }

    private func drawByAddress(_ c: Canvas, _ r: RECT, _ cw: ConnectWindow, sending: Bool) -> Int32 {
        var y = drawRemoteWarning(c, r, receivingEnd: sending ? false : nil)
        func section(_ title: String, _ text: String, field: Bool) {
            c.text(title, RECT(left: r.left, top: y, right: r.right, bottom: y + c.s(15)), c.font(11, .semibold), c.p.text)
            y += c.s(16)
            y += c.rich(text, RECT(left: r.left, top: y, right: r.right, bottom: y + c.s(80)), size: 11, c.p.muted) + c.s(5)
            guard field else { y += c.s(6); return }
            let f = RECT(x: r.left, y: y, width: c.s(180), height: c.s(22))
            fieldFrames["byaddr"] = f
            c.field(fieldKey == "byaddr" ? "" : cw.addressDraft, f, placeholder: "203.0.113.40", hover: isHover("byaddr"))
            let commit: (String) -> Void = { [unowned self] text in
                cw.addressDraft = text
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                if sending {
                    guard let s = self.send?.sender else { return }
                    let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1)
                    s.draftHost = String(parts[0])
                    s.draftPort = parts.count > 1 ? String(parts[1]) : String(VBAN.port)
                    s.draftError = nil
                    cw.addressError = s.addDraft() ? nil : s.draftError
                } else {
                    cw.addressError = self.grabber.addManualSender(text)
                }
                if cw.addressError == nil { cw.addressDraft = "" }
            }
            hit(f, "byaddr") { [unowned self] _ in self.beginField("byaddr", frame: f, text: cw.addressDraft, commit: commit) }
            let w = c.buttonWidth("Add anyway")
            let b = RECT(x: f.right + c.s(6), y: y + c.s(1), width: w, height: c.s(20))
            c.button("Add anyway", b, hover: isHover("byaddrgo"))
            hit(b, "byaddrgo") { [unowned self] _ in if self.fieldKey == "byaddr" { self.commitField() } else { commit(cw.addressDraft) } }
            y = f.bottom + c.s(4)
            if let e = cw.addressError { y += c.wrapped(e, RECT(left: r.left, top: y, right: r.right, bottom: y + c.s(40)), c.font(10), c.p.warning) + c.s(4) }
            y += c.s(8)
        }
        if sending {
            section("A Grabber or other VBAN receiver somewhere else",
                    "Its router forwards UDP \(VBAN.port) to the receiving computer. Type the address of its network as the internet sees it, with :port if not \(VBAN.port).",
                    field: true)
        } else {
            section("A Network Audio Sender somewhere else",
                    "Its router forwards UDP \(VBANControl.controlPort) to that computer, and **Findable by Grabbers** is on there. Type the address of its "
                    + "network as the internet sees it.", field: true)
            let here = grabber.vbanAddresses.first?.address
            section("Voicemeeter or any other VBAN sender somewhere else",
                    "It sends to this network's outside address, port \(VBAN.port), and this network's router forwards UDP \(VBAN.port) to this PC"
                    + (here.map { " (\($0) here)" } ?? "") + ".", field: false)
        }
        let title = cw.looking ? "Finding…" : "Find this network's outside address"
        let w = c.buttonWidth(title)
        let b = RECT(x: r.left, y: y, width: w, height: c.s(20))
        c.button(title, b, hover: isHover("outside"), enabled: !cw.looking)
        hit(b, "outside") { [unowned self] _ in
            guard !cw.looking else { return }
            cw.looking = true
            cw.lookupError = nil
            OutsideAddress.lookup { result in
                cw.looking = false
                switch result {
                case .success(let ip): cw.outside = ip
                case .failure(let f): cw.lookupError = f.description
                }
                self.invalidateAll()
            }
        }
        if let outside = cw.outside {
            c.text(outside, RECT(left: b.right + c.s(10), top: b.top, right: r.right, bottom: b.bottom), c.font(12), c.p.text)
        }
        y = b.bottom + c.s(5)
        if let e = cw.lookupError { y += c.wrapped(e, RECT(left: r.left, top: y, right: r.right, bottom: y + c.s(30)), c.font(10), c.p.warning) + c.s(3) }
        y += c.wrapped("For the other end to type in. " + OutsideAddress.note, RECT(left: r.left, top: y, right: r.right, bottom: y + c.s(40)), c.font(9), c.p.muted)
        return y
    }
}

/// "SDP Address…": paste a session description for a sender that announces nothing (the Mac's
/// `ManualSDPSheet`). Its own small window, with Windows' own multi-line edit control to paste into.
final class AddStreamDialog {
    unowned let owner: GrabberWindow
    private(set) var surface: Surface!
    private var edit: HWND?
    var message: String?

    init(owner: GrabberWindow) {
        self.owner = owner
        surface = Surface(paint: { [unowned self] c, r in self.draw(c, r) }, minimum: { (420, 360) })
    }

    func show() {
        if surface.hwnd == nil {
            guard owner.makeWindow(surface, title: "Paste SDP — Network Audio Grabber", width: 500, height: 420, owner: owner.hwnd) else { return }
            makeEdit()
        }
        message = nil
        if let edit { SetWindowTextW(edit, nil) }
        ShowWindow(surface.hwnd, SW_SHOW)
        SetForegroundWindow(surface.hwnd)
        if let edit { SetFocus(edit) }
    }

    private func makeEdit() {
        guard let parent = surface.hwnd else { return }
        let style = DWORD(WS_CHILD | WS_VISIBLE | WS_VSCROLL | ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN)
        edit = "EDIT".withCString(encodedAs: UTF16.self) { cls in
            CreateWindowExW(DWORD(WS_EX_CLIENTEDGE), cls, nil, style, 0, 0, 100, 100, parent, nil, GetModuleHandleW(nil), nil)
        }
        if let edit, let font = Canvas.monoFont(dpi: owner.dpi) {
            SendMessageW(edit, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: Int(bitPattern: font))), 1)
        }
    }

    /// Escape closes; everything else goes to the edit control as typed.
    func preTranslate(_ message: inout MSG) -> Bool {
        guard let hwnd = surface.hwnd, message.message == UINT(WM_KEYDOWN), Int32(message.wParam) == VK_ESCAPE,
              message.hwnd == hwnd || message.hwnd == edit else { return false }
        ShowWindow(hwnd, SW_HIDE)
        return true
    }

    private var text: String {
        guard let edit else { return "" }
        let length = Int(GetWindowTextLengthW(edit))
        var buffer = [WCHAR](repeating: 0, count: length + 1)
        GetWindowTextW(edit, &buffer, Int32(length + 1))
        return String(decodingCString: buffer, as: UTF16.self)
    }

    private func draw(_ c: Canvas, _ r: RECT) {
        let pad = c.s(16)
        let left = r.left + pad, right = r.right - pad
        var y = r.top + pad
        c.text("Paste SDP", RECT(left: left, top: y, right: right, bottom: y + c.s(20)), c.font(14, .semibold), c.p.text)
        y += c.s(24)
        y += c.wrapped("For a sender that announces nothing — copy the session's SDP out of ANEMAN, Dante Controller's AES67 page, or the device's web UI.",
                       RECT(left: left, top: y, right: right, bottom: y + c.s(40)), c.font(11), c.p.muted) + c.s(10)
        let bottomRow = r.bottom - pad - c.s(22)
        var editBottom = bottomRow - c.s(10)
        if let message {
            editBottom -= c.s(20)
            c.text(message, RECT(left: left, top: editBottom + c.s(4), right: right, bottom: editBottom + c.s(20)), c.font(11), c.p.warning)
        }
        if let edit {
            SetWindowPos(edit, nil, left, y, right - left, max(c.s(40), editBottom - y), UINT(SWP_NOZORDER))
        }
        let aw = c.buttonWidth("Add"), cw = c.buttonWidth("Cancel")
        let add = RECT(x: right - aw, y: bottomRow, width: aw, height: c.s(22))
        let cancel = RECT(x: add.left - c.s(8) - cw, y: bottomRow, width: cw, height: c.s(22))
        c.button("Add", add, hover: owner.isHover("sdpadd"), prominent: true)
        c.button("Cancel", cancel, hover: owner.isHover("sdpcancel"))
        owner.hit(add, "sdpadd") { [unowned self] _ in
            let t = self.text
            guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if let error = self.owner.grabber.addManualSDP(t) { self.message = error } else { ShowWindow(self.surface.hwnd, SW_HIDE) }
        }
        owner.hit(cancel, "sdpcancel") { [unowned self] _ in ShowWindow(self.surface.hwnd, SW_HIDE) }
    }
}

extension Canvas {
    private static var monoFonts: [Int: HFONT] = [:]
    static func monoFont(dpi: Int) -> HFONT? {
        if let f = monoFonts[dpi] { return f }
        let height = -Int32(MulDiv(12, Int32(dpi), 96))
        let f = "Cascadia Mono".withCString(encodedAs: UTF16.self) { name in
            CreateFontW(height, 0, 0, 0, 400, 0, 0, 0, DWORD(DEFAULT_CHARSET), DWORD(OUT_TT_PRECIS), DWORD(CLIP_DEFAULT_PRECIS),
                        DWORD(CLEARTYPE_QUALITY), DWORD(FIXED_PITCH) | DWORD(FF_MODERN), name)
        }
        monoFonts[dpi] = f
        return f
    }
}
