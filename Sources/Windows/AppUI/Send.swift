import Foundation
import WinSDK
import NetworkAudioEngine
import GrabberCore
import SenderCore

/// The Sender inside the Grabber (the Mac's `GrabberSend`, on Windows): the Windows
/// Sender's own engine, made on demand — no capture, no offer and no tick until something is sent
/// or offered — with settings of its own and its log lines in the Grabber's log.
final class SendState {
    let sender: WindowsSender

    init(grabber: WindowsGrabber, testing: Bool) {
        let suite = testing ? "app.networkaudiograbber.windows.send.test" : "app.networkaudiograbber.windows.send"
        if testing { UserDefaults.standard.removePersistentDomain(forName: suite) }
        sender = WindowsSender(defaults: UserDefaults(suiteName: suite) ?? .standard,
                               name: GrabberEngine.receiverName(grabber.vbanReceiverName), onDemand: true)
        sender.settingsPath = "Settings → Send → Auto-stop"
        configureSenderCapture(sender, forSenderApp: false)
        sender.logSink = { [weak grabber] kind, text in grabber?.append(log: text, kind) }
        // Without this the on-demand engine never wakes: Findable said "Offering" but no beacon
        // left and no request was heard. Nothing runs until something is sent
        // or offered, as before.
        sender.start()
    }

    var isSending: Bool { sender.isActive }

    private var addressesAt = Date.distantPast
    private var addresses: [String] = []

    /// Keeps this Send's own broadcast out of the Grabber's list: its audio comes
    /// back from this PC's address on that network and the Send's port — kept whenever the Send's
    /// socket is open, so the first packet is caught too. Called every frame;
    /// the adapters are looked at every few seconds.
    func leaveOwnSendOut(of grabber: WindowsGrabber) {
        let port = sender.offerPort
        guard port > 0 else {
            if !grabber.vbanIgnoredSources.isEmpty { grabber.vbanIgnoredSources = [] }
            return
        }
        if Date().timeIntervalSince(addressesAt) > 3 {
            addressesAt = Date()
            addresses = Interfaces.receiveAddresses().map(\.address) + ["127.0.0.1"]
        }
        grabber.vbanIgnoredSources = Set(addresses.map { "\($0):\(port)" })
    }
}

/// The Sender's controls (the Mac's `SendControls`, `GrabberSendHeader` and `SendSettingsSections`):
/// what is being sent, who is asking, everyone receiving, and the settings every Send has. Drawn
/// into whichever window holds it — the Grabber's Send section, its Send tabs, and the Sender
/// app's own window — so the two apps' Send is one set of controls, as on the Mac.
final class SendUI {
    let sender: WindowsSender
    unowned let window: DrawnWindow
    /// "Grabber" or "Sender", where the words differ.
    let appName: String
    /// Whether "System audio" leaves this app's own playback out (the Grabber's does).
    let excludesOwnPlayback: Bool
    /// Whether the window's toolbar shows the source, so the stream block need not (the Sender's).
    var sourceInToolbar = false

    var addingReceiver = false
    var addError: String?
    var draft = ""

    init(sender: WindowsSender, window: DrawnWindow, appName: String, excludesOwnPlayback: Bool) {
        self.sender = sender
        self.window = window
        self.appName = appName
        self.excludesOwnPlayback = excludesOwnPlayback
    }

    private var w: DrawnWindow { window }
    var receiverCount: Int { sender.sending.count + sender.listeners.count }
    var healthy: Bool { !sender.captureBlocked && !sender.quietForAWhile }

    /// "● Sending · 2": only while sending; amber while sending silence.
    func drawSendingPill(_ c: Canvas, right: Int32, centreY: Int32, action: @escaping () -> Void) {
        guard sender.isActive else { return }
        let ok = healthy
        let text = "Sending · \(receiverCount)"
        let f = c.font(11)
        let width = c.width(text, f) + c.s(22)
        let pill = RECT(x: right - width, y: centreY - c.s(9), width: width, height: c.s(18))
        c.round(pill, 9, c.p.label, alpha: 0.06)
        c.ellipse(RECT(x: pill.left + c.s(7), y: centreY - c.s(3.5), width: c.s(7), height: c.s(7)), ok ? c.p.green : c.p.warning)
        c.text(text, RECT(left: pill.left + c.s(18), top: pill.top, right: pill.right, bottom: pill.bottom), f, ok ? c.p.text : c.p.warning)
        w.hit(pill, "sendingpill", tip: ok ? "Sending this PC's audio. Send has the controls."
                                          : "Sending, but nothing is arriving from this PC's audio. Send says why.") { _ in action() }
    }

    // MARK: - The header (the Mac's `GrabberSendHeader`)

    /// Fold (where foldable), what is sending, Findable, MUTE ALL, Stop.
    func drawHeader(_ c: Canvas, _ r: RECT, foldable: Bool, open: Bool = true, toggle: @escaping () -> Void = {}) {
        let s = sender
        var x = r.left
        if foldable {
            w.drawFoldHeading(c, r, "Send", open: open, key: "fold-send", toggle: toggle)
            x += c.s(14) + c.width("Send", c.font(12, .semibold)) + c.s(10)
        }
        var right = r.right
        let cy = (r.top + r.bottom) / 2
        let stopTitle = r.width < c.s(420) ? "Stop" : "Stop sending"
        let sw = c.buttonWidth(stopTitle)
        let stop = RECT(x: right - sw, y: cy - c.s(10), width: sw, height: c.s(20))
        let canStop = s.isActive || s.offering
        c.button(stopTitle, stop, hover: w.isHover("sendstop"), enabled: canStop)
        w.hit(stop, "sendstop", tip: "Stop sending, and stop being findable: nothing leaves this PC.") { _ in if canStop { s.stopAll() } }
        right = stop.left - c.s(8)
        let mw = c.pillWidth("MUTE ALL")
        let mute = RECT(x: right - mw, y: cy - c.s(9), width: mw, height: c.s(18))
        c.pill("MUTE ALL", mute, on: s.allMuted, tint: c.p.red, hover: w.isHover("sendmuteall"), enabled: s.isActive)
        w.hit(mute, "sendmuteall", tip: "Every receiver hears silence and stays connected. Each target's own mute is kept.") { _ in
            if s.isActive { s.allMuted.toggle() }
        }
        right = mute.left - c.s(10)
        if foldable && !open {
            right = drawFindable(c, right: right, centreY: cy)
            let summary: String
            if !s.isActive { summary = s.offering ? "Findable, nobody listening" : "Not sending" }
            else {
                let names = s.targets.filter { s.sending.contains($0.id) }.map(\.label) + s.listeners.map { $0.name ?? $0.ip }
                summary = "\(VBAN.wireName(s.streamName)) → " + names.joined(separator: ", ")
            }
            c.text(summary, RECT(left: x, top: r.top, right: right - c.s(8), bottom: r.bottom), c.font(11), c.p.muted)
        }
    }

    /// The Findable switch and its label; returns the left edge it used.
    @discardableResult
    func drawFindable(_ c: Canvas, right: Int32, centreY: Int32) -> Int32 {
        let s = sender
        let sw = RECT(x: right - c.s(26), y: centreY - c.s(7.5), width: c.s(26), height: c.s(15))
        c.toggleSwitch(sw, on: s.offering)
        let label = "Findable by Grabbers"
        let f = c.font(11)
        let lw = c.width(label, f)
        let lr = RECT(left: sw.left - c.s(6) - lw, top: centreY - c.s(9), right: sw.left - c.s(6), bottom: centreY + c.s(9))
        c.text(label, lr, f, c.p.muted)
        w.hit(RECT(left: lr.left, top: lr.top, right: sw.right, bottom: lr.bottom), "findable",
              tip: tooltip("Grabbers on this network list the stream, and it goes to each one that listens, and to nobody else. Anyone on "
                           + "the network can ask for it, so every listener is shown here.", now: s.offering ? "findable" : "off")) { _ in
            s.offering.toggle()
        }
        return lr.left - c.s(10)
    }

    // MARK: - Layouts

    /// The Grabber's Send section along the bottom: header, then this PC beside its receivers.
    func drawSection(_ c: Canvas, _ r: RECT, open: Bool, toggle: @escaping () -> Void) {
        let head = RECT(left: r.left + c.s(12), top: r.top, right: r.right - c.s(12), bottom: r.top + c.s(36))
        drawHeader(c, head, foldable: true, open: open, toggle: toggle)
        guard open else { return }
        c.hline(head.bottom, r.left, r.right, c.p.hairline)
        let body = RECT(left: r.left, top: head.bottom + 1, right: r.right, bottom: r.bottom)
        let split = min(body.left + c.s(320), body.right - c.s(240))
        drawSource(c, RECT(left: body.left, top: body.top, right: split, bottom: body.bottom))
        c.vline(split, body.top, body.bottom, c.p.hairline)
        let right = RECT(left: split + 1, top: body.top, right: body.right, bottom: body.bottom)
        let offset = w.beginScroll("sendreceivers", right, c)
        var y = right.top - offset
        y = drawRequests(c, RECT(left: right.left, top: y + c.s(8), right: right.right, bottom: y))
        y = drawReceivers(c, RECT(left: right.left, top: y, right: right.right, bottom: y))
        w.endScroll("sendreceivers", content: y - (right.top - offset), c)
    }

    /// One column, scrolling: the compact window's and the Connect window's Send tabs, and the
    /// body of the Sender app's window (which has its own header, so passes `header: false`).
    func drawColumn(_ c: Canvas, _ r: RECT, key: String, header: Bool = true, extra: ((Canvas, RECT) -> Int32)? = nil) {
        var top = r.top
        if header {
            let head = RECT(left: r.left + c.s(12), top: r.top, right: r.right - c.s(12), bottom: r.top + c.s(34))
            drawHeader(c, head, foldable: false)
            c.hline(head.bottom, r.left, r.right, c.p.hairline)
            top = head.bottom + 1
        }
        let body = RECT(left: r.left, top: top, right: r.right, bottom: r.bottom)
        let offset = w.beginScroll(key, body, c)
        var y = body.top - offset
        y = drawSource(c, RECT(left: body.left, top: y, right: body.right, bottom: y))
        y = drawRequests(c, RECT(left: body.left, top: y, right: body.right, bottom: y))
        c.hline(y, body.left, body.right, c.p.divider)
        y = drawReceivers(c, RECT(left: body.left, top: y + 1, right: body.right, bottom: y))
        if let extra {
            c.hline(y, body.left, body.right, c.p.divider)
            y = extra(c, RECT(left: body.left, top: y + 1, right: body.right, bottom: y))
        }
        w.endScroll(key, content: y - (body.top - offset), c)
    }

    // MARK: - What is sent

    /// The stream's name, its format, its source, where this PC is, and the level going out.
    @discardableResult
    func drawSource(_ c: Canvas, _ r: RECT) -> Int32 {
        let s = sender
        let pad = c.s(12)
        let left = r.left + pad, right = r.right - pad
        var y = r.top + pad
        // The name, with its pencil.
        let name = VBAN.wireName(s.streamName).isEmpty ? "PC Audio" : s.streamName
        let nf = c.font(20, .medium)
        let detail = formatDetail
        let df = c.font(10)
        let dw = c.width(detail, df)
        c.text(detail, RECT(left: right - dw, top: y + c.s(6), right: right, bottom: y + c.s(26)), df, c.p.muted, align: .right)
        let nameBox = RECT(left: left, top: y, right: right - dw - c.s(10), bottom: y + c.s(28))
        w.fieldFrames["streamname"] = nameBox
        if w.fieldKey != "streamname" {
            let nw = min(c.width(name, nf), nameBox.width - c.s(20))
            c.text(name, RECT(left: nameBox.left, top: nameBox.top, right: nameBox.left + nw + 1, bottom: nameBox.bottom), nf, c.p.text, middle: true)
            let pencil = RECT(x: nameBox.left + nw + c.s(6), y: nameBox.top + c.s(8), width: c.s(14), height: c.s(14))
            c.icon("\u{E70F}", pencil, size: 11, w.isHover("rename") ? c.p.text : c.p.muted)
            w.hit(RECT(left: nameBox.left, top: nameBox.top, right: pencil.right, bottom: nameBox.bottom), "rename",
                  tip: tooltip("What receivers list this stream as — up to 16 plain characters. Click to rename; it takes effect on Enter.",
                               now: VBAN.wireName(s.streamName))) { [unowned self] _ in
                self.w.beginField("streamname", frame: nameBox, text: s.streamName) { text in
                    let t = text.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { s.streamName = t }
                }
            }
        }
        y = nameBox.bottom + c.s(8)
        // The source, as a menu (the Mac's `SourceMenu`) — not in the Sender app, whose toolbar
        // already shows it, as the Mac Sender's does.
        if !sourceInToolbar {
            let sourceRow = RECT(left: left, top: y, right: right, bottom: y + c.s(18))
            drawSourceMenu(c, sourceRow)
            y = sourceRow.bottom + c.s(4)
        }
        let addresses = s.localAddresses
        if !addresses.isEmpty {
            c.text("This PC: " + addresses.joined(separator: ", "), RECT(left: left, top: y, right: right, bottom: y + c.s(16)), c.font(11), c.p.muted)
            w.hit(RECT(left: left, top: y, right: right, bottom: y + c.s(16)), "thispc",
                  tip: "This PC's address on each network it is on. A Grabber adds it by hand under Settings → Discovery (port "
                    + "\(VBANControl.controlPort)); Connect… has the steps.")
            y += c.s(20)
        }
        // One bar per channel captured, dotted while nothing is.
        // Each labelled with its channel, as the Mac's: SMPTE names where the
        // count has a layout, numbers where it doesn't.
        let channels = max(1, s.captureChannels)
        let names = SMPTELayout.forChannelCount(channels)?.channelNames ?? (1...channels).map { "\($0)" }
        let slot = channels <= 2 ? 11.0 : max(7, 56 / Double(channels))
        let labelW = channels <= 2 ? c.s(13) : c.s(22)
        let barsLeft = left + labelW + c.s(6)
        for ch in 0..<channels {
            let rowTop = y + c.s(slot * Double(ch))
            c.text(ch < names.count ? names[ch] : "\(ch + 1)", RECT(left: left, top: rowTop, right: left + labelW, bottom: rowTop + c.s(slot)),
                   c.font(channels <= 2 ? 8 : 7, .semibold), c.p.muted, align: channels <= 2 ? .centre : .left)
            let thick = max(2, slot - 4)
            let bar = RECT(left: barsLeft, top: rowTop + (c.s(slot) - c.s(thick)) / 2, right: right,
                           bottom: rowTop + (c.s(slot) - c.s(thick)) / 2 + c.s(thick))
            c.bar(bar, level: s.level(ch), vertical: false)
        }
        w.hit(RECT(left: left, top: y, right: right, bottom: y + c.s(slot * Double(channels))), "sendmeters",
              tip: tooltip("What is being sent, as captured. Green to −18 dBFS, amber to −6, red above.",
                           now: s.isActive ? "capturing" : "not capturing"))
        y += c.s(slot * Double(channels)) + c.s(9)
        // What is wrong, if anything.
        if case .failed(let message) = s.captureStatus {
            y += c.wrapped(message, RECT(left: left, top: y, right: right, bottom: y + c.s(60)), c.font(11), c.p.warning) + c.s(6)
        } else if let rate = s.unsupportedRate {
            y += c.wrapped("This PC is running at \(rate) Hz, which VBAN cannot carry. Set the playback device to 44.1 or 48 kHz in "
                           + "Windows' Sound settings.", RECT(left: left, top: y, right: right, bottom: y + c.s(60)), c.font(11), c.p.warning) + c.s(6)
        } else if s.quietForAWhile && s.isActive {
            y += c.wrapped("Nothing is playing, so receivers hear silence. They stay connected.",
                           RECT(left: left, top: y, right: right, bottom: y + c.s(60)), c.font(11), c.p.muted) + c.s(6)
        }
        return y + c.s(4)
    }

    var formatDetail: String {
        let bits = sender.dataType == .int24 ? "24-bit" : "16-bit"
        if case .running(let rate, let channels) = sender.captureStatus {
            return "\(bits) · \(String(format: "%.4g kHz", Double(rate) / 1000)) · \(channels == 2 ? "stereo" : "\(channels) ch")"
        }
        return bits
    }

    /// Grabbers asking to listen, with Allow and Deny.
    func drawRequests(_ c: Canvas, _ r: RECT) -> Int32 {
        let s = sender
        var y = r.top
        for request in s.requests.prefix(4) {
            let card = RECT(left: r.left + c.s(12), top: y, right: r.right - c.s(12), bottom: y + c.s(46))
            c.round(card, 6, c.p.active, alpha: 0.10, border: c.p.active, borderAlpha: 0.4)
            let aw = c.buttonWidth("Allow"), dw = c.buttonWidth("Deny")
            let allow = RECT(x: card.right - c.s(8) - aw, y: card.top + c.s(13), width: aw, height: c.s(20))
            let deny = RECT(x: allow.left - c.s(6) - dw, y: allow.top, width: dw, height: c.s(20))
            c.button("Allow", allow, hover: w.isHover("allow-\(request.id)"), prominent: true)
            c.button("Deny", deny, hover: w.isHover("deny-\(request.id)"))
            w.hit(allow, "allow-\(request.id)") { _ in s.allow(request) }
            w.hit(deny, "deny-\(request.id)") { _ in s.decline(request) }
            c.text("\(request.name ?? "A Grabber") wants to listen", RECT(left: card.left + c.s(10), top: card.top + c.s(6),
                                                                         right: deny.left - c.s(8), bottom: card.top + c.s(24)),
                   c.font(12, .medium), c.p.text)
            c.text(request.ip, RECT(left: card.left + c.s(10), top: card.top + c.s(24), right: deny.left - c.s(8), bottom: card.bottom - c.s(4)),
                   c.font(11), c.p.muted)
            y = card.bottom + c.s(6)
        }
        return y + (s.requests.isEmpty ? 0 : c.s(4))
    }

    /// Everyone the audio reaches: listeners, then targets, favourites first.
    func drawReceivers(_ c: Canvas, _ r: RECT) -> Int32 {
        let s = sender
        let pad = c.s(12)
        let head = RECT(left: r.left + pad, top: r.top, right: r.right - pad, bottom: r.top + c.s(36))
        let hf = c.font(12, .semibold)
        c.text("Receivers", RECT(left: head.left, top: head.top, right: head.left + c.width("Receivers", hf) + 2, bottom: head.bottom), hf, c.p.muted)
        let cy = (head.top + head.bottom) / 2
        var right = head.right
        let plus = RECT(x: right - c.s(22), y: cy - c.s(10), width: c.s(22), height: c.s(20))
        c.round(plus, 5, c.p.label, alpha: w.isHover("sendadd") ? 0.14 : 0.08)
        c.icon("\u{E710}", plus, size: 10, c.p.muted)
        w.hit(plus, "sendadd", tip: "Add a receiver by address — another VBAN receiver such as Voicemeeter, or a Grabber this PC cannot find on its own.") {
            [unowned self] _ in self.addingReceiver.toggle(); self.addError = nil
        }
        right = plus.left - c.s(6)
        let bw = c.buttonWidth("Broadcast…")
        let broadcast = RECT(x: right - bw, y: cy - c.s(10), width: bw, height: c.s(20))
        let canBroadcast = !s.broadcastNetworks.isEmpty
        c.button("Broadcast…", broadcast, hover: w.isHover("sendbroadcast"), enabled: canBroadcast)
        w.hit(broadcast, "sendbroadcast", tip: "Send to every VBAN receiver on a network at once — several Grabbers, Voicemeeter.") { [unowned self] _ in
            if canBroadcast { self.broadcastMenu(at: POINT(x: broadcast.left, y: broadcast.bottom)) }
        }
        right = broadcast.left - c.s(10)
        drawFindable(c, right: right, centreY: cy)
        var y = head.bottom
        if addingReceiver {
            let box = RECT(left: r.left + pad, top: y, right: r.right - pad, bottom: y + c.s(addError == nil ? 58 : 76))
            c.round(box, 6, c.p.label, alpha: 0.05)
            let remote = RemoteAddresses.isRemote(RemoteAddresses.host(draft))
            let addTitle = remote ? "Add anyway" : "Add"
            let aw = c.buttonWidth(addTitle), cw = c.buttonWidth("Cancel")
            let add = RECT(x: box.right - c.s(8) - aw, y: box.top + c.s(8), width: aw, height: c.s(22))
            let cancel = RECT(x: add.left - c.s(6) - cw, y: add.top, width: cw, height: c.s(22))
            let fieldRect = RECT(left: box.left + c.s(8), top: add.top, right: cancel.left - c.s(8), bottom: add.bottom)
            w.fieldFrames["sendtarget"] = fieldRect
            c.field(w.fieldKey == "sendtarget" ? "" : draft, fieldRect, placeholder: "Receiver IP address, or address:port",
                    hover: w.isHover("sendtargetfield"))
            let commit: (String) -> Void = { [unowned self] text in
                self.draft = text
                let typed = text.trimmingCharacters(in: .whitespaces)
                guard !typed.isEmpty else { return }
                let parts = typed.split(separator: ":", maxSplits: 1)
                s.draftHost = String(parts[0])
                s.draftPort = parts.count > 1 ? String(parts[1]) : String(VBAN.port)
                s.draftError = nil
                if s.addDraft() { self.addError = nil; self.addingReceiver = false; self.draft = "" }
                else { self.addError = s.draftError }
            }
            w.hit(fieldRect, "sendtargetfield") { [unowned self] _ in
                self.w.beginField("sendtarget", frame: fieldRect, text: self.draft, commit: commit)
            }
            c.button(addTitle, add, hover: w.isHover("sendaddgo"), prominent: true)
            w.hit(add, "sendaddgo") { [unowned self] _ in
                if self.w.fieldKey == "sendtarget" { self.w.commitField() } else { commit(self.draft) }
            }
            c.button("Cancel", cancel, hover: w.isHover("sendaddcancel"))
            w.hit(cancel, "sendaddcancel") { [unowned self] _ in self.w.cancelField(); self.addingReceiver = false; self.addError = nil }
            var ty = add.bottom + c.s(4)
            if let error = addError {
                c.text(error, RECT(left: box.left + c.s(8), top: ty, right: box.right - c.s(8), bottom: ty + c.s(16)), c.font(11), c.p.warning)
                ty += c.s(18)
            }
            c.text("For another VBAN receiver, such as Voicemeeter. A Grabber on this network needs nothing typed: turn on Findable instead.",
                   RECT(left: box.left + c.s(8), top: ty, right: box.right - c.s(8), bottom: ty + c.s(16)), c.font(10), c.p.muted)
            y = box.bottom + c.s(6)
        }
        let listeners = s.offering ? s.listeners : []
        let targets = s.targets.sorted { $0.favourite && !$1.favourite }
        if listeners.isEmpty && targets.isEmpty {
            let text = s.offering
                ? "Nobody is listening yet. Grabbers on this network now list “\(VBAN.wireName(s.streamName))”."
                : "Nobody is receiving. Turn on Findable so Grabbers on this network can list this PC, or add a receiver by address with +."
            y += c.wrapped(text, RECT(left: r.left + pad, top: y, right: r.right - pad, bottom: y + c.s(60)), c.font(11), c.p.muted) + c.s(12)
            return y
        }
        for listener in listeners {
            let row = RECT(left: r.left + pad, top: y, right: r.right - pad, bottom: y + c.s(40))
            c.icon("\u{E7F6}", RECT(x: row.left, y: row.top, width: c.s(20), height: row.height), size: 12, c.p.green)
            c.text(listener.name ?? "A Grabber", RECT(left: row.left + c.s(28), top: row.top + c.s(4), right: row.right - c.s(80), bottom: row.top + c.s(21)),
                   c.font(12, .medium), c.p.text)
            c.text(listener.ip, RECT(left: row.left + c.s(28), top: row.top + c.s(21), right: row.right - c.s(80), bottom: row.bottom - c.s(3)),
                   c.font(10), c.p.muted)
            c.text("Listening", RECT(left: row.right - c.s(80), top: row.top, right: row.right, bottom: row.bottom), c.font(11), c.p.green, align: .right)
            y = row.bottom
            c.hline(y, row.left + c.s(28), row.right, c.p.hairline)
            y += 1
        }
        for target in targets {
            let row = RECT(left: r.left + pad, top: y, right: r.right - pad, bottom: y + c.s(40))
            let sending = s.isSending(target.id)
            let play = RECT(x: row.left + c.s(1), y: (row.top + row.bottom) / 2 - c.s(9), width: c.s(18), height: c.s(18))
            c.playStop(play, active: sending, hover: w.isHover("tplay-\(target.id)"))
            w.hit(play.inset(by: -c.s(3)), "tplay-\(target.id)", tip: sending ? "Stop sending to \(target.label)" : "Send to \(target.label)") { _ in
                s.toggleSending(target.id)
            }
            var rr = row.right
            let more = RECT(x: rr - c.s(20), y: row.top, width: c.s(20), height: row.height)
            c.icon("\u{E712}", more, size: 11, w.isHover("tmore-\(target.id)") ? c.p.text : c.p.muted)
            w.hit(more, "tmore-\(target.id)", tip: "Rename, favourite, remove") { [unowned self] _ in
                self.targetMenu(target, at: POINT(x: more.left, y: more.bottom))
            }
            rr = more.left - c.s(4)
            let m = RECT(x: rr - c.s(24), y: (row.top + row.bottom) / 2 - c.s(9), width: c.s(24), height: c.s(18))
            c.pill("M", m, on: target.muted, tint: c.p.mute, hover: w.isHover("tm-\(target.id)"))
            w.hit(m, "tm-\(target.id)", tip: tooltip("Mute: send silence, so the receiver keeps the stream listed.",
                                                      now: target.muted ? "muted" : "sending audio")) { _ in s.toggleMuted(target.id) }
            rr = m.left - c.s(8)
            let unreachable = sending && s.unreachableTargets.contains(target.id)
            let note = s.autoStopNote(target.id)
            let status = unreachable ? "Unreachable" : (sending ? "Sending" : (note != nil ? "Timed out" : "Stopped"))
            let statusColour = unreachable ? c.p.warning : (sending ? c.p.secondary : (note != nil ? c.p.warning : c.p.muted))
            let sf = c.font(11)
            let swid = c.width(status, sf)
            c.text(status, RECT(left: rr - swid, top: row.top, right: rr, bottom: row.bottom), sf, statusColour, align: .right)
            if let note { w.hit(RECT(left: rr - swid, top: row.top, right: rr, bottom: row.bottom), "tnote-\(target.id)", tip: note) }
            if unreachable {
                w.hit(RECT(left: rr - swid, top: row.top, right: rr, bottom: row.bottom), "tunreach-\(target.id)",
                      tip: "This PC cannot reach \(target.address): the network says the host is down or has no route. Still sending; it picks up as "
                        + "soon as the host is back.")
            }
            rr -= swid + c.s(8)
            let textLeft = row.left + c.s(28)
            let reported = s.reportedName(for: target.host)
            let shown = target.name ?? reported
            var label = shown ?? target.address
            if target.favourite { label += "  ★" }
            let lf = c.font(12, .medium)
            var badgeX = textLeft + min(c.width(label, lf), rr - textLeft - c.s(60)) + c.s(6)
            if shown != nil || target.broadcast {
                c.text(label, RECT(left: textLeft, top: row.top + c.s(4), right: badgeX, bottom: row.top + c.s(21)), lf, c.p.text)
                let sub = target.broadcast ? (s.destination(of: target).map { "broadcast \($0)" } ?? target.address) : target.address
                c.text(sub, RECT(left: textLeft, top: row.top + c.s(21), right: rr, bottom: row.bottom - c.s(3)), c.font(10), c.p.muted)
            } else {
                c.text(label, RECT(left: textLeft, top: row.top, right: badgeX, bottom: row.bottom), lf, c.p.text)
            }
            // Where it is: another location, a VPN, or this network; and BCAST while broadcasting.
            let by = shown != nil || target.broadcast ? row.top + c.s(12) : (row.top + row.bottom) / 2
            var badges: [(String, Colour)] = []
            if RemoteAddresses.isRemote(target.host) { badges.append(("REMOTE · NOT ENCRYPTED", c.p.warning)) }
            else if RemoteAddresses.isVPN(target.host) { badges.append(("VPN", c.p.secondary)) }
            else { badges.append(("LOCAL", c.p.secondary)) }     // the Mac's `ConnectionBadge`
            if target.broadcast { badges.append(("BCAST", c.p.active)) }
            for (text, tint) in badges where badgeX < rr - c.s(40) {
                let bf = c.font(8, .bold)
                let houseW = text == "LOCAL" ? c.s(11) : 0
                let bw2 = c.width(text, bf) + c.s(10) + houseW
                let b = RECT(x: badgeX, y: by - c.s(7), width: bw2, height: c.s(14))
                c.round(b, 7, c.p.label, alpha: 0.07)
                if houseW > 0 { c.icon("\u{E80F}", RECT(x: b.left + c.s(4), y: b.top, width: houseW, height: b.height), size: 8, tint) }
                c.text(text, RECT(left: b.left + (houseW > 0 ? houseW + c.s(3) : 0), top: b.top, right: b.right, bottom: b.bottom), bf, tint, align: .centre)
                badgeX = b.right + c.s(4)
            }
            w.hit(RECT(left: textLeft, top: row.top, right: rr, bottom: row.bottom), "tname-\(target.id)",
                  tip: target.name != nil ? "\(target.address). Double-click to rename."
                    : reported != nil ? "\(target.address), as the Grabber there names itself. Double-click to give it your own name."
                    : "Double-click to give this a name.",
                  double: { [unowned self] in self.beginNaming(target, row: RECT(left: textLeft, top: row.top + c.s(8), right: rr, bottom: row.bottom - c.s(8))) },
                  right: { [unowned self] pt in self.targetMenu(target, at: pt) })
            y = row.bottom
            c.hline(y, textLeft, row.right, c.p.hairline)
            y += 1
        }
        return y + c.s(8)
    }

    private func beginNaming(_ target: SendTarget, row: RECT) {
        w.fieldFrames["targetname"] = row
        w.beginField("targetname", frame: row, text: target.name ?? "") { [unowned self] text in
            self.sender.rename(target.id, to: text.trimmingCharacters(in: .whitespaces))
        }
    }

    private func targetMenu(_ target: SendTarget, at pt: POINT) {
        let s = sender
        var entries: [DrawnWindow.MenuEntry] = []
        if target.broadcast, target.networkSignature == nil {
            entries.append(.item("Stop broadcasting") { s.toggleBroadcast(target.id) })
            entries.append(.separator)
        }
        entries.append(.item(target.favourite ? "Unpin" : "Pin to the top", checked: target.favourite) { s.toggleFavourite(target.id) })
        entries.append(.item("Send silence (mute)", checked: target.muted) { s.toggleMuted(target.id) })
        entries.append(.separator)
        entries.append(.item("Remove") { s.remove(target.id) })
        w.popup(entries, at: pt)
    }

    private func broadcastMenu(at pt: POINT) {
        let s = sender
        var entries: [DrawnWindow.MenuEntry] = [.heading("Every VBAN receiver on the network hears it. Not encrypted.")]
        for n in s.broadcastNetworks {
            let on = s.isBroadcasting(on: n)
            entries.append(.item("\(n.name) — \(n.address)" + (on ? "  (broadcasting)" : ""), checked: on, enabled: !on) {
                s.startBroadcast(on: n, keepOn: false)
            })
            if !on {
                entries.append(.item("\(n.name) — and keep broadcasting when opened again", enabled: true) {
                    s.startBroadcast(on: n, keepOn: true)
                })
            }
        }
        w.popup(entries, at: pt)
    }

    // MARK: - The source

    /// "Source: System audio ⌄" — what is sent, as a menu.
    func drawSourceMenu(_ c: Canvas, _ r: RECT) {
        let s = sender
        let label = SendSourceText.short(s)
        c.icon(SendSourceText.glyph(s), RECT(x: r.left, y: r.top, width: c.s(14), height: r.height), size: 10, c.p.muted)
        let ml = c.menuLabel("Source: " + label, x: r.left + c.s(18), r, size: 11, colour: w.isHover("sendsource") ? c.p.active : c.p.muted)
        w.hit(RECT(left: r.left, top: r.top, right: ml.right, bottom: r.bottom), "sendsource",
              tip: SendSourceText.tooltip(s, excludesOwnPlayback: excludesOwnPlayback, app: appName)) { [unowned self] _ in
            self.sourceMenu(at: POINT(x: r.left, y: r.bottom))
        }
    }

    func sourceMenu(at pt: POINT) {
        w.popup(SendSourceText.menu(sender), at: pt)
    }

    // MARK: - Settings (the Mac's `SendSettingsSections`)

    func settings(_ f: Form) {
        let s = sender
        let c = f.c
        // Stream.
        f.labeled("Name") { [unowned self] r in
            let width = min(c.s(220), r.width)
            let box = RECT(x: r.right - width, y: r.top + c.s(5), width: width, height: r.height - c.s(10))
            self.w.fieldFrames["setname"] = box
            c.field(self.w.fieldKey == "setname" ? "" : s.streamName, box, hover: self.w.isHover("field-setname"))
            self.w.hit(box, "field-setname", tip: "What receivers list this stream as — up to 16 plain characters.") { [unowned self] _ in
                self.w.beginField("setname", frame: box, text: s.streamName) { text in
                    let t = text.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { s.streamName = t }
                }
            }
        }
        f.segmented("Quality", options: ["16-bit", "24-bit"], selected: s.dataType == .int24 ? 1 : 0,
                    tip: "24-bit is what most receivers expect for monitoring; 16-bit is two-thirds the traffic.") { i in
            s.dataType = i == 1 ? .int24 : .int16
        }
        f.popupRow("Source", value: SendSourceText.short(s), width: 260,
                   tip: SendSourceText.tooltip(s, excludesOwnPlayback: excludesOwnPlayback, app: appName)) { SendSourceText.menu(s) }
        if SendSourceText.isInput(s) {
            f.labeled("Channels") { r in
                c.text("The device's own: \(s.captureChannels) ch", r, c.font(11), c.p.muted, align: .right)
            }
        } else {
            f.segmented("Channels", options: ["Match output", "Stereo"], selected: s.stereoOnly ? 1 : 0,
                        tip: tooltip("Match output sends as many channels as the output device has — six on a 5.1 device, eight on a 7.1. "
                                     + "Stereo mixes everything down to two.", now: s.stereoOnly ? "stereo" : "matching the output device")) { i in
                s.stereoOnly = i == 1
            }
        }
        f.section("Stream")

        f.toggle("Resume sending when opened", on: s.resumeSending) { s.resumeSending.toggle() }
        f.section("Targets", footer: "Every target is remembered; ★ pins it to the top. With this on, sending picks up with whatever it was "
                  + "sending to when it was last quit.")

        f.toggle("Ask before a new Grabber listens", on: s.askFirst,
                 tip: tooltip("With the offer on, a Grabber you have not allowed before has to wait for you to press Allow. Off, any Grabber on "
                              + "the network can listen as soon as it presses play.", now: s.askFirst ? "asks first" : "anyone may listen")) {
            s.askFirst.toggle()
        }
        for ip in s.allowedGrabbers.keys.sorted() {
            let name = s.allowedGrabbers[ip].flatMap { $0.isEmpty ? nil : $0 } ?? "Grabber"
            f.custom(c.s(30)) { [unowned self] r in
                c.icon("\u{EA18}", RECT(x: r.left, y: r.top, width: c.s(14), height: r.height), size: 10, c.p.muted)
                c.text(name, RECT(left: r.left + c.s(20), top: r.top, right: r.left + c.s(20) + c.width(name, c.font(12)) + 2, bottom: r.bottom), c.font(12), c.p.text)
                c.text(ip, RECT(left: r.left + c.s(28) + c.width(name, c.font(12)), top: r.top, right: r.right - c.s(80), bottom: r.bottom), c.font(10), c.p.muted)
                let bw = c.buttonWidth("Remove")
                let b = RECT(x: r.right - bw, y: r.top + c.s(5), width: bw, height: c.s(20))
                c.button("Remove", b, hover: self.w.isHover("revoke-\(ip)"))
                self.w.hit(b, "revoke-\(ip)", tip: "Stop it listening now; it has to ask again next time.") { _ in s.revoke(ip) }
            }
        }
        for d in s.deniedGrabbers {
            f.custom(c.s(30)) { [unowned self] r in
                c.icon("\u{E7BA}", RECT(x: r.left, y: r.top, width: c.s(14), height: r.height), size: 10, c.p.muted)
                c.text("\(d.name ?? "Grabber")  ·  \(d.ip)  ·  Denied", RECT(left: r.left + c.s(20), top: r.top, right: r.right - c.s(80), bottom: r.bottom),
                       c.font(12), c.p.secondary)
                let bw = c.buttonWidth("Allow")
                let b = RECT(x: r.right - bw, y: r.top + c.s(5), width: bw, height: c.s(20))
                c.button("Allow", b, hover: self.w.isHover("allowdenied-\(d.id)"))
                self.w.hit(b, "allowdenied-\(d.id)", tip: "Let it listen after all — it is let in the next time it asks, within 20 seconds.") { _ in
                    s.allowDenied(d)
                }
            }
        }
        f.popupRow("Findable on", value: s.offerInterfaces.isEmpty ? "All networks" : s.offerInterfaces.sorted().joined(separator: ", "),
                   tip: "Which networks the offer to Grabbers is announced on.") { [unowned self] in self.networkMenuEntries() }
        f.section("Grabbers", footer: s.allowedGrabbers.isEmpty && s.deniedGrabbers.isEmpty
                  ? "Grabbers you allow are listed here. One you deny is refused until you allow it here, or until this is next opened."
                  : "A Grabber allowed on one of its computer's addresses is let in from the others too. The name is what each Grabber calls "
                    + "itself. Denied ones are refused until you allow them here, or until this is next opened.")

        f.toggle("Stop sending to receivers that can't be reached", on: s.autoStopSends) { s.autoStopSends.toggle() }
        f.popupRow("After", value: GrabberEngine.minutesText(s.autoStopSendsMinutes), width: 120, dimmed: !s.autoStopSends) {
            GrabberEngine.autoStopChoices.map { m in .item(GrabberEngine.minutesText(m), checked: m == s.autoStopSendsMinutes) { s.autoStopSendsMinutes = m } }
        }
        f.section("Auto-stop", footer: "Off, a target is sent to until you stop it. On, each target is stopped once this PC has been unable to "
                  + "reach it for the time chosen, and its row says Timed out. A Grabber listening through “Findable by Grabbers” that goes away "
                  + "is let go after 15 seconds either way.")
    }

    /// Which networks the offer is announced on: every one, or any chosen set.
    func networkMenuEntries() -> [DrawnWindow.MenuEntry] {
        let s = sender
        let chosen = s.offerInterfaces
        let up = Set(s.networks.map(\.name))
        var entries: [DrawnWindow.MenuEntry] = [.item("All networks", checked: chosen.isEmpty) { s.offerInterfaces = [] }, .separator]
        for n in s.networks {
            entries.append(.item("\(n.name) — \(n.address)", checked: chosen.contains(n.name)) {
                var next = s.offerInterfaces
                if next.contains(n.name) { next.remove(n.name) } else { next.insert(n.name) }
                s.offerInterfaces = next
            })
        }
        let missing = chosen.subtracting(up).sorted()
        if !missing.isEmpty {
            entries.append(.separator)
            for name in missing {
                entries.append(.item("\(name) — not connected", checked: true) { s.offerInterfaces.remove(name) })
            }
        }
        return entries
    }
}

// MARK: - The Grabber's wrappers

extension GrabberWindow {
    var sendState: SendState? { send }

    func drawSendingPill(_ c: Canvas, right: Int32, centreY: Int32, action: @escaping () -> Void) {
        sendUI?.drawSendingPill(c, right: right, centreY: centreY, action: action)
    }

    func sendSectionHeight(_ c: Canvas) -> Int32 { send == nil ? 0 : (view.sendOpen ? c.s(220) : c.s(36)) }

    func drawSendSection(_ c: Canvas, _ r: RECT) {
        sendUI?.drawSection(c, r, open: view.sendOpen) { [unowned self] in self.view.sendOpen.toggle() }
    }

    func drawSendTab(_ c: Canvas, _ r: RECT, compact: Bool) {
        sendUI?.drawColumn(c, r, key: compact ? "csendtab" : "sendtab")
    }
}
