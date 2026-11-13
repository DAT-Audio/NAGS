import Foundation
import WinSDK
import NetworkAudioEngine
import GrabberCore
import SenderCore

/// The Mac's grouped `Form`, for GDI: sections as rounded boxes of rows — a label on the left, its
/// control on the right — with a footer under each in caption type. Rows are gathered first and
/// drawn second, so a box knows its height before it is drawn.
final class Form {
    let c: Canvas
    let w: DrawnWindow
    let left: Int32, right: Int32
    var y: Int32

    init(_ c: Canvas, _ w: DrawnWindow, left: Int32, right: Int32, top: Int32) {
        self.c = c; self.w = w; self.left = left; self.right = right; self.y = top
    }

    struct Row { let height: Int32; let draw: (RECT) -> Void }
    private var rows: [Row] = []

    var inner: Int32 { right - left - c.s(24) }

    /// A labelled row: the label on the left, the control drawn into the rest.
    func labeled(_ label: String, height: Double = 32, tip: String? = nil, dimmed: Bool = false, control: @escaping (RECT) -> Void) {
        rows.append(Row(height: c.s(height)) { [c, w] r in
            let lf = c.font(12)
            let lw = c.width(label, lf)
            c.text(label, RECT(left: r.left, top: r.top, right: r.left + lw + 2, bottom: r.bottom), lf, dimmed ? c.p.secondary : c.p.text)
            if let tip { w.hit(RECT(left: r.left, top: r.top, right: r.left + lw, bottom: r.bottom), "tip-\(label)", tip: tip) }
            control(RECT(left: r.left + lw + c.s(12), top: r.top, right: r.right, bottom: r.bottom))
        })
    }

    /// A switch row (the Mac's `Toggle` in a grouped form): label left, switch right.
    func toggle(_ label: String, on: Bool, beta: Bool = false, enabled: Bool = true, tip: String? = nil, set: @escaping () -> Void) {
        rows.append(Row(height: c.s(32)) { [c, w] r in
            let lf = c.font(12)
            let lw = c.width(label, lf)
            c.text(label, RECT(left: r.left, top: r.top, right: min(r.right - c.s(40), r.left + lw + 2), bottom: r.bottom), lf,
                   enabled ? c.p.text : c.p.secondary)
            if beta { _ = c.betaBadge(x: r.left + lw + c.s(6), centreY: (r.top + r.bottom) / 2) }
            let sw = RECT(x: r.right - c.s(38), y: (r.top + r.bottom) / 2 - c.s(11), width: c.s(38), height: c.s(22))
            c.toggleSwitch(sw, on: on, enabled: enabled)
            w.hit(RECT(left: r.left, top: r.top, right: r.right, bottom: r.bottom), "toggle-\(label)", tip: tip) { _ in if enabled { set() } }
        })
    }

    /// Caption text inside a section.
    func note(_ text: String, colour: Colour? = nil, size: Double = 11) {
        let h = c.wrappedHeight(text, width: inner, c.font(size)) + c.s(8)
        rows.append(Row(height: h) { [c] r in
            c.wrapped(text, RECT(left: r.left, top: r.top + c.s(2), right: r.right, bottom: r.bottom), c.font(size), colour ?? c.p.muted)
        })
    }

    func custom(_ height: Int32, _ draw: @escaping (RECT) -> Void) { rows.append(Row(height: height, draw: draw)) }

    /// A slider and its figure (the buffers).
    func slider(_ label: String, value: Double, range: ClosedRange<Double>, step: Double, def: Double, unit: String,
                tip: String? = nil, set: @escaping (Double) -> Void) {
        labeled(label, tip: tip) { [c, w] r in
            let figure = "\(Int(value)) \(unit)"
            c.text(figure, RECT(left: r.right - c.s(46), top: r.top, right: r.right, bottom: r.bottom), c.font(12), c.p.text, align: .right)
            let track = RECT(left: max(r.left, r.right - c.s(260)), top: r.top + c.s(5), right: r.right - c.s(54), bottom: r.bottom - c.s(5))
            c.slider(track, fraction: (value - range.lowerBound) / (range.upperBound - range.lowerBound))
            w.sliderHit(track, track: track, "slider-\(label)", tip: tip, set: { f in
                let v = range.lowerBound + f * (range.upperBound - range.lowerBound)
                set(max(range.lowerBound, min(range.upperBound, (v / step).rounded() * step)))
            }, reset: { set(def) })
        }
    }

    /// A pop-up button on the right of a row, opening `entries`.
    func popupRow(_ label: String, value: String, width: Double = 200, tip: String? = nil, dimmed: Bool = false,
                  entries: @escaping () -> [DrawnWindow.MenuEntry]) {
        labeled(label, tip: tip, dimmed: dimmed) { [c, w] r in
            let bw = min(c.s(width), r.width)
            let b = RECT(x: r.right - bw, y: r.top + c.s(5), width: bw, height: r.height - c.s(10))
            c.popup(value, b, hover: w.isHover("popup-\(label)"), colour: dimmed ? c.p.secondary : nil)
            w.hit(b, "popup-\(label)", tip: tip) { [w] _ in
                if !dimmed { w.popup(entries(), at: POINT(x: b.left, y: b.bottom)) }
            }
        }
    }

    func segmented(_ label: String, options: [String], selected: Int, tip: String? = nil, enabled: Bool = true,
                   choose: @escaping (Int) -> Void) {
        labeled(label, tip: tip, dimmed: !enabled) { [c, w] r in
            let sw = min(c.segmentedWidth(options), r.width)
            let seg = RECT(x: r.right - sw, y: r.top + c.s(5), width: sw, height: r.height - c.s(10))
            let rects = c.segmented(options, seg, selected: selected)
            for (i, sr) in rects.enumerated() { w.hit(sr, "seg-\(label)-\(i)", tip: tip) { _ in if enabled { choose(i) } } }
        }
    }

    /// A typed value: a drawn box, Windows' edit control while typing.
    func field(_ label: String, key: String, value: String, placeholder: String = "", width: Double = 220,
               tip: String? = nil, trailing: String? = nil, commit: @escaping (String) -> Void) {
        labeled(label, tip: tip) { [c, w] r in
            var right = r.right
            if let trailing {
                let tf = c.font(11)
                c.text(trailing, RECT(left: right - c.width(trailing, tf), top: r.top, right: right, bottom: r.bottom), tf, c.p.muted)
                right -= c.width(trailing, tf) + c.s(6)
            }
            let fw = min(c.s(width), right - r.left)
            let box = RECT(x: right - fw, y: r.top + c.s(5), width: fw, height: r.height - c.s(10))
            w.fieldFrames[key] = box
            c.field(w.fieldKey == key ? "" : value, box, placeholder: placeholder, hover: w.isHover("field-\(key)"))
            w.hit(box, "field-\(key)", tip: tip) { [w] _ in w.beginField(key, frame: box, text: value, commit: commit) }
        }
    }

    /// Draws what was gathered as one box, with an optional header above and footer below.
    func section(_ header: String? = nil, footer: String? = nil) {
        if let header {
            y += c.s(6)
            c.text(header, RECT(left: left + c.s(4), top: y, right: right, bottom: y + c.s(18)), c.font(11, .semibold), c.p.muted)
            y += c.s(20)
        }
        if !rows.isEmpty {
            let pad = c.s(12)
            let total = rows.reduce(Int32(0)) { $0 + $1.height } + c.s(4) * 2
            let box = RECT(left: left, top: y, right: right, bottom: y + total)
            c.round(box, 8, c.p.label, alpha: c.p.dark ? 0.05 : 0.04, border: c.p.label, borderAlpha: 0.06)
            var ry = box.top + c.s(4)
            for (i, row) in rows.enumerated() {
                let rr = RECT(left: box.left + pad, top: ry, right: box.right - pad, bottom: ry + row.height)
                row.draw(rr)
                ry = rr.bottom
                if i < rows.count - 1 { c.hline(ry, box.left + pad, box.right - pad, c.p.hairline) }
            }
            y = box.bottom
        }
        rows.removeAll()
        if let footer {
            y += c.s(6)
            y += c.rich(footer, RECT(left: left + c.s(4), top: y, right: right - c.s(4), bottom: y + c.s(400)), size: 10, c.p.muted)
        }
        y += c.s(14)
    }

    /// Long-form guidance, shut until asked for (the Mac's `Explainer`).
    func explainer(_ title: String, _ text: String) {
        let open = w.openExplainers.contains(title)
        let head = RECT(left: left + c.s(4), top: y, right: right, bottom: y + c.s(20))
        c.icon("\u{E946}", RECT(x: head.left, y: head.top, width: c.s(14), height: head.height), size: 10, c.p.muted)
        let tf = c.font(11)
        c.text(title, RECT(left: head.left + c.s(18), top: head.top, right: head.left + c.s(18) + c.width(title, tf) + 2, bottom: head.bottom), tf,
               w.isHover("expl-\(title)") ? c.p.text : c.p.muted)
        c.chevron(RECT(left: head.left + c.s(20) + c.width(title, tf), top: head.top, right: head.left + c.s(32) + c.width(title, tf), bottom: head.bottom),
                  down: open, colour: c.p.muted, size: 7)
        w.hit(RECT(left: head.left, top: head.top, right: head.left + c.s(34) + c.width(title, tf), bottom: head.bottom), "expl-\(title)") { [w] _ in
            if open { w.openExplainers.remove(title) } else { w.openExplainers.insert(title) }
        }
        y = head.bottom + c.s(4)
        if open {
            y += c.rich(text, RECT(left: left + c.s(22), top: y, right: right - c.s(4), bottom: y + c.s(800)), size: 10, c.p.muted) + c.s(4)
        }
        y += c.s(10)
    }
}

extension GrabberWindow {
    func drawSettings(_ c: Canvas, _ r: RECT, compact: Bool) {
        let pane = view.settingsPane
        var body = r
        if compact {
            // A row of icons: there is no room for a sidebar.
            let rail = RECT(left: r.left, top: r.top, right: r.right, bottom: r.top + c.s(32))
            var x = rail.left + c.s(8)
            for item in SettingsPane.allCases {
                let b = RECT(x: x, y: rail.top + c.s(5), width: c.s(24), height: c.s(22))
                if item == pane { c.round(b, 5, c.p.active, alpha: 0.16) }
                c.icon(item.glyph, b, size: 12, item == pane ? c.p.active : c.p.muted)
                hit(b, "pane-\(item.rawValue)", tip: item.title) { [unowned self] _ in self.choosePane(item) }
                x = b.right + c.s(2)
                if x > rail.right - c.s(24) { break }
            }
            c.hline(rail.bottom, r.left, r.right, c.p.divider)
            body = RECT(left: r.left, top: rail.bottom + 1, right: r.right, bottom: r.bottom)
        } else {
            let side = RECT(left: r.left, top: r.top, right: r.left + c.s(150), bottom: r.bottom)
            c.fill(side, c.p.panel)
            var y = side.top + c.s(10)
            for item in SettingsPane.allCases {
                let b = RECT(left: side.left + c.s(8), top: y, right: side.right - c.s(8), bottom: y + c.s(25))
                if item == pane { c.round(b, 6, c.p.active, alpha: 0.16) } else if isHover("pane-\(item.rawValue)") { c.round(b, 6, c.p.label, alpha: 0.05) }
                c.icon(item.glyph, RECT(x: b.left + c.s(8), y: b.top, width: c.s(16), height: b.height), size: 11, item == pane ? c.p.active : c.p.muted)
                c.text(item.title, RECT(left: b.left + c.s(32), top: b.top, right: b.right, bottom: b.bottom), c.font(12, item == pane ? .semibold : .regular),
                       item == pane ? c.p.text : c.p.secondary)
                hit(b, "pane-\(item.rawValue)") { [unowned self] _ in self.choosePane(item) }
                y = b.bottom + c.s(1)
            }
            // The Quick Start Guide, at the foot of the list.
            let qs = RECT(left: side.left + c.s(16), top: side.bottom - c.s(30), right: side.right - c.s(8), bottom: side.bottom - c.s(10))
            c.icon("\u{E897}", RECT(x: qs.left, y: qs.top, width: c.s(14), height: qs.height), size: 10, c.p.active)
            c.text("Quick Start Guide", RECT(left: qs.left + c.s(18), top: qs.top, right: qs.right, bottom: qs.bottom), c.font(11),
                   isHover("quickstart") ? c.p.text : c.p.active)
            hit(qs, "quickstart") { [unowned self] _ in self.open(besideApp: "QUICK-START.html") }
            c.vline(side.right, r.top, r.bottom, c.p.divider)
            body = RECT(left: side.right + 1, top: r.top, right: r.right, bottom: r.bottom)
        }
        // The pane's heading, its line, and Done.
        let pad = c.s(16)
        let head = RECT(left: body.left + pad, top: body.top + c.s(12), right: body.right - pad, bottom: body.top + c.s(32))
        c.icon(pane.glyph, RECT(x: head.left, y: head.top, width: c.s(16), height: head.height), size: 12, c.p.active)
        c.text(pane.title, RECT(left: head.left + c.s(22), top: head.top, right: head.right - c.s(70), bottom: head.bottom), c.font(14, .semibold), c.p.text)
        let dw = c.buttonWidth("Done")
        let done = RECT(x: head.right - dw, y: head.top, width: dw, height: c.s(20))
        c.button("Done", done, hover: isHover("settingsdone"))
        hit(done, "settingsdone", tip: "Back to the streams (Ctrl+,)") { [unowned self] _ in self.commitField(); self.view.showSettings = false }
        let sub = RECT(left: head.left, top: head.bottom + c.s(2), right: head.right, bottom: head.bottom + c.s(32))
        let subH = c.wrapped(pane.subtitle, sub, c.font(11), c.p.muted)
        let content = RECT(left: body.left, top: sub.top + subH + c.s(10), right: body.right, bottom: body.bottom)
        let key = "settings-\(pane.rawValue)"
        let offset = beginScroll(key, content, c)
        let form = Form(c, self, left: content.left + pad, right: content.right - pad, top: content.top - offset + c.s(4))
        switch pane {
        case .sources:
            form.y = drawSourcesGuide(c, RECT(left: form.left, top: form.y, right: form.right, bottom: form.y), icons: false)
        case .playout: playoutPane(form)
        case .send: sendPane(form)
        case .foldDown: foldDownPane(form)
        case .discovery: discoveryPane(form)
        case .output: outputPane(form)
        case .inserts: insertsPane(form)
        case .loudness: loudnessPane(form)
        case .theme: themePane(form)
        case .view: viewPane(form)
        case .log: logPane(form)
        case .credits: creditsPane(form)
        }
        endScroll(key, content: form.y - (content.top - offset) + c.s(12), c)
    }

    private func choosePane(_ pane: SettingsPane) {
        commitField()
        view.settingsPane = pane
    }

    // The panes' small controls are `Form`'s; these keep the panes' calls short.
    private func bufferSlider(_ form: Form, _ label: String, value: Double, range: ClosedRange<Double>, step: Double, def: Double,
                              tip: String? = nil, set: @escaping (Double) -> Void) {
        form.slider(label, value: value, range: range, step: step, def: def, unit: "ms", tip: tip, set: set)
    }
    private func popupRow(_ form: Form, _ label: String, value: String, width: Double = 200, tip: String? = nil, dimmed: Bool = false,
                          entries: @escaping () -> [MenuEntry]) {
        form.popupRow(label, value: value, width: width, tip: tip, dimmed: dimmed, entries: entries)
    }
    private func segmentedRow(_ form: Form, _ label: String, options: [String], selected: Int, tip: String? = nil, enabled: Bool = true,
                              choose: @escaping (Int) -> Void) {
        form.segmented(label, options: options, selected: selected, tip: tip, enabled: enabled, choose: choose)
    }
    private func fieldRow(_ form: Form, _ label: String, key: String, value: String, placeholder: String = "", width: Double = 220,
                          tip: String? = nil, trailing: String? = nil, commit: @escaping (String) -> Void) {
        form.field(label, key: key, value: value, placeholder: placeholder, width: width, tip: tip, trailing: trailing, commit: commit)
    }

    // MARK: - Playout

    private func playoutPane(_ f: Form) {
        let c = f.c
        bufferSlider(f, "Buffer, PTP streams", value: grabber.latencyMs, range: 5...80, step: 1, def: GrabberEngine.defaultLatencyMs) {
            [unowned self] v in self.grabber.latencyMs = v
        }
        f.note("AES67, RAVENNA and Dante in AES67 mode — streams that follow a PTP clock.")
        bufferSlider(f, "Buffer, streams without PTP", value: grabber.vbanLatencyMs, range: 5...80, step: 1, def: GrabberEngine.defaultVBANLatencyMs,
                     tip: tooltip("The buffer for streams with no shared clock: VBAN, Scream, and RTP from senders such as PipeWire, VLC or "
                                  + "GStreamer that name no PTP clock. They usually arrive over Wi-Fi or a VPN, where packets bunch up more than "
                                  + "on a wired network. 20 ms was clean over Wi-Fi in testing; below about 16 ms, underruns start.",
                                  now: "\(Int(grabber.vbanLatencyMs)) ms")) { [unowned self] v in self.grabber.vbanLatencyMs = v }
        f.note("VBAN (Network Audio Sender, Voicemeeter), Scream, and RTP without PTP (PipeWire, VLC, GStreamer).")
        bufferSlider(f, "Buffer, streams from another location", value: grabber.remoteLatencyMs, range: GrabberEngine.remoteBufferRange, step: 5,
                     def: GrabberEngine.defaultRemoteLatencyMs,
                     tip: tooltip("Streams marked REMOTE or VPN cross the internet, where packets arrive far less evenly than on a local network, "
                                  + "so they get a larger buffer of their own. Test the connection suggests one, and changes nothing unless you press Use.",
                                  now: "\(Int(grabber.remoteLatencyMs)) ms")) { [unowned self] v in self.grabber.remoteLatencyMs = v }
        f.note("Streams marked REMOTE or VPN (across the internet). 60 ms to start.")
        connectionTestRows(f)
        let frames = grabber.outputBufferFrames
        f.labeled("Device buffer") { r in
            let ms = Double(frames) / max(1, self.grabber.outputRate) * 1000
            c.text(frames > 0 ? "\(frames) frames · \(String(format: "%.1f", ms)) ms, set by Windows" : "—", r, c.font(12), c.p.secondary, align: .right)
        }
        f.section(footer: "Each buffer is a **total**, and the output device's own buffer is spent first. In shared mode the device's period "
                  + "is Windows' to choose, so it is shown here rather than set.")

        f.toggle("Stop streams that go quiet", on: grabber.autoStopStreams) { [unowned self] in self.grabber.autoStopStreams.toggle() }
        popupRow(f, "After", value: GrabberEngine.minutesText(grabber.autoStopStreamsMinutes), width: 120, dimmed: !grabber.autoStopStreams) {
            [unowned self] in GrabberEngine.autoStopChoices.map { m in
                .item(GrabberEngine.minutesText(m), checked: m == self.grabber.autoStopStreamsMinutes) { [unowned self] in
                    self.grabber.autoStopStreamsMinutes = m
                }
            }
        }
        f.section("Auto-stop", footer: "Off, a stream you play stays joined until you stop it, however long it is quiet, and plays again the moment "
                  + "it returns; streams playing when the app quits are joined again when it opens and they are found. On, each playing stream is "
                  + "stopped once it has had no audio for the time chosen — its row then says Timed out. Sending has its own, under Send.")

        let budget = grabber.latencyBudget
        let bh = c.wrappedHeight(budget, width: f.inner, c.font(9)) + c.s(10)
        f.custom(max(c.s(52), bh)) { r in c.wrapped(budget, RECT(left: r.left, top: r.top + c.s(4), right: r.right, bottom: r.bottom), c.font(9), c.p.muted) }
        f.section("Budget")
        f.explainer("How to tune the buffer",
                    "Lower the buffer until underruns start moving and back off a notch. **Arrival jitter** is the honest guide: the buffer has "
                    + "to cover the worst figure, and if that is large the cause is upstream — the sender's packet pacing or the switch — not this PC.")
    }

    private func connectionTestRows(_ f: Form) {
        let c = f.c
        let remote = grabber.playingRemoteStreams
        let test = grabber.connectionTest
        f.custom(c.s(32)) { [unowned self] r in
            var running: String?
            if case .running(let name, _) = test { running = name }
            let title = running != nil ? "Testing…" : "Test the connection"
            let w = c.buttonWidth(title)
            let b = RECT(x: r.left, y: r.top + c.s(6), width: w, height: c.s(20))
            let enabled = !remote.isEmpty && running == nil
            c.button(title, b, hover: self.isHover("conntest"), enabled: enabled)
            self.hit(b, "conntest") { [unowned self] _ in if enabled, let id = remote.first?.id { self.grabber.testConnection(id) } }
            if remote.isEmpty {
                c.text("Play a stream marked REMOTE or VPN to test it.", RECT(left: b.right + c.s(10), top: r.top, right: r.right, bottom: r.bottom),
                       c.font(11), c.p.muted)
            }
        }
        switch test {
        case .running(let name, let until):
            f.note("Listening to “\(name)” — \(max(0, Int(until.timeIntervalSinceNow))) s left. Nothing changes while it runs.")
        case .done(let r):
            f.note(String(format: "“%@”: packets arrived within %.0f ms of even (worst %.0f ms)", r.streamName, r.spreadMs, r.worstMs)
                   + (r.lostPercent >= 0.1 ? String(format: ", %.1f %% lost", r.lostPercent) : ", none lost") + ".", colour: c.p.text)
            f.custom(c.s(30)) { [unowned self] rr in
                let tf = c.font(11, .semibold)
                let label = "Suggested: \(Int(r.suggestedMs)) ms"
                c.text(label, RECT(left: rr.left, top: rr.top, right: rr.left + c.width(label, tf) + 2, bottom: rr.bottom), tf, c.p.text)
                var x = rr.left + c.width(label, tf) + c.s(10)
                let use = "Use \(Int(r.suggestedMs)) ms"
                let uw = c.buttonWidth(use)
                let ub = RECT(x: x, y: rr.top + c.s(5), width: uw, height: c.s(20))
                let can = Int(self.grabber.remoteLatencyMs) != Int(r.suggestedMs)
                c.button(use, ub, hover: self.isHover("ctuse"), enabled: can)
                self.hit(ub, "ctuse") { [unowned self] _ in if can { self.grabber.useSuggestedBuffer() } }
                x = ub.right + c.s(6)
                let dw = c.buttonWidth("Dismiss")
                let db = RECT(x: x, y: ub.top, width: dw, height: c.s(20))
                c.button("Dismiss", db, hover: self.isHover("ctdismiss"))
                self.hit(db, "ctdismiss") { [unowned self] _ in self.grabber.clearConnectionTest() }
            }
            if r.lostPercent >= 1 {
                f.note("Packets are being lost, which no buffer can fix: the connection itself is the limit.", colour: c.p.warning)
            }
        case .failed(let why):
            f.note(why, colour: c.p.warning)
        case .idle:
            f.note("Listens to a remote stream for 30 s and suggests a buffer — the spread of arrival times plus a margin. It changes nothing: "
                   + "press Use to take the suggestion, or set the slider yourself.")
        }
    }

    // MARK: - Send

    private func sendPane(_ f: Form) {
        guard let sendUI else {
            f.note("Send is not available here.")
            f.section()
            return
        }
        sendUI.settings(f)
    }

    // MARK: - Fold-down

    private func foldDownPane(_ f: Form) {
        popupRow(f, "Channel order", value: grabber.channelOrder.menuLabel(channels: 6), width: 260) { [unowned self] in
            ChannelOrder.allCases.map { o in
                .item(o.menuLabel(channels: 6), checked: o == self.grabber.channelOrder) { [unowned self] in self.grabber.channelOrder = o }
            }
        }
        let trims: [Double] = [0, -3, -6]
        segmentedRow(f, "Downmix trim", options: ["0 dB", "−3 dB", "−6 dB"], selected: trims.firstIndex(of: grabber.downmixTrimDB) ?? 0) {
            [unowned self] i in self.grabber.downmixTrimDB = trims[i]
        }
        f.toggle("Include LFE in the fold-down (−10 dB)", on: grabber.includeLFE) { [unowned self] in self.grabber.includeLFE.toggle() }
        f.toggle("Fold quad, 5.1 and 7.1 streams down automatically", on: grabber.autoFoldSurround) { [unowned self] in
            self.grabber.autoFoldSurround.toggle()
        }
        f.section(footer: "On by default, because monitoring on headphones usually means wanting the whole bed. Each stream then remembers what "
                  + "you last set it to, so a discrete multichannel feed only needs putting back on Ch 1/2 once — from its own menu in the list.")
        f.explainer("Channel order is assumed, not detected",
                    "**SMPTE** reads 5.1 as L R C LFE Ls Rs and 7.1 as L R C LFE Lss Rss Lrs Rrs. **ITU/DTS** puts the surrounds before the centre "
                    + "and LFE: L R Ls Rs C LFE. AES67 and Dante carry no channel-order metadata at all, so this is an assumption either way — which "
                    + "is why it is a setting rather than a fact.\n\nThis is the default for every stream. A single stream can be set differently from "
                    + "its own menu in the list, because the order belongs to the sender.")
    }

    // MARK: - Discovery

    private func discoveryPane(_ f: Form) {
        let c = f.c
        f.toggle("SAP announcements", on: grabber.sapEnabled) { [unowned self] in self.grabber.sapEnabled.toggle() }
        f.toggle("RAVENNA (Bonjour + RTSP)", on: grabber.ravennaEnabled,
                 tip: "Browses for RAVENNA sessions with Windows' own Bonjour, and asks each for its description.") { [unowned self] in
            self.grabber.ravennaEnabled.toggle()
        }
        f.toggle("Dante devices (AES67 mode)", on: grabber.danteEnabled,
                 tip: "Browses for Dante devices with Windows' own Bonjour, to label their AES67 streams as Dante.") { [unowned self] in
            self.grabber.danteEnabled.toggle()
        }
        f.toggle("VBAN (UDP \(VBAN.port))", on: grabber.vbanEnabled) { [unowned self] in self.grabber.vbanEnabled.toggle() }
        f.toggle("Scream (UDP 4010)", on: grabber.screamEnabled, beta: true,
                 tip: "Scream is a free virtual sound card for Windows that sends the PC's audio over the network. Each PC sending it appears in the list by itself.") {
            [unowned self] in self.grabber.screamEnabled.toggle()
        }
        f.toggle("RTP without PTP", on: grabber.plainRTPEnabled, beta: true,
                 tip: "RTP streams that follow no PTP clock — PipeWire, PulseAudio, VLC, GStreamer — announced over SAP or pasted as SDP.") {
            [unowned self] in self.grabber.plainRTPEnabled.toggle()
        }
        f.toggle("Keep streams added from SDP", on: grabber.keepManualStreams,
                 tip: "A stream you pasted the SDP of is never announced, so once stopped it leaves the list after two quiet minutes. On: it stays "
                    + "until you remove it (right-click → Remove from the list). Not kept after the app quits.") { [unowned self] in
            self.grabber.keepManualStreams.toggle()
        }
        if !grabber.ignoredStreams.isEmpty {
            f.labeled("Ignored streams") { [unowned self] r in
                let w = c.buttonWidth("Show all again")
                let b = RECT(x: r.right - w, y: r.top + c.s(6), width: w, height: c.s(20))
                c.button("Show all again", b, hover: self.isHover("unignoreall"))
                self.hit(b, "unignoreall") { [unowned self] _ in self.grabber.ignoredStreams = [] }
                c.text("\(self.grabber.ignoredStreams.count) remembered", RECT(left: r.left, top: r.top, right: b.left - c.s(8), bottom: r.bottom),
                       c.font(12), c.p.muted, align: .right)
            }
        }
        f.note("Internet radio plays in the Mac Grabber; it is not in this Windows beta yet.")
        f.section()

        if grabber.vbanEnabled {
            // Send VBAN to this PC.
            if let error = grabber.vbanError { f.note(error, colour: c.p.warning) }
            let addresses = grabber.vbanAddresses
            if addresses.isEmpty { f.note("This PC has no network address right now.") }
            func copyRow(_ value: String, _ label: String) {
                f.custom(c.s(28)) { [unowned self] r in
                    let mono = c.font(12)
                    c.text(value, RECT(left: r.left, top: r.top, right: r.left + c.width(value, mono) + 2, bottom: r.bottom), mono, c.p.text)
                    c.text(label, RECT(left: r.left + c.width(value, mono) + c.s(10), top: r.top, right: r.right - c.s(30), bottom: r.bottom),
                           c.font(10), c.p.muted)
                    let b = RECT(x: r.right - c.s(20), y: r.top + c.s(4), width: c.s(20), height: c.s(20))
                    let copied = self.copiedValue == value
                    c.icon(copied ? "\u{E73E}" : "\u{E8C8}", b, size: 10, self.isHover("copy-\(value)") ? c.p.text : c.p.muted)
                    self.hit(b, "copy-\(value)", tip: "Copy to the clipboard.") { [unowned self] _ in
                        self.copyToClipboard(value); self.copiedValue = value
                    }
                }
            }
            for a in addresses {
                copyRow(a.address, "\(a.kind == .wifi ? "Wi-Fi" : (a.kind == .vpn ? "VPN" : "Wired")) · \(a.name)")
                if let b = a.broadcast { copyRow(b, "Broadcast · \(a.name)") }
            }
            copyRow(String(VBAN.port), "Port")
            f.section("Send VBAN to this PC", footer: "In the sender — in Voicemeeter, an outgoing stream in its VBAN window — set the IP address to "
                      + "the one on the same network as the sender, and the port to \(VBAN.port). A broadcast address reaches every receiver on that "
                      + "network at once, but also sends the audio to every device on it, so prefer the PC's own address where one receiver will do.")

            // Network Audio Sender.
            fieldRow(f, "This Grabber's name", key: "grabbername", value: grabber.vbanReceiverName,
                     placeholder: GrabberEngine.receiverName(""), width: 220,
                     tip: tooltip("What a Network Audio Sender shows against this Grabber while it listens. Up to 16 plain characters; blank uses this PC's name.",
                                  now: GrabberEngine.receiverName(grabber.vbanReceiverName))) { [unowned self] text in
                self.grabber.vbanReceiverName = text.trimmingCharacters(in: .whitespaces)
            }
            fieldRow(f, "Add a Sender by address", key: "senderaddress", value: senderDraft, placeholder: "192.0.2.20", width: 180,
                     trailing: nil) { [unowned self] text in
                self.senderDraft = text
                let typed = text.trimmingCharacters(in: .whitespaces)
                guard !typed.isEmpty else { return }
                self.senderAddError = self.grabber.addManualSender(typed)
                if self.senderAddError == nil { self.senderDraft = "" }
            }
            if let error = senderAddError { f.note(error, colour: c.p.warning) }
            if RemoteAddresses.isRemote(RemoteAddresses.host(senderDraft)) {
                f.note("Outside this PC's networks. " + RemoteAddresses.warning(receivingEnd: false), colour: c.p.warning)
            }
            for key in grabber.vbanManualSenders {
                let sending = grabber.vbanSenderStates[key] ?? false
                f.custom(c.s(28)) { [unowned self] r in
                    c.ellipse(RECT(x: r.left, y: (r.top + r.bottom) / 2 - c.s(3), width: c.s(6), height: c.s(6)), sending ? c.p.green : c.p.secondary)
                    c.text(key, RECT(left: r.left + c.s(14), top: r.top, right: r.left + c.s(170), bottom: r.bottom), c.font(12), c.p.text)
                    c.text(sending ? "sending here" : "waiting for it to answer", RECT(left: r.left + c.s(170), top: r.top, right: r.right - c.s(30), bottom: r.bottom),
                           c.font(10), c.p.muted)
                    let b = RECT(x: r.right - c.s(20), y: r.top + c.s(4), width: c.s(20), height: c.s(20))
                    c.icon("\u{E711}", b, size: 9, self.isHover("rmsender-\(key)") ? c.p.text : c.p.muted)
                    self.hit(b, "rmsender-\(key)", tip: "Stop asking \(key) for its stream, and remove it.") { [unowned self] _ in
                        self.grabber.removeManualSender(key)
                    }
                }
            }
            f.section("Network Audio Sender", footer: "A Network Audio Sender that offers its stream appears in the list by itself: press play and it "
                      + "sends to this PC only. Add one by address where its offer cannot reach, such as over a VPN; its port is "
                      + "\(VBANControl.controlPort) unless you add another. An added Sender sends here for as long as it is in this list.")
        }

        if !grabber.danteDevices.isEmpty {
            for device in grabber.danteDevices {
                let publishing = grabber.danteIsPublishing(device)
                f.custom(c.s(26)) { r in
                    c.ellipse(RECT(x: r.left, y: (r.top + r.bottom) / 2 - c.s(2.5), width: c.s(5), height: c.s(5)),
                              publishing ? c.p.tint(for: .dante) : c.p.secondary)
                    let nf = c.font(11)
                    c.text(device.name, RECT(left: r.left + c.s(12), top: r.top, right: r.left + c.s(12) + c.width(device.name, nf) + 2, bottom: r.bottom), nf, c.p.text)
                    if let a = device.address {
                        c.text(a, RECT(left: r.left + c.s(20) + c.width(device.name, nf), top: r.top, right: r.right - c.s(70), bottom: r.bottom), c.font(9), c.p.muted)
                    }
                    let chip = publishing ? "AES67" : "no flow"
                    let cw = c.width(chip, c.font(9, .semibold)) + c.s(10)
                    _ = c.chip(chip, x: r.right - cw, centreY: (r.top + r.bottom) / 2, tint: publishing ? c.p.tint(for: .dante) : c.p.secondary)
                }
            }
            f.section("Dante devices", footer: "\"no flow\" means the device is reachable but publishing no AES67 stream this app can receive.")
        }
        f.explainer("Why a Dante device can appear and still send nothing",
                    "Dante audio reaches this app only when a device is in **AES67 mode** and someone has created an AES67 multicast flow for it "
                    + "in Dante Controller. **Dante Virtual Soundcard and Dante Via cannot do AES67 at all** — route them through a hardware Dante "
                    + "device, or use a RAVENNA driver instead.")
        f.explainer("What turning VBAN on opens up",
                    "VBAN (Voicemeeter, VBAN apps on phones) has **no authentication**. On, the app listens on UDP 6980 on **every** interface, "
                    + "VPNs included, and lists any VBAN stream sent to this PC. Nothing is decoded until you join a stream; at most 32 are listed, "
                    + "8 from any one sender, and 4 new ones a second admitted, so a flood of made-up streams cannot swamp the list. A stream "
                    + "appears while its packets arrive and leaves 15 s after they stop.")
    }

    // MARK: - Output

    private func outputPane(_ f: Form) {
        let c = f.c
        let chosen = grabber.wasapi.chosenDeviceID
        let deviceTitle = chosen == nil ? "System default — \(WASAPIOutput.defaultDeviceName() ?? "none")" : grabber.wasapi.chosenDeviceName
        popupRow(f, "Device", value: deviceTitle, width: 300) { [unowned self] in
            var entries: [MenuEntry] = [.item("System default — \(WASAPIOutput.defaultDeviceName() ?? "none")", checked: chosen == nil) {
                [unowned self] in self.grabber.chooseOutputDevice(nil)
            }, .separator]
            for d in WASAPIOutput.renderDevices() {
                entries.append(.item("\(d.name)  (\(d.channels) ch)", checked: d.id == chosen) { [unowned self] in self.grabber.chooseOutputDevice(d) })
            }
            return entries
        }
        if grabber.wasapi.usingFallback {
            f.note("\(grabber.wasapi.chosenDeviceName) isn't connected. Playing on the system default (\(grabber.outputDeviceName)) until it's back.",
                   colour: c.p.warning)
        }
        popupRow(f, "Output bus", value: grabber.busWidthLabel(grabber.busChannels), width: 200, tip: busWidthHelp()) { [unowned self] in
            self.grabber.busWidthOptions.map { w in
                .item(self.grabber.busWidthLabel(w), checked: w == self.grabber.busChannels) { [unowned self] in self.grabber.setBusWidth(w) }
            }
        }
        f.labeled("Sample rate") { [unowned self] r in
            c.text(String(format: "%.4g kHz · %d ch, set in Windows", self.grabber.outputRate / 1000, self.grabber.wasapi.mixChannels), r,
                   c.font(12), self.grabber.outputRate == 48000 ? c.p.secondary : c.p.warning, align: .right)
        }
        f.custom(c.s(32)) { [unowned self] r in
            let w = c.buttonWidth("Open Windows' Sound settings")
            let b = RECT(x: r.right - w, y: r.top + c.s(6), width: w, height: c.s(20))
            c.button("Open Windows' Sound settings", b, hover: self.isHover("soundsettings"))
            self.hit(b, "soundsettings") { [unowned self] _ in self.shellOpen("ms-settings:sound") }
        }
        f.section(footer: "**System default** follows whatever Windows plays through. A named device stays chosen however Windows' own setting "
                  + "changes. The output bus is how many channels the app plays out of; streams that fit go out channel for channel, wider ones "
                  + "fold to stereo. With Windows Sonic or Dolby Atmos for Headphones on, choose 7.1: a surround stream is then placed around your "
                  + "head. The rate is the device's shared-mode rate, set in Windows' Sound settings"
                  + (grabber.outputRate != 48000 ? ". AES67 is 48 kHz throughout, so at this rate a sample-rate conversion sits in the path." : "."))
        f.toggle("Headphone safety limiter", on: grabber.safetyLimiter, tip: "A peak limiter on the end of the chain, to catch a hot stream") {
            [unowned self] in self.grabber.safetyLimiter.toggle()
        }
        f.section(footer: "A peak limiter, last in the chain. It is there to catch a stream that arrives far hotter than expected, not to be mixed into.")
    }

    // MARK: - Inserts

    private func insertsPane(_ f: Form) {
        let c = f.c
        f.labeled("Plug-ins found") { [unowned self] r in
            c.text(self.inserts.scanning ? "Looking…" : "\(self.inserts.available.count) VST3 effects", r, c.font(12), c.p.secondary, align: .right)
        }
        f.custom(c.s(32)) { [unowned self] r in
            let w = c.buttonWidth("Look for plug-ins again")
            let b = RECT(x: r.right - w, y: r.top + c.s(6), width: w, height: c.s(20))
            c.button("Look for plug-ins again", b, hover: self.isHover("rescan"), enabled: !self.inserts.scanning)
            self.hit(b, "rescan") { [unowned self] _ in self.inserts.rescan() }
        }
        f.toggle("Show dry/wet on inserts", on: view.showInsertMix) { [unowned self] in self.view.showInsertMix.toggle() }
        f.section(footer: "VST3 effects from **C:\\Program Files\\Common Files\\VST3**, where installers put them. Each plug-in is looked at in a "
                  + "separate process, so one that crashes while being looked at cannot take the Grabber with it. Three slots, after the loudness "
                  + "measurement and before the monitor level, as on the Mac.")
        f.explainer("Bypass, Δ and dry/wet",
                    "**BYP** takes a plug-in out of circuit entirely — the only path with no insert latency in it. **Δ** plays only what the "
                    + "plug-in changed: wet minus dry, with the dry path delayed to match its reported latency, so silence means it is doing nothing. "
                    + "**Dry/wet** is ours rather than the plug-in's, so it works for every plug-in, and the dry path is delayed to match at every blend.")
    }

    // MARK: - Loudness

    private func loudnessPane(_ f: Form) {
        let c = f.c
        f.toggle("Show loudness readings", on: grabber.showLoudness) { [unowned self] in self.grabber.showLoudness.toggle() }
        popupRow(f, "Pinned loudness", value: view.pinnedLoudness.label, width: 200, dimmed: !grabber.showLoudness) { [unowned self] in
            LoudnessPin.allCases.map { pin in .item(pin.label, checked: pin == self.view.pinnedLoudness) { [unowned self] in self.view.pinnedLoudness = pin } }
        }
        fieldRow(f, "Window", key: "lufswindow", value: "\(grabber.lufsWindowSeconds)", width: 56, trailing: "seconds") { [unowned self] text in
            if let v = Int(text.trimmingCharacters(in: .whitespaces)) { self.grabber.lufsWindowSeconds = v }
        }
        f.section()
        f.labeled("Targets") { [unowned self] r in
            var x = r.right - c.width("LUFS", c.font(11))
            c.text("LUFS", RECT(left: x, top: r.top, right: r.right, bottom: r.bottom), c.font(11), c.p.muted)
            x -= c.s(8)
            for (label, key, value, set) in [("I", "ti", self.grabber.targetIntegrated, { (v: Double) in self.grabber.targetIntegrated = v }),
                                             ("W", "tw", self.grabber.targetWindow, { (v: Double) in self.grabber.targetWindow = v }),
                                             ("S", "ts", self.grabber.targetShortTerm, { (v: Double) in self.grabber.targetShortTerm = v })] {
                let box = RECT(x: x - c.s(48), y: r.top + c.s(5), width: c.s(48), height: r.height - c.s(10))
                self.fieldFrames[key] = box
                let text = value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
                c.field(self.fieldKey == key ? "" : text, box, hover: self.isHover("field-\(key)"))
                self.hit(box, "field-\(key)") { [unowned self] _ in
                    self.beginField(key, frame: box, text: text) { t in
                        if let v = Double(t.replacingOccurrences(of: "−", with: "-").trimmingCharacters(in: .whitespaces)) { set(v) }
                    }
                }
                c.text(label, RECT(left: box.left - c.s(12), top: r.top, right: box.left - c.s(3), bottom: r.bottom), c.font(9, .bold), c.p.muted, align: .right)
                x = box.left - c.s(18)
            }
        }
        f.labeled("Presets") { [unowned self] r in
            var x = r.right
            for (title, lufs) in [("−14 (streaming)", -14.0), ("−23 (R 128)", -23.0)] {
                let w = c.buttonWidth(title, size: 11)
                let b = RECT(x: x - w, y: r.top + c.s(6), width: w, height: c.s(20))
                c.button(title, b, hover: self.isHover("preset-\(lufs)"))
                self.hit(b, "preset-\(lufs)") { [unowned self] _ in self.grabber.setLoudnessTargets(lufs) }
                x = b.left - c.s(6)
            }
        }
        f.section(footer: "**S** short-term, **W** the window, **I** integrated.")
        f.explainer("What the three readings measure",
                    "Short-term (S) is a fixed 3-second window. It moves with the material, so it is the one to mix against.\n\nWindow (W) is the "
                    + "span set above — a minute by default — gated the way integrated is.\n\nIntegrated (I) runs from the last reset until you reset "
                    + "it again (Ctrl+Shift+L). It is the figure a delivery specification means.\n\nAll three are measured on the summed bus ahead of "
                    + "master level, DIM and MONO, so the monitor controls cannot move a reading.\n\nPinned loudness is the reading you judge by, made "
                    + "readable across a room: it leads the readings beside the output meters, larger than the others, and sits beside the peak in "
                    + "the compact window.")
    }

    // MARK: - Theme

    private func themePane(_ f: Form) {
        let c = f.c
        let forced = view.skin.style.dark
        segmentedRow(f, "Appearance", options: Appearance.allCases.map(\.label),
                     selected: Appearance.allCases.firstIndex(of: view.appearance) ?? 2,
                     tip: forced == nil ? "Light, dark, or follow Windows." : "This colour scheme has its own look, so it sets the appearance.",
                     enabled: forced == nil) {
            [unowned self] i in self.view.appearance = Appearance.allCases[i]; self.restyle()
        }
        if let forced { f.note("Set by the colour scheme: always \(forced ? "dark" : "light").") }
        let selection = !view.themeEnabled ? "System colour scheme" : (view.preset?.name ?? "Custom")
        popupRow(f, "Colour scheme", value: selection, width: 240,
                 tip: tooltip("Tints the window and marks what is switched on, in two colours. System colour scheme leaves Windows' own colours alone.",
                              now: selection)) { [unowned self] in
            var entries: [MenuEntry] = [.item("System colour scheme", checked: !self.view.themeEnabled) { [unowned self] in
                self.view.themeEnabled = false; self.restyle()
            }, .separator]
            for p in ThemePreset.all { entries.append(self.schemeItem(p)) }
            entries.append(.separator)
            for p in ThemePreset.looks { entries.append(self.schemeItem(p)) }
            entries.append(.separator)
            entries.append(.item("Custom", checked: self.view.themeEnabled && self.view.preset == nil) { [unowned self] in
                self.view.themeEnabled = true; self.restyle()
            })
            return entries
        }
        if let forced {
            f.note("This scheme has its own look — meters, faders and buttons — and is always \(forced ? "dark" : "light"), so Appearance is set by it.")
        }
        f.labeled("Colours") { [unowned self] r in
            var x = r.left + c.s(40)
            for (label, hex, isPrimary) in [("Window", self.view.themePrimaryHex, true), ("Active", self.view.themeSecondaryHex, false)] {
                let well = RECT(x: x, y: r.top + c.s(6), width: c.s(36), height: r.height - c.s(12))
                let colour = Colour(hex: hex) ?? .black
                c.round(well, 5, colour, alpha: self.view.themeEnabled ? 1 : 0.45, border: c.p.label, borderAlpha: 0.25)
                c.text(label, RECT(left: well.right + c.s(6), top: r.top, right: well.right + c.s(70), bottom: r.bottom), c.font(11), c.p.muted)
                self.hit(well, "well-\(label)", tip: "Choose the \(label.lowercased()) colour. Editing a colour makes a custom scheme.") { [unowned self] _ in
                    if let picked = self.chooseColour(colour) {
                        if isPrimary { self.view.themePrimaryHex = picked.hexString } else { self.view.themeSecondaryHex = picked.hexString }
                        self.view.themeEnabled = true
                        self.restyle()
                    }
                }
                x = well.right + c.s(90)
            }
        }
        f.section()
        f.explainer("What the two colours reach, and what stays fixed",
                    "**Window** washes every surface, so the list, the toolbar and the signal panel take the hue — the panel still sits a shade apart. "
                    + "**Active** is anything you have switched on: a stream you are listening to, its stop button, ACTIVE, the panel toggle, MONO and "
                    + "the sliders.\n\nLeft alone on purpose: meter green/amber/red (the colour *is* the level), the RAVENNA/Dante/SAP tints (they "
                    + "identify the transport), solo yellow and mute red.")
    }

    private func schemeItem(_ p: ThemePreset) -> MenuEntry {
        .item(p.name, checked: view.themeEnabled && view.preset?.name == p.name) { [unowned self] in
            self.view.themePrimaryHex = p.primary
            self.view.themeSecondaryHex = p.secondary
            self.view.themeEnabled = true
            self.restyle()
        }
    }

    // MARK: - View

    private func viewPane(_ f: Form) {
        segmentedRow(f, "Window", options: ViewMode.allCases.map(\.label), selected: ViewMode.allCases.firstIndex(of: view.viewMode) ?? 0) {
            [unowned self] i in self.switchMode(ViewMode.allCases[i])
        }
        segmentedRow(f, "Stream list", options: DetailLevel.allCases.map(\.label),
                     selected: DetailLevel.allCases.firstIndex(of: grabber.detailLevel) ?? 0) { [unowned self] i in
            self.grabber.detailLevel = DetailLevel.allCases[i]
        }
        f.toggle("Show dry/wet on inserts", on: view.showInsertMix) { [unowned self] in self.view.showInsertMix.toggle() }
        segmentedRow(f, "Stream filter", options: ["Sidebar", "Row above the list"], selected: view.sourceFilterRow ? 1 : 0,
                     tip: "Where the full window's stream filter sits: a sidebar on the left, or a row above the list, which leaves the window narrower.") {
            [unowned self] i in self.view.sourceFilterRow = i == 1
        }
        f.toggle("Show level history", on: view.showLevelHistory,
                 tip: "The last 30 seconds of the output under the meters. A red mark is a moment when a stream's audio stopped arriving or its "
                    + "buffer ran out.") { [unowned self] in self.view.showLevelHistory.toggle() }
        f.section(footer: "Simple is name, source, channels, where it goes, its level and its trim. Detailed adds the arrival figures the receiver "
                  + "already keeps — jitter, buffer, drift, lost packets, underruns — as a column in the list and a block under the stream you have "
                  + "open. Any slider returns to its default on a **double-click**.")
        let rates = [20, 30, 60]
        segmentedRow(f, "Meter refresh", options: rates.map { "\($0) fps" }, selected: rates.firstIndex(of: view.meterHz) ?? 1) { [unowned self] i in
            self.view.meterHz = rates[i]; self.meterRateChanged()
        }
        f.section(footer: "The window redraws at this rate while anything moves; 30 is plenty to read a meter by.")
    }

    // MARK: - Log

    private func logPane(_ f: Form) {
        let c = f.c
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        let entries = Array(grabber.activity.entries.reversed().prefix(400))
        if entries.isEmpty { f.note("Nothing has happened yet.") }
        for entry in entries {
            let h = c.wrappedHeight(entry.text, width: f.inner - c.s(130), c.font(11)) + c.s(8)
            f.custom(max(c.s(24), h)) { r in
                c.text(clock.string(from: entry.date), RECT(left: r.left, top: r.top + c.s(4), right: r.left + c.s(60), bottom: r.top + c.s(20)),
                       c.font(10), c.p.muted, top: true)
                let kindColour = entry.kind == .failed ? c.p.red : (entry.kind == .warning ? c.p.warning : c.p.muted)
                c.text(entry.kind.label, RECT(left: r.left + c.s(62), top: r.top + c.s(4), right: r.left + c.s(124), bottom: r.top + c.s(20)),
                       c.font(10, .semibold), kindColour, top: true)
                c.wrapped(entry.text, RECT(left: r.left + c.s(128), top: r.top + c.s(4), right: r.right, bottom: r.bottom), c.font(11), c.p.text)
            }
        }
        f.section(footer: "Newest first. Kept between runs in %LOCALAPPDATA%\\Network Audio Grabber.")
    }

    // MARK: - Credits

    private func creditsPane(_ f: Form) {
        let c = f.c
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
        item("Network Audio Grabber \(WindowsGrabber.version) for Windows", "A beta. The same engine as the Mac Grabber, so a stream from a Mac and "
             + "a stream from a PC are the same stream.")
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
        f.section()
        item("AES67", "The AES standard for audio over IP, with RTP (RFC 3550, 3551), SDP (RFC 4566) and SAP (RFC 2974) from the IETF")
        item("RAVENNA", "ALC NetworX")
        item("Dante, in its AES67 mode", "Audinate")
        item("VBAN", "VB-Audio Software, from its published specification")
        item("Scream", "The open-source Scream project, from its own description of the format")
        item("RTP without PTP", "PipeWire, PulseAudio, VLC, GStreamer")
        item("VST 3", "Steinberg Media Technologies")
        f.section("Works with")
        item("Swift and Foundation", "Apple Inc. and the Swift project · Apache License 2.0 with the Runtime Library Exception")
        item("ICU", "Unicode, Inc. · Unicode License V3")
        item("swift-crypto", "Apple Inc. · Apache License 2.0 · the Remote link's encryption, with BoringSSL (Apache 2.0) and XKCP (public domain)")
        item("VST 3 SDK", "Steinberg Media Technologies GmbH · MIT licence · hosting the inserts")
        item("Windows", "WASAPI, Bonjour (dnsapi), GDI and GDI+")
        f.section("Built with")
        item("", "Dante is a trademark of Audinate. RAVENNA is a trademark of ALC NetworX. VBAN and Voicemeeter are trademarks of VB-Audio Software. "
             + "VST is a trademark of Steinberg Media Technologies GmbH. Windows, Windows Sonic and Dolby Atmos belong to their owners, as do the "
             + "other names mentioned.")
        item("", "Not affiliated with, or endorsed by, any of them: names say only what the apps work with.")
        f.section("Trademarks", footer: "© 2026 DAT Audio · free software, MIT licence. The full licence texts are in the Licences folder beside the app.")
    }
}
