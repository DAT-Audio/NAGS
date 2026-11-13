import Foundation
import WinSDK
import NetworkAudioEngine
import SenderCore
import WindowsInserts

/// The Sender's inserts: the same VST3 chain as the Grabber's, on what is sent,
/// before the meters and the network, so every receiver hears them. The engine hands interleaved
/// audio on the capture's thread; the chain works on planes, so this goes between.
final class VST3SendProcessor: SendProcessor, @unchecked Sendable {
    let chain = VST3InsertChain()
    private static let maxFrames = 4096, maxChannels = 8
    private let planes = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * maxChannels)
    private let pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: maxChannels)
    private var out = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * maxChannels)
    private var outCapacity = maxFrames * maxChannels
    private(set) var configured: (rate: Int, channels: Int) = (0, 0)

    init() {
        for c in 0..<Self.maxChannels { pointers[c] = planes + c * Self.maxFrames }
    }

    deinit { planes.deallocate(); pointers.deallocate(); out.deallocate() }

    /// The rate and width being sent, on the main thread; the chain takes it from the next block.
    func configure(rate: Int, channels: Int) {
        guard (rate, channels) != configured, rate > 0, channels > 0 else { return }
        configured = (rate, channels)
        chain.configure(sampleRate: Double(rate), channels: min(channels, Self.maxChannels), maxFrames: Self.maxFrames)
    }

    func process(_ samples: UnsafePointer<Float>, frames: Int, channels: Int, sampleRate: Int) -> UnsafePointer<Float> {
        guard channels <= Self.maxChannels, frames > 0, frames * channels <= outCapacity else { return samples }
        var done = 0
        while done < frames {
            let n = min(Self.maxFrames, frames - done)
            let src = samples + done * channels
            for f in 0..<n { for c in 0..<channels { pointers[c][f] = src[f * channels + c] } }
            chain.process(buses: pointers, channels: channels, frames: n)
            let dst = out + done * channels
            for f in 0..<n { for c in 0..<channels { dst[f * channels + c] = pointers[c][f] } }
            done += n
        }
        return UnsafePointer(out)
    }
}

/// What the Sender's window keeps for itself, in the Sender's own settings (the Mac's
/// `SenderState` keys): the look, the folds, Settings or Log.
final class SenderPrefs {
    private let d: UserDefaults
    init(_ defaults: UserDefaults) {
        d = defaults
        appearance = Appearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .dark
        if let enabled = d.object(forKey: "themeEnabled") as? Bool {
            themeEnabled = enabled
            themePrimaryHex = d.string(forKey: "themePrimaryHex") ?? ThemePreset.previousFallback.primary
            themeSecondaryHex = d.string(forKey: "themeSecondaryHex") ?? ThemePreset.previousFallback.secondary
        } else {
            themeEnabled = false
            themePrimaryHex = d.string(forKey: "themePrimaryHex") ?? ThemePreset.standard.primary
            themeSecondaryHex = d.string(forKey: "themeSecondaryHex") ?? ThemePreset.standard.secondary
        }
        showInsertMix = d.object(forKey: "showInsertMix") as? Bool ?? true
        insertsOpen = d.object(forKey: "insertsOpen") as? Bool ?? false
    }
    var appearance: Appearance { didSet { d.set(appearance.rawValue, forKey: "appearance") } }
    var themeEnabled: Bool { didSet { d.set(themeEnabled, forKey: "themeEnabled") } }
    var themePrimaryHex: String { didSet { d.set(themePrimaryHex, forKey: "themePrimaryHex") } }
    var themeSecondaryHex: String { didSet { d.set(themeSecondaryHex, forKey: "themeSecondaryHex") } }
    var showInsertMix: Bool { didSet { d.set(showInsertMix, forKey: "showInsertMix") } }
    var insertsOpen: Bool { didSet { d.set(insertsOpen, forKey: "insertsOpen") } }
    var showSettings = false
    var showsLog = false

    var skin: Skin { Skin.forScheme(enabled: themeEnabled, primary: themePrimaryHex, secondary: themeSecondaryHex) }
    var preset: ThemePreset? {
        (ThemePreset.all + ThemePreset.looks).first {
            $0.primary.caseInsensitiveCompare(themePrimaryHex) == .orderedSame && $0.secondary.caseInsensitiveCompare(themeSecondaryHex) == .orderedSame
        }
    }

    func windowSize() -> (Double, Double) {
        (d.object(forKey: "window.w") as? Double ?? 520, d.object(forKey: "window.h") as? Double ?? 640)
    }
    func rememberWindowSize(_ w: Double, _ h: Double) {
        guard w > 100, h > 100 else { return }
        d.set(w, forKey: "window.w"); d.set(h, forKey: "window.h")
    }
}

/// The Sender's one window (the Mac's `SenderView`): what is being
/// captured, and where it is going. The toolbar — the emblem, the networks the offer goes out on,
/// the source, the gear — then the Send controls the Grabber's Send area shares, the inserts, and
/// a status line with Connect… and Stop all. Everything set once is in Settings.
final class SenderAppWindow: DrawnWindow {
    let sender: WindowsSender
    let prefs: SenderPrefs
    let processor: VST3SendProcessor
    private(set) var sendUI: SendUI!
    private(set) var inserts: InsertsModel!
    var connect: SenderConnectWindow?

    init(sender: WindowsSender, processor: VST3SendProcessor, prefs: SenderPrefs) {
        self.sender = sender
        self.prefs = prefs
        self.processor = processor
        super.init(palette: Self.palette(for: prefs), iconPNG: SenderIcon.png128)
        sendUI = SendUI(sender: sender, window: self, appName: "Sender", excludesOwnPlayback: false)
        sendUI?.sourceInToolbar = true
        inserts = InsertsModel(chain: processor.chain, defaults: sender.defaults, width: { [unowned sender] in sender.captureChannels },
                               widthName: "stream to stereo (Settings → Channels)", showMix: { [unowned prefs] in prefs.showInsertMix }) {
            [unowned sender] text, kind in sender.note(kind, text)
        }
        inserts.rate = { [unowned self] in Double(self.processor.configured.rate == 0 ? 48000 : self.processor.configured.rate) }
    }

    static func palette(for prefs: SenderPrefs) -> Palette {
        Palette.make(appearance: prefs.appearance, themeEnabled: prefs.themeEnabled, primaryHex: prefs.themePrimaryHex,
                     secondaryHex: prefs.themeSecondaryHex, systemDark: SystemLook.prefersDark, systemAccent: SystemLook.accent)
    }

    func restyle() {
        palette = Self.palette(for: prefs)
        applyTitleBars()
        invalidateAll()
    }

    override var extraSurfaces: [Surface] { [connect?.surface].compactMap { $0 } }

    func create() -> Bool {
        let (w, h) = prefs.windowSize()
        guard makeWindow(main, title: "Network Audio Sender", width: w, height: h) else { return false }
        ShowWindow(hwnd, SW_SHOW)
        UpdateWindow(hwnd)
        startTimer(hz: 30)
        inserts.start()
        return true
    }

    private var lastQuarter = Date.distantPast

    override func timerTick() {
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        if case .running(let rate, let channels) = sender.captureStatus { processor.configure(rate: rate, channels: channels) }
        let now = Date()
        if now.timeIntervalSince(lastQuarter) >= 0.25 { lastQuarter = now; inserts.tick() }
        tooltipsAndRepaint()
    }

    override func keyDown(_ key: Int32, ctrl: Bool, shift: Bool) -> Bool {
        if key == VK_ESCAPE, prefs.showSettings { prefs.showSettings = false; return true }
        if ctrl, key == 0xBC { prefs.showSettings.toggle(); return true }                // Ctrl+,
        return false
    }

    override func mainResized(width: Double, height: Double) { prefs.rememberWindowSize(width, height) }
    override func systemLookChanged() { restyle() }
    override func closingMain() {
        inserts.shutdown()
        sender.shutdown()
    }
    override func log(_ text: String, _ kind: ActivityLog.Kind) { sender.note(kind, text) }
    override func minimumSize() -> (Double, Double) { (460, 460) }

    func openConnect() {
        if connect == nil { connect = SenderConnectWindow(owner: self) }
        connect?.show()
    }

    // MARK: - Drawing

    override func drawMain(_ c: Canvas, _ client: RECT) {
        let toolbar = RECT(left: 0, top: 0, right: client.right, bottom: c.s(44))
        drawToolbar(c, toolbar)
        c.hline(toolbar.bottom, 0, client.right, c.p.divider)
        let body = RECT(left: 0, top: toolbar.bottom + 1, right: client.right, bottom: client.bottom)
        if prefs.showSettings {
            drawSettings(c, body)
            return
        }
        let status = RECT(left: 0, top: client.bottom - c.s(34), right: client.right, bottom: client.bottom)
        c.hline(status.top - 1, 0, client.right, c.p.divider)
        drawStatusBar(c, status)
        sendUI.drawColumn(c, RECT(left: 0, top: body.top, right: client.right, bottom: status.top - 1), key: "sender", header: false) {
            [unowned self] c, r in
            let y = self.drawInserts(self.inserts, c, r, open: self.prefs.insertsOpen, key: "fold-sinserts", showCount: true) {
                [unowned self] in self.prefs.insertsOpen.toggle()
            }
            c.hline(y, r.left, r.right, c.p.divider)
            return y + 1
        }
    }

    private func drawToolbar(_ c: Canvas, _ r: RECT) {
        let pad = c.s(14)
        var x = r.left + pad
        let cy = (r.top + r.bottom) / 2
        let size = 22.0
        let mark = RECT(x: x, y: cy - c.s(size) / 2, width: c.s(size), height: c.s(size))
        drawEmblem(c, mark, sender: true)
        x = mark.right + c.s(size * 0.32)
        let nf = c.font((size * 0.6).rounded(), .semibold)
        c.text("Sender", RECT(left: x, top: r.top, right: x + c.width("Sender", nf) + 2, bottom: r.bottom), nf, c.p.window.over(c.p.muted, 0.6))
        x += c.width("Sender", nf) + c.s(10)
        c.vline(x, cy - c.s(9), cy + c.s(9), c.p.divider)
        x += c.s(10)

        // Which networks the offer is announced on.
        let chosen = sender.offerInterfaces
        let up = Set(sender.networks.map(\.name))
        let live = chosen.isEmpty || !chosen.isDisjoint(with: up)
        let names = chosen.sorted()
        let title = chosen.isEmpty ? "All networks"
            : (names.count <= 2 ? names.joined(separator: " / ") : names.prefix(2).joined(separator: " / ") + " / +\(names.count - 2)")
        c.ellipse(RECT(x: x, y: cy - c.s(3), width: c.s(6), height: c.s(6)), live ? c.p.green : c.p.warning)
        let ml = c.menuLabel(title, x: x + c.s(11), RECT(left: x, top: r.top, right: r.right - c.s(200), bottom: r.bottom), size: 12,
                             colour: live ? c.p.active : c.p.warning, weight: .medium)
        let netHit = RECT(left: x - c.s(2), top: r.top + c.s(8), right: ml.right, bottom: r.bottom - c.s(8))
        hit(netHit, "networks",
            tip: tooltip("Where the offer to Grabbers is announced: every network this PC is on, or the ones ticked — as many as you like. "
                         + "Addresses under Receivers are reached whichever are chosen.",
                         now: chosen.isEmpty ? "All networks." : (live ? names.joined(separator: ", ") + "."
                                                                        : "None of the chosen networks is connected, so the offer is not announced."))) {
            [unowned self] _ in self.popup(self.sendUI.networkMenuEntries(), at: POINT(x: netHit.left, y: netHit.bottom))
        }
        x = netHit.right + c.s(10)
        c.vline(x, cy - c.s(7), cy + c.s(7), c.p.divider)
        x += c.s(10)

        // The gear, from the right.
        let gear = RECT(x: r.right - pad - c.s(22), y: cy - c.s(11), width: c.s(22), height: c.s(22))
        if isHover("gear") { c.round(gear, 5, c.p.label, alpha: 0.08) }
        c.icon("\u{E713}", gear, size: 12, prefs.showSettings ? c.p.active : (isHover("gear") ? c.p.text : c.p.secondary))
        hit(gear, "gear", tip: prefs.showSettings ? "Back to sending (Ctrl+,)" : "Settings (Ctrl+,)") { [unowned self] _ in
            self.commitField(); self.prefs.showSettings.toggle()
        }

        // What is being sent: the source menu, then the rate of the device behind it.
        let room = RECT(left: x, top: r.top, right: gear.left - c.s(10), bottom: r.bottom)
        let rate = sender.outputDevice()?.rate ?? 0
        let rateText = rate > 0 && !SendSourceText.isInput(sender) ? String(format: "%.4g kHz", Double(rate) / 1000) : ""
        let rf = c.font(10)
        let rw = c.width(rateText, rf)
        let label = SendSourceText.short(sender)
        c.icon(SendSourceText.glyph(sender), RECT(x: room.left, y: r.top, width: c.s(14), height: r.height), size: 10, c.p.active)
        let sl = c.menuLabel(label, x: room.left + c.s(18), RECT(left: room.left, top: r.top, right: room.right - rw - c.s(8), bottom: r.bottom), size: 11,
                             colour: c.p.active)
        hit(RECT(left: room.left, top: r.top + c.s(8), right: sl.right, bottom: r.bottom - c.s(8)), "tsource",
            tip: SendSourceText.tooltip(sender, excludesOwnPlayback: false, app: "Sender")) { [unowned self] _ in
            self.sendUI.sourceMenu(at: POINT(x: room.left, y: r.bottom - c.s(8)))
        }
        if !rateText.isEmpty {
            c.text(rateText, RECT(left: sl.right + c.s(6), top: r.top, right: sl.right + c.s(6) + rw + 2, bottom: r.bottom), rf,
                   rate == 48000 || rate == 44100 ? c.p.secondary : c.p.warning)
        }
    }

    private func drawStatusBar(_ c: Canvas, _ r: RECT) {
        let pad = c.s(12)
        let cy = (r.top + r.bottom) / 2
        c.ellipse(RECT(x: r.left + pad, y: cy - c.s(3), width: c.s(6), height: c.s(6)), sender.isActive ? c.p.green : c.p.label,
                  alpha: sender.isActive ? 1 : 0.4)
        var bx = r.right - pad
        if sender.isActive {
            let w = c.buttonWidth("Stop all")
            let b = RECT(x: bx - w, y: cy - c.s(10), width: w, height: c.s(20))
            c.button("Stop all", b, hover: isHover("stopall"))
            hit(b, "stopall", tip: "Stop every send and the offer: nothing leaves this PC.") { [unowned self] _ in self.sender.stopAll() }
            bx = b.left - c.s(8)
        }
        let cf = c.font(11)
        let cw = c.width("Connect…", cf) + c.s(30)
        let connectB = RECT(x: bx - cw, y: cy - c.s(10), width: cw, height: c.s(20))
        c.button("", connectB, hover: isHover("connect"))
        c.icon("\u{E8EE}", RECT(x: connectB.left + c.s(7), y: connectB.top, width: c.s(12), height: connectB.height), size: 10, c.p.secondary)
        c.text("Connect…", RECT(left: connectB.left + c.s(22), top: connectB.top, right: connectB.right, bottom: connectB.bottom), cf, c.p.text)
        hit(connectB, "connect", tip: "Steps for Network Audio Grabber on the same network, over VBAN — the one protocol the Sender sends — "
                                      + "and the other ways to connect.") { [unowned self] _ in self.openConnect() }
        c.text(statusText, RECT(left: r.left + pad + c.s(12), top: r.top, right: connectB.left - c.s(8), bottom: r.bottom), c.font(11), c.p.muted)
    }

    private var statusText: String {
        guard sender.isActive else { return sender.offering ? "Offering, nobody listening" : "Not sending" }
        let n = sender.sending.count, l = sender.listeners.count
        let rate = sender.bitrateKbps >= 1000 ? String(format: "%.1f Mbit/s", sender.bitrateKbps / 1000) : String(format: "%.0f kbit/s", sender.bitrateKbps)
        var parts: [String] = []
        if n > 0 { parts.append("\(n) target\(n == 1 ? "" : "s")") }
        if l > 0 { parts.append("\(l) listening") }
        return "Sending to " + parts.joined(separator: " and ") + " · \(rate)"
    }

    // MARK: - Settings (one page, as the Mac Sender's), with the Log beside it

    private func drawSettings(_ c: Canvas, _ r: RECT) {
        let pad = c.s(16)
        let head = RECT(left: r.left + pad, top: r.top + c.s(12), right: r.right - pad, bottom: r.top + c.s(34))
        c.icon("\u{E713}", RECT(x: head.left, y: head.top, width: c.s(16), height: head.height), size: 12, c.p.active)
        let tf = c.font(14, .semibold)
        c.text("Settings", RECT(left: head.left + c.s(22), top: head.top, right: head.left + c.s(22) + c.width("Settings", tf) + 2, bottom: head.bottom), tf, c.p.text)
        let seg = RECT(x: head.left + c.s(30) + c.width("Settings", tf), y: head.top, width: c.s(140), height: head.height)
        for (i, rr) in c.segmented(["Settings", "Log"], seg, selected: prefs.showsLog ? 1 : 0).enumerated() {
            hit(rr, "slog-\(i)") { [unowned self] _ in self.prefs.showsLog = i == 1 }
        }
        let dw = c.buttonWidth("Done")
        let done = RECT(x: head.right - dw, y: head.top + c.s(1), width: dw, height: c.s(20))
        c.button("Done", done, hover: isHover("done"))
        hit(done, "done", tip: "Back to sending (Ctrl+,)") { [unowned self] _ in self.commitField(); self.prefs.showSettings = false }
        let qf = c.font(11)
        let qr = RECT(left: done.left - c.s(30), top: head.top, right: done.left - c.s(8), bottom: head.bottom)
        c.icon("\u{E897}", qr, size: 11, isHover("qs") ? c.p.text : c.p.active)
        hit(qr, "qs", tip: "Quick Start Guide") { [unowned self] _ in self.open(besideApp: "QUICK-START.html") }
        _ = qf

        let content = RECT(left: r.left, top: head.bottom + c.s(10), right: r.right, bottom: r.bottom)
        let key = prefs.showsLog ? "senderlog" : "sendersettings"
        let offset = beginScroll(key, content, c)
        let f = Form(c, self, left: content.left + pad, right: content.right - pad, top: content.top - offset + c.s(4))
        if prefs.showsLog { logPage(f) } else { settingsPage(f) }
        endScroll(key, content: f.y - (content.top - offset) + c.s(12), c)
    }

    private func settingsPage(_ f: Form) {
        let c = f.c
        sendUI.settings(f)

        f.toggle("Show dry/wet on inserts", on: prefs.showInsertMix) { [unowned self] in self.prefs.showInsertMix.toggle() }
        f.section("Inserts", footer: "The audio is sent after the inserts, so every target hears them. With nothing loaded they are out of the "
                  + "path entirely. VST3 effects from C:\\Program Files\\Common Files\\VST3.")

        f.note("Windows cannot silence this PC's own output for one app without silencing what is captured, so there is no “mute this PC "
               + "while sending” here.")
        f.section("This PC")

        f.custom(c.s(32)) { [unowned self] r in
            let w = c.buttonWidth("Connect…")
            let b = RECT(x: r.left, y: r.top + c.s(6), width: w, height: c.s(20))
            c.button("Connect…", b, hover: self.isHover("setconnect"))
            self.hit(b, "setconnect") { [unowned self] _ in self.openConnect() }
            c.text("The steps for a Grabber on this network, and the other ways to connect.", RECT(left: b.right + c.s(10), top: r.top, right: r.right, bottom: r.bottom),
                   c.font(11), c.p.muted)
        }
        f.section("Connecting")

        let forced = prefs.skin.style.dark
        f.segmented("Appearance", options: Appearance.allCases.map(\.label), selected: Appearance.allCases.firstIndex(of: prefs.appearance) ?? 2,
                    tip: forced == nil ? "Light, dark, or follow Windows." : "This colour scheme has its own look, so it sets the appearance.",
                    enabled: forced == nil) { [unowned self] i in self.prefs.appearance = Appearance.allCases[i]; self.restyle() }
        let selection = !prefs.themeEnabled ? "System colour scheme" : (prefs.preset?.name ?? "Custom")
        f.popupRow("Colour scheme", value: selection, width: 240) { [unowned self] in
            var entries: [MenuEntry] = [.item("System colour scheme", checked: !self.prefs.themeEnabled) { [unowned self] in
                self.prefs.themeEnabled = false; self.restyle()
            }, .separator]
            for p in ThemePreset.all + [] { entries.append(self.schemeItem(p)) }
            entries.append(.separator)
            for p in ThemePreset.looks { entries.append(self.schemeItem(p)) }
            entries.append(.separator)
            entries.append(.item("Custom", checked: self.prefs.themeEnabled && self.prefs.preset == nil) { [unowned self] in
                self.prefs.themeEnabled = true; self.restyle()
            })
            return entries
        }
        if let forced { f.note("This scheme has its own look and is always \(forced ? "dark" : "light"), so Appearance is set by it.") }
        f.labeled("Colours") { [unowned self] r in
            var x = r.left + c.s(40)
            for (label, hex, isPrimary) in [("Window", self.prefs.themePrimaryHex, true), ("Active", self.prefs.themeSecondaryHex, false)] {
                let well = RECT(x: x, y: r.top + c.s(6), width: c.s(36), height: r.height - c.s(12))
                let colour = Colour(hex: hex) ?? .black
                c.round(well, 5, colour, alpha: self.prefs.themeEnabled ? 1 : 0.45, border: c.p.label, borderAlpha: 0.25)
                c.text(label, RECT(left: well.right + c.s(6), top: r.top, right: well.right + c.s(70), bottom: r.bottom), c.font(11), c.p.muted)
                self.hit(well, "well-\(label)", tip: "Choose the \(label.lowercased()) colour. Editing a colour makes a custom scheme.") { [unowned self] _ in
                    if let picked = self.chooseColour(colour) {
                        if isPrimary { self.prefs.themePrimaryHex = picked.hexString } else { self.prefs.themeSecondaryHex = picked.hexString }
                        self.prefs.themeEnabled = true
                        self.restyle()
                    }
                }
                x = well.right + c.s(90)
            }
        }
        f.section("Theme")

        f.explainer("What is sent, and what is left out",
                    "**System audio** is everything this PC plays on its default playback device, except Network Audio Grabber — so a PC running "
                    + "both cannot send the Grabber's playback straight back out. **An app** sends that app alone. **An input device** sends it "
                    + "whole, at its own channel count. Capture runs only while something is being sent.\n\nThe audio is plain VBAN, so it plays "
                    + "in the Grabber, Voicemeeter and VBAN Receptor alike, and is not encrypted on this network. A Remote link to another place "
                    + "is encrypted end to end; so is a VPN such as Tailscale.")

        func item(_ title: String, _ detail: String) {
            let h = (title.isEmpty ? 0 : c.s(17)) + c.wrappedHeight(detail, width: f.inner, c.font(11)) + c.s(10)
            f.custom(h) { r in
                var y = r.top + c.s(5)
                if !title.isEmpty {
                    c.text(title, RECT(left: r.left, top: y, right: r.right, bottom: y + c.s(16)), c.font(12, .semibold), c.p.text)
                    y += c.s(17)
                }
                c.wrapped(detail, RECT(left: r.left, top: y, right: r.right, bottom: r.bottom), c.font(11), c.p.muted)
            }
        }
        item("Network Audio Sender \(senderVersion) for Windows", "The same engine as the Mac Sender, so a stream from a PC and a stream from a Mac are the same stream.")
        f.custom(c.s(34)) { [unowned self] r in
            var x = r.left
            for (title, file) in [("Quick Start Guide", "QUICK-START.html"), ("Licences folder", "Licences")] {
                let w = c.buttonWidth(title)
                let b = RECT(x: x, y: r.top + c.s(7), width: w, height: c.s(20))
                c.button(title, b, hover: self.isHover("open-\(file)"))
                self.hit(b, "open-\(file)") { [unowned self] _ in self.open(besideApp: file) }
                x = b.right + c.s(8)
            }
        }
        item("Works with", "VBAN (VB-Audio Software, from its published specification) — Network Audio Grabber, Voicemeeter and any VBAN receiver; "
             + "VST 3 (Steinberg Media Technologies).")
        item("Built with", "Swift and Foundation (Apache 2.0 with the Runtime Library Exception), ICU (Unicode License V3), swift-crypto with "
             + "BoringSSL and XKCP for the Remote link, and Steinberg's VST 3 SDK (MIT) for the inserts. Windows: WASAPI, GDI and GDI+.")
        item("", "VBAN and Voicemeeter are trademarks of VB-Audio Software. VST is a trademark of Steinberg Media Technologies GmbH. Not affiliated "
             + "with, or endorsed by, any of them.")
        f.section("Credits", footer: "© 2026 DAT Audio · free software, MIT licence. The full licence texts are in the Licences folder beside the app.")
    }

    private func schemeItem(_ p: ThemePreset) -> MenuEntry {
        .item(p.name, checked: prefs.themeEnabled && prefs.preset?.name == p.name) { [unowned self] in
            self.prefs.themePrimaryHex = p.primary
            self.prefs.themeSecondaryHex = p.secondary
            self.prefs.themeEnabled = true
            self.restyle()
        }
    }

    private func logPage(_ f: Form) {
        let c = f.c
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        let entries = Array(sender.activity.entries.reversed().prefix(400))
        if entries.isEmpty { f.note("Nothing has happened yet.") }
        for entry in entries {
            let h = c.wrappedHeight(entry.text, width: f.inner - c.s(130), c.font(11)) + c.s(8)
            f.custom(max(c.s(24), h)) { r in
                c.text(clock.string(from: entry.date), RECT(left: r.left, top: r.top + c.s(4), right: r.left + c.s(60), bottom: r.top + c.s(20)),
                       c.font(10), c.p.muted, top: true)
                let kc = entry.kind == .failed ? c.p.red : (entry.kind == .warning ? c.p.warning : c.p.muted)
                c.text(entry.kind.label, RECT(left: r.left + c.s(62), top: r.top + c.s(4), right: r.left + c.s(124), bottom: r.top + c.s(20)),
                       c.font(10, .semibold), kc, top: true)
                c.wrapped(entry.text, RECT(left: r.left + c.s(128), top: r.top + c.s(4), right: r.right, bottom: r.bottom), c.font(11), c.p.text)
            }
        }
        f.section(footer: "Newest first. Kept between runs in %LOCALAPPDATA%\\Network Audio Sender.")
    }
}

/// "Connect to a Grabber…" (the Mac's `ConnectToGrabber`): the steps for a Grabber on this network,
/// ticked off as they happen, and the other ways — the Remote link, a VPN, by address.
final class SenderConnectWindow {
    unowned let owner: SenderAppWindow
    private(set) var surface: Surface!
    var hwnd: HWND? { surface.hwnd }
    var whereChoice = 0
    var linkDraft = ""
    var linkError: String?
    var justLinked = false

    init(owner: SenderAppWindow) {
        self.owner = owner
        surface = Surface(paint: { [unowned self] c, r in self.draw(c, r) }, minimum: { (420, 480) })
    }

    func show() {
        if surface.hwnd == nil {
            guard owner.makeWindow(surface, title: "Connect — Network Audio Sender", width: 460, height: 640) else { return }
        }
        ShowWindow(hwnd, SW_SHOW)
        SetForegroundWindow(hwnd)
    }

    private var w: SenderAppWindow { owner }
    private var s: WindowsSender { owner.sender }

    private func draw(_ c: Canvas, _ r: RECT) {
        let offset = w.beginScroll("sconnect", r, c)
        let pad = c.s(18)
        let left = r.left + pad, right = r.right - pad
        var y = r.top + pad - offset
        c.text("Connect to a Grabber over VBAN", RECT(left: left, top: y, right: right, bottom: y + c.s(20)), c.font(15, .semibold), c.p.text)
        y += c.s(26)
        c.icon("\u{E785}", RECT(x: left, y: y, width: c.s(14), height: c.s(16)), size: 10, c.p.warning)
        y += c.wrapped("Not encrypted: use this on a network you trust, such as at home, in a studio or an office.",
                       RECT(left: left + c.s(18), top: y, right: right, bottom: y + c.s(40)), c.font(11), c.p.warning) + c.s(10)
        // Where is the other end?
        c.text("Where is the other end?", RECT(left: left, top: y, right: right, bottom: y + c.s(18)), c.font(12, .semibold), c.p.text)
        y += c.s(22)
        let cardW = (right - left - c.s(10)) / 2
        for (i, (glyph, title, text)) in [("\u{E80F}", "On this network", "The same home, studio or office."),
                                          ("\u{E774}", "Somewhere else", "Another building, across the internet.")].enumerated() {
            let card = RECT(x: left + Int32(i) * (cardW + c.s(10)), y: y, width: cardW, height: c.s(58))
            let on = whereChoice == i
            c.round(card, 8, c.p.label, alpha: on ? 0.08 : 0.03, border: on ? c.p.active : c.p.label, borderAlpha: on ? 1 : 0.12, borderWidth: on ? 1.5 : 1)
            c.icon(glyph, RECT(x: card.left + c.s(9), y: card.top + c.s(8), width: c.s(14), height: c.s(16)), size: 12, c.p.active)
            c.text(title, RECT(left: card.left + c.s(28), top: card.top + c.s(8), right: card.right - c.s(8), bottom: card.top + c.s(24)), c.font(12, .semibold), c.p.text)
            c.wrapped(text, RECT(left: card.left + c.s(9), top: card.top + c.s(28), right: card.right - c.s(9), bottom: card.bottom), c.font(10), c.p.muted)
            w.hit(card, "swhere-\(i)") { [unowned self] _ in self.whereChoice = i }
        }
        y += c.s(66)
        y += c.rich("Already on a VPN such as Tailscale? Choose **On this network**: the VPN makes the other place part of it.",
                    RECT(left: left, top: y, right: right, bottom: y + c.s(40)), size: 10, c.p.muted) + c.s(10)
        y = whereChoice == 0 ? drawHere(c, left: left, right: right, y: y) : drawElsewhere(c, left: left, right: right, y: y)
        w.endScroll("sconnect", content: y - (r.top - offset) + pad, c)
    }

    private func drawHere(_ c: Canvas, left: Int32, right: Int32, y top: Int32) -> Int32 {
        var y = top
        let stream = VBAN.wireName(s.streamName).isEmpty ? "PC Audio" : VBAN.wireName(s.streamName)
        let connected = !s.listeners.isEmpty
        y += c.wrapped("For Network Audio Grabber on the same network. Nothing to type. VBAN is simple, unicast and works on any network, Wi-Fi "
                       + "included, which is why it is the one the Sender uses.", RECT(left: left, top: y, right: right, bottom: y + c.s(60)),
                       c.font(11), c.p.muted) + c.s(10)
        func step(_ n: Int, done: Bool?, _ text: String, button: (String, () -> Void)? = nil) {
            let dot = RECT(x: left, y: y, width: c.s(18), height: c.s(18))
            c.ellipse(dot, done == true ? c.p.green : c.p.label, alpha: done == true ? 1 : 0.08)
            if done == true { c.icon("\u{E73E}", dot, size: 9, .white) } else { c.text("\(n)", dot, c.font(10, .semibold), c.p.muted, align: .centre) }
            let tx = dot.right + c.s(10)
            y += c.wrapped(text, RECT(left: tx, top: y + c.s(1), right: right, bottom: y + c.s(60)), c.font(12), c.p.text) + c.s(4)
            if let (title, action) = button {
                let bw = c.buttonWidth(title)
                let b = RECT(x: tx, y: y, width: bw, height: c.s(20))
                c.button(title, b, hover: w.isHover("sstep-\(n)"))
                w.hit(b, "sstep-\(n)") { _ in action() }
                y += c.s(24)
            }
            y += c.s(8)
        }
        step(1, done: nil, "On the other computer, open Network Audio Grabber. In Settings → Discovery, turn on VBAN.")
        step(2, done: s.offering, "Make this PC findable by Grabbers.", button: s.offering ? nil : ("Turn on", { [unowned self] in self.s.offering = true }))
        step(3, done: !s.requests.isEmpty || connected, "In the Grabber, press play on “\(stream)”.")
        step(4, done: connected, s.askFirst ? "Allow it here when it asks." : "It starts playing.")
        y = w.sendUI.drawRequests(c, RECT(left: left - c.s(12), top: y, right: right + c.s(12), bottom: y))
        if connected {
            c.icon("\u{E73E}", RECT(x: left, y: y, width: c.s(14), height: c.s(16)), size: 10, c.p.green)
            c.text("Connected: \(s.listeners.map { $0.name ?? $0.ip }.joined(separator: ", ")) listening.",
                   RECT(left: left + c.s(18), top: y, right: right, bottom: y + c.s(16)), c.font(12, .medium), c.p.green)
            y += c.s(22)
        }
        c.hline(y, left, right, c.p.divider)
        y += c.s(10)
        c.text("Which way to connect", RECT(left: left, top: y, right: right, bottom: y + c.s(16)), c.font(11, .semibold), c.p.text)
        y += c.s(20)
        func guide(_ title: String, _ text: String) {
            c.text(title, RECT(left: left, top: y, right: right, bottom: y + c.s(15)), c.font(11, .medium), c.p.text)
            y += c.s(15)
            y += c.wrapped(text, RECT(left: left, top: y, right: right, bottom: y + c.s(60)), c.font(11), c.p.muted) + c.s(8)
        }
        guide("Network Audio Grabber, same network",
              "The steps above: the Grabber finds this PC by itself, and the audio goes only to Grabbers you allow.")
        guide("Network Audio Grabber over a VPN",
              "Turn on Findable by Grabbers. In that Grabber, open Settings → Discovery and add this PC's address, port \(VBANControl.controlPort):")
        if !s.localAddresses.isEmpty {
            c.text(s.localAddresses.joined(separator: "   "), RECT(left: left + c.s(12), top: y - c.s(4), right: right, bottom: y + c.s(12)), c.font(10), c.p.text)
            y += c.s(18)
        }
        guide("Any other VBAN receiver, such as Voicemeeter",
              "Add its address with + beside Receivers. It receives the stream whether or not it asks, so only add receivers you mean to send to.")
        return y
    }

    private func drawElsewhere(_ c: Canvas, left: Int32, right: Int32, y top: Int32) -> Int32 {
        var y = top
        let methods: [(String, String?, String)] = [
            ("Remote link", "RECOMMENDED", "Swap a code with the other end. Encrypted, and nothing to set up on a router."),
            ("VPN", nil, "Already use Tailscale or similar? The other place is then part of your network."),
            ("By address", nil, "For other VBAN receivers, such as Voicemeeter. Needs a port opened on a router."),
        ]
        for (i, (title, tag, summary)) in methods.enumerated() {
            let chosen = s.remoteMethod == i
            let headH = c.wrappedHeight(summary, width: right - left - c.s(50), c.font(11)) + c.s(34)
            var detailBottom = y + headH
            if chosen {
                let inner = RECT(left: left + c.s(12), top: y + headH + c.s(10), right: right - c.s(12), bottom: y)
                switch i {
                case 0: detailBottom = drawRemoteLink(c, inner) + c.s(10)
                case 1:
                    var dy = inner.top
                    dy += c.wrapped("With a VPN such as Tailscale on both computers, the other place is part of this network — encrypted, and nothing to "
                                    + "open on a router. The Grabber then finds this PC as usual; if not, add it by its VPN address there.",
                                    RECT(left: inner.left, top: dy, right: inner.right, bottom: dy + c.s(80)), c.font(11), c.p.muted) + c.s(6)
                    let bw = c.buttonWidth("Use On this network")
                    let b = RECT(x: inner.left, y: dy, width: bw, height: c.s(20))
                    c.button("Use On this network", b, hover: w.isHover("svpn"))
                    w.hit(b, "svpn") { [unowned self] _ in self.whereChoice = 0 }
                    detailBottom = b.bottom + c.s(10)
                default:
                    var dy = w.drawSenderRemoteWarning(c, inner)
                    dy += c.wrapped("Add the other network's outside address with + under Receivers; the router there forwards UDP \(VBAN.port) to the "
                                    + "Grabber's computer.", RECT(left: inner.left, top: dy, right: inner.right, bottom: dy + c.s(60)), c.font(11), c.p.muted)
                    detailBottom = dy + c.s(10)
                }
            }
            let box = RECT(left: left, top: y, right: right, bottom: detailBottom)
            c.round(box, 8, c.p.label, alpha: chosen ? 0.05 : 0.02, border: chosen ? c.p.active : c.p.label, borderAlpha: chosen ? 0.8 : 0.12,
                    borderWidth: chosen ? 1.5 : 1)
            let radio = RECT(x: box.left + c.s(10), y: y + c.s(11), width: c.s(13), height: c.s(13))
            c.ellipse(radio, nil, border: chosen ? c.p.active : c.p.muted, borderWidth: 1.2)
            if chosen { c.ellipse(radio.inset(by: c.s(3)), c.p.active) }
            let tf = c.font(12, .semibold)
            c.text(title, RECT(left: radio.right + c.s(9), top: y + c.s(9), right: radio.right + c.s(9) + c.width(title, tf) + 2, bottom: y + c.s(26)), tf, c.p.text)
            if let tag { _ = c.chip(tag, x: radio.right + c.s(15) + c.width(title, tf), centreY: y + c.s(17), tint: c.p.active, filled: true) }
            c.wrapped(summary, RECT(left: radio.right + c.s(9), top: y + c.s(27), right: box.right - c.s(10), bottom: y + headH), c.font(11), c.p.muted)
            w.hit(RECT(left: box.left, top: y, right: box.right, bottom: y + headH), "smethod-\(i)") { [unowned self] _ in self.s.remoteMethod = i }
            y = box.bottom + c.s(8)
        }
        return y
    }

    private func drawRemoteLink(_ c: Canvas, _ r: RECT) -> Int32 {
        let left = r.left, right = r.right
        var y = r.top
        y += c.wrapped("With a Grabber at the other place — or several, one link each. Both ends do both steps.",
                       RECT(left: left, top: y, right: right, bottom: y + c.s(40)), c.font(11), c.p.muted) + c.s(9)
        func stepHead(_ n: Int, _ text: String) {
            let dot = RECT(x: left, y: y, width: c.s(18), height: c.s(18))
            c.ellipse(dot, c.p.label, alpha: 0.1)
            c.text("\(n)", dot, c.font(11, .bold), c.p.text, align: .centre)
            y += c.wrapped(text, RECT(left: left + c.s(26), top: y + c.s(1), right: right, bottom: y + c.s(60)), c.font(11), c.p.text) + c.s(6)
        }
        let x0 = left + c.s(26)
        stepHead(1, "Make this end's code, and send it to the other end — by message or email. The same code does for every other end.")
        if let code = s.remoteCode {
            let mono = c.font(11)
            let h = c.wrappedHeight(code.text, width: right - x0 - c.s(80), mono) + c.s(8)
            let box = RECT(left: x0, top: y, right: right - c.s(66), bottom: y + h)
            c.round(box, 5, c.p.label, alpha: 0.07)
            c.wrapped(code.text, RECT(left: box.left + c.s(8), top: box.top + c.s(4), right: box.right - c.s(8), bottom: box.bottom), mono, c.p.text)
            let cb = RECT(x: right - c.s(58), y: y, width: c.s(58), height: c.s(20))
            c.button("Copy", cb, hover: w.isHover("scopy"))
            w.hit(cb, "scopy") { [unowned self] _ in self.w.copyToClipboard(code.text) }
            y = box.bottom + c.s(6)
            if let made = s.remoteCodeMadeAt {
                let left2 = 15 * 60 - Date().timeIntervalSince(made)
                c.text(left2 > 0 ? "Good for about \(max(1, Int(left2 / 60 + 0.5))) more minutes, to be pasted at the other end." : "This code has lapsed.",
                       RECT(left: x0, top: y, right: right, bottom: y + c.s(14)), c.font(10), left2 > 0 ? c.p.muted : c.p.warning)
                y += c.s(16)
            }
        } else {
            let title = s.makingRemoteCode ? "Making…" : "Make this end's code"
            let bw = c.buttonWidth(title)
            let b = RECT(x: x0, y: y, width: bw, height: c.s(20))
            c.button(title, b, hover: w.isHover("smake"), enabled: !s.makingRemoteCode)
            w.hit(b, "smake") { [unowned self] _ in if !self.s.makingRemoteCode { self.s.makeRemoteCode() } }
            y += c.s(26)
        }
        if let e = s.remoteCodeError { y += c.wrapped(e, RECT(left: x0, top: y, right: right, bottom: y + c.s(40)), c.font(10), c.p.warning) + c.s(4) }
        y += c.wrapped(OutsideAddress.note, RECT(left: x0, top: y, right: right, bottom: y + c.s(40)), c.font(9), c.p.muted) + c.s(10)
        stepHead(2, s.remoteLinks.isEmpty ? "Paste the other end's code." : "Paste another end's code, to link one more.")
        let fieldRect = RECT(left: x0, top: y, right: right - c.s(84), bottom: y + c.s(22))
        w.fieldFrames["slink"] = fieldRect
        c.field(w.fieldKey == "slink" ? "" : linkDraft, fieldRect, placeholder: "NAG-…", hover: w.isHover("slink"))
        let commit: (String) -> Void = { [unowned self] text in
            self.linkDraft = text
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            self.linkError = self.s.linkRemote(text)
            self.justLinked = self.linkError == nil
            if self.justLinked { self.linkDraft = "" }
        }
        w.hit(fieldRect, "slink") { [unowned self] _ in
            self.linkError = nil; self.justLinked = false
            self.w.beginField("slink", frame: fieldRect, text: self.linkDraft, commit: commit)
        }
        let cbw = c.buttonWidth("Connect")
        let go = RECT(x: right - cbw, y: y + c.s(1), width: cbw, height: c.s(20))
        c.button("Connect", go, hover: w.isHover("slinkgo"))
        w.hit(go, "slinkgo") { [unowned self] _ in if self.w.fieldKey == "slink" { self.w.commitField() } else { commit(self.linkDraft) } }
        y = fieldRect.bottom + c.s(6)
        if let e = linkError { y += c.wrapped(e, RECT(left: x0, top: y, right: right, bottom: y + c.s(60)), c.font(10), c.p.warning) + c.s(4) }
        let links = s.remoteLinkInfo
        if !links.isEmpty {
            let connected = links.filter(\.connected).count
            let paused = s.remoteLinksPaused
            let status = paused ? "Paused" : connected == 0 ? "Waiting for the other end"
                : connected == links.count ? (links.count == 1 ? "Connected" : "Connected to \(links.count)") : "Connected to \(connected) of \(links.count)"
            c.text(status + "  ·  encrypted", RECT(left: left, top: y, right: right - c.s(80), bottom: y + c.s(16)), c.font(12, .semibold),
                   !paused && connected > 0 ? c.p.green : c.p.warning)
            if paused {
                let bw = c.buttonWidth("Resume")
                let b = RECT(x: right - bw, y: y - c.s(2), width: bw, height: c.s(20))
                c.button("Resume", b, hover: w.isHover("sresume"))
                w.hit(b, "sresume") { [unowned self] _ in self.s.resumeRemoteLinks() }
            }
            y += c.s(22)
            for l in links {
                c.ellipse(RECT(x: left + c.s(2), y: y + c.s(5), width: c.s(6), height: c.s(6)), l.connected ? c.p.green : c.p.warning)
                c.text((l.name ?? l.key) + (l.connected ? " · Connected" : " · waiting for the other end to paste this end's code"),
                       RECT(left: left + c.s(14), top: y, right: right - c.s(70), bottom: y + c.s(16)), c.font(11), c.p.text)
                let bw = c.buttonWidth("Unlink", size: 10)
                let b = RECT(x: right - bw, y: y - c.s(1), width: bw, height: c.s(18))
                c.button("Unlink", b, hover: w.isHover("sunlink-\(l.key)"), size: 10)
                w.hit(b, "sunlink-\(l.key)") { [unowned self] _ in self.s.unlinkRemote(l.key) }
                y += c.s(22)
            }
            if justLinked {
                y += c.wrapped("Let in. Its row appears under Receivers when it plays the stream.", RECT(left: left, top: y, right: right, bottom: y + c.s(40)),
                               c.font(10), c.p.muted) + c.s(4)
            }
        }
        return y
    }
}

extension DrawnWindow {
    /// The warning box for reaching another place by address.
    func drawSenderRemoteWarning(_ c: Canvas, _ r: RECT) -> Int32 {
        let text = "**\(RemoteAddresses.warningTitle)** " + RemoteAddresses.warning(receivingEnd: false)
        let h = c.wrappedHeight(text.replacingOccurrences(of: "**", with: ""), width: r.width - c.s(36), c.font(11)) + c.s(20)
        let box = RECT(left: r.left, top: r.top, right: r.right, bottom: r.top + h)
        c.round(box, 6, Colour(1, 0.58, 0), alpha: 0.12)
        c.icon("\u{E7BA}", RECT(x: box.left + c.s(9), y: box.top + c.s(9), width: c.s(14), height: c.s(14)), size: 11, c.p.warning)
        c.rich(text, RECT(left: box.left + c.s(30), top: box.top + c.s(9), right: box.right - c.s(9), bottom: box.bottom), size: 11, c.p.text)
        return box.bottom + c.s(8)
    }
}

let senderVersion = "0.16.2"

/// `nag-sender`: the Sender with a window. Its whole start-up, so the executable is one line.
public func runSenderApp() -> Never {
    setvbuf(stdout, nil, _IONBF, 0)
    let arguments = Array(CommandLine.arguments.dropFirst())
    func flag(_ name: String) -> Bool { arguments.contains(name) }
    func value(_ name: String) -> String? {
        guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }
    func values(_ name: String) -> [String] {
        arguments.enumerated().compactMap { i, a in a == name && i + 1 < arguments.count ? arguments[i + 1] : nil }
    }
    if flag("--help") || flag("-h") {
        print("""
        nag-sender — the Windows Sender, with a window

          --to <ip[:port]>   add a receiver at this address (may be given more than once).
                             Added to the ones remembered; nothing is sent until started.
          --name <stream>    the stream's name, as listeners see it
          --bits 16|24       what is sent (24 unless changed)
          --stereo           fold to two channels instead of the device's own count
          --test             a throwaway settings suite and no log file, for trying it out
          --help             this

        Settings, receivers and the log are remembered between runs.
        """)
        exit(0)
    }
    FreeConsole()
    _ = OleInitialize(nil)
    _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT(bitPattern: -4))   // PER_MONITOR_AWARE_V2

    let testing = flag("--test")
    let suite = testing ? "app.networkaudiosender.windows.test" : "app.networkaudiosender.windows"
    if testing { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    var logFile: URL?
    if !testing, let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"] {
        let folder = URL(fileURLWithPath: base).appendingPathComponent("Network Audio Sender")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        logFile = folder.appendingPathComponent("activity-log.json")
    }
    let processor = VST3SendProcessor()
    let sender = WindowsSender(defaults: defaults, name: value("--name") ?? "PC Audio", processor: processor, logFile: logFile)
    configureSenderCapture(sender, forSenderApp: true)
    if let name = value("--name") { sender.streamName = name }
    if value("--bits") == "24" { sender.dataType = .int24 }
    if value("--bits") == "16" { sender.dataType = .int16 }
    if flag("--stereo") { sender.stereoOnly = true }
    for text in values("--to") {
        let parts = text.split(separator: ":", maxSplits: 1)
        let host = String(parts[0])
        let port = parts.count > 1 ? Int(parts[1]) ?? VBAN.port : VBAN.port
        if !sender.targets.contains(where: { $0.host == host && $0.port == port }) {
            sender.targets.append(SendTarget(host: host, port: port))
        }
    }
    sender.start()

    let window = SenderAppWindow(sender: sender, processor: processor, prefs: SenderPrefs(defaults))
    guard window.create() else {
        print("The window could not be made.")
        exit(1)
    }
    window.run()
    sender.shutdown()
    exit(0)
}
