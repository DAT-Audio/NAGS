import Foundation
import WinSDK
import NetworkAudioEngine
import GrabberCore

/// The compact window (the Mac's `CompactView`): the monitor controls, the loudness readings and
/// whatever is playing, in a strip narrow enough to leave beside something else. A different
/// arrangement of the same state: every control drives what its twin in the full window drives.
extension GrabberWindow {
    func drawCompact(_ c: Canvas, _ client: RECT) {
        let header = RECT(left: 0, top: 0, right: client.right, bottom: c.s(34))
        drawToolbar(c, header, compact: true)
        c.hline(header.bottom, 0, client.right, c.p.divider)
        let footer = RECT(left: 0, top: client.bottom - c.s(32), right: client.right, bottom: client.bottom)
        c.hline(footer.top - 1, 0, client.right, c.p.divider)
        var top = header.bottom + 1
        if view.showSettings {
            drawSettings(c, RECT(left: 0, top: top, right: client.right, bottom: footer.top - 1), compact: true)
            drawCompactFooter(c, footer)
            return
        }
        // Receive / Send: a small segmented control, centred, as the Mac's.
        let tabsW = c.segmentedWidth(["Receive", "Send"], size: 11) + c.s(24)
        let tabs = RECT(left: (client.right - tabsW) / 2, top: top + c.s(6), right: (client.right + tabsW) / 2, bottom: top + c.s(26))
        let segs = c.segmented(["Receive", "Send"], tabs, selected: view.compactTab, size: 11)
        for (i, seg) in segs.enumerated() { hit(seg, "ctab-\(i)") { [unowned self] _ in self.view.compactTab = i } }
        top = tabs.bottom + c.s(5)
        let body = RECT(left: 0, top: top, right: client.right, bottom: footer.top - 1)
        if view.compactTab == 1 {
            drawSendTab(c, body, compact: true)
        } else {
            let offset = beginScroll("compact", body, c)
            var y = body.top - offset
            y = drawCompactMonitor(c, RECT(left: body.left, top: y, right: body.right, bottom: y))
            if grabber.showLoudness {
                c.hline(y, body.left, body.right, c.p.divider)
                y = drawCompactLoudness(c, RECT(left: body.left, top: y + 1, right: body.right, bottom: y))
            }
            c.hline(y, body.left, body.right, c.p.divider)
            y = drawInsertsSection(c, RECT(left: body.left, top: y + 1, right: body.right, bottom: y), compact: true)
            c.hline(y, body.left, body.right, c.p.divider)
            y = drawCompactStreams(c, RECT(left: body.left, top: y + 1, right: body.right, bottom: y))
            endScroll("compact", content: y - (body.top - offset), c)
        }
        drawCompactFooter(c, footer)
    }

    private func meterSlot(_ n: Int) -> Double { n > 2 ? min(11, max(4, 72 / Double(n))) : 11 }

    private func drawCompactMonitor(_ c: Canvas, _ r: RECT) -> Int32 {
        let pad = c.s(11)
        let left = r.left + pad, right = r.right - pad
        var y = r.top + c.s(12)
        // The peak figure, its label, the pinned reading and the clip dot.
        let ro = view.readouts
        let big = c.font(30, .light)
        let bh = c.s(36)
        let pw = c.width(ro.outputMax, big)
        c.text(ro.outputMax, RECT(left: left, top: y, right: left + pw + 2, bottom: y + bh), big, c.p.skin.figureText ?? c.p.text)
        c.text("dBFS max", RECT(left: left + pw + c.s(5), top: y + c.s(14), right: left + pw + c.s(70), bottom: y + bh - c.s(4)), c.font(10), c.p.muted)
        hit(RECT(left: left, top: y, right: left + pw + c.s(60), bottom: y + bh), "cpeak",
            tip: "Highest output level since it was last reset. Double-click to reset it and start logging a new maximum.",
            double: { [unowned self] in self.grabber.clearClip() })
        let dot = RECT(x: right - c.s(9), y: y + c.s(16), width: c.s(9), height: c.s(9))
        c.ellipse(dot, grabber.clipped ? c.p.red : c.p.label, alpha: grabber.clipped ? 1 : 0.12)
        hit(dot.inset(by: -c.s(4)), "cclip", tip: grabber.clipped ? "Clipped — click to reset the maximum and the clip indicator"
                                                                  : "Click to reset the maximum") { [unowned self] _ in self.grabber.clearClip() }
        if grabber.showLoudness, let reading = view.pinnedReading() {
            let badge = view.pinnedLoudness.badge
            let bf = c.font(10)
            let vw = c.width(reading.value, big)
            let bw = c.width(badge, bf)
            let x = dot.left - c.s(10) - bw - c.s(3) - vw
            c.text(reading.value, RECT(left: x, top: y, right: x + vw + 2, bottom: y + bh), big, reading.provisional ? c.p.secondary : c.p.text)
            c.text(badge, RECT(left: x + vw + c.s(3), top: y + c.s(14), right: x + vw + c.s(3) + bw + 2, bottom: y + bh - c.s(4)), bf, c.p.muted)
            if let delta = reading.delta {
                let pinnedTarget: Double
                switch view.pinnedLoudness {
                case .shortTerm: pinnedTarget = grabber.targetShortTerm
                case .window: pinnedTarget = grabber.targetWindow
                default: pinnedTarget = grabber.targetIntegrated
                }
                c.text("\(delta) against \(target(pinnedTarget))", RECT(left: x - c.s(40), top: y + bh, right: dot.left - c.s(10), bottom: y + bh + c.s(14)),
                       c.font(10), reading.colour(c.p), align: .right)
            }
            hit(RECT(left: x, top: y, right: dot.left - c.s(6), bottom: y + bh + c.s(14)), "cpinned",
                tip: tooltip("The loudness reading pinned beside the peak — chosen in Settings → Loudness. Double-click to reset the "
                             + "measurement. The full set is in the loudness section.", now: "\(view.pinnedLoudness.label): \(reading.value) LUFS"),
                double: { [unowned self] in self.grabber.resetLoudness() })
        }
        y += bh + c.s(16)

        // A horizontal bar per bus channel.
        let n = grabber.busChannels
        let slot = meterSlot(n)
        let barThick = max(2, slot - 4)
        let showLabels = n <= 2 || slot >= 7
        let labels = n <= 2 ? ["L", "R"] : grabber.busChannelLabels.map { $0.count <= 2 ? $0 : String($0.prefix(2)) }
        let barsLeft = showLabels ? left + c.s(19) : left
        for ch in 0..<n {
            let rowTop = y + c.s(slot * Double(ch))
            if showLabels, ch < labels.count {
                c.text(labels[ch], RECT(left: left, top: rowTop, right: left + c.s(13), bottom: rowTop + c.s(slot)),
                       c.font(slot >= 9 ? 8 : 7, .semibold), c.p.muted, align: .centre)
            }
            let bar = RECT(left: barsLeft, top: rowTop + (c.s(slot) - c.s(barThick)) / 2, right: right,
                           bottom: rowTop + (c.s(slot) - c.s(barThick)) / 2 + c.s(barThick))
            c.bar(bar, level: grabber.outputPeak(ch), vertical: false, hold: grabber.outputPeakHold)
        }
        y += c.s(slot * Double(n)) + c.s(11)
        if view.showLevelHistory {
            drawHistory(c, RECT(left: left, top: y, right: right, bottom: y + c.s(32)), height: 18)
            y += c.s(32) + c.s(11)
        }
        drawVolume(c, RECT(left: left, top: y, right: right, bottom: y + c.s(20)))
        y += c.s(20) + c.s(11)
        let pills = RECT(left: left, top: y, right: right, bottom: y + c.s(20))
        drawDimMono(c, pills)
        if grabber.busWidthOptions.count > 1 {
            let text = "\(grabber.busChannels) of \(grabber.wasapi.deviceChannels) ch"
            let bf = c.font(9, .medium)
            let w = c.width(text, bf) + c.s(14)
            let busRect = RECT(left: right - w, top: pills.top, right: right, bottom: pills.bottom)
            c.menuLabel(text, x: busRect.left, busRect, size: 9, colour: isHover("cbus") ? c.p.active : c.p.text, weight: .medium)
            hit(busRect, "cbus", tip: busWidthHelp()) { [unowned self] _ in self.busMenu(at: POINT(x: busRect.left, y: busRect.bottom)) }
        }
        y = pills.bottom + c.s(12)
        return y
    }

    private func drawCompactLoudness(_ c: Canvas, _ r: RECT) -> Int32 {
        let pad = c.s(11)
        let head = RECT(left: r.left + pad, top: r.top, right: r.right - pad, bottom: r.top + c.s(30))
        drawFoldHeading(c, head, "Loudness", open: view.loudnessOpen, key: "fold-loud") { [unowned self] in self.view.loudnessOpen.toggle() }
        let ro = view.readouts
        if !view.loudnessOpen {
            // As many of the three as fit, the pinned one last to go.
            let titleW = c.s(14) + c.width("Loudness", c.font(12, .semibold)) + c.s(8)
            let room = head.width - titleW
            let item = c.s(78), gap = c.s(9)
            var keys = ["S", "W", "I"]
            if room < item * 3 + gap * 2 {
                switch view.pinnedLoudness {
                case .shortTerm: keys = room >= item * 2 + gap ? ["W", "I"] : ["S"]
                case .window: keys = room >= item * 2 + gap ? ["S", "I"] : ["W"]
                case .integrated: keys = room >= item * 2 + gap ? ["S", "W"] : ["I"]
                case .none: keys = room >= item * 2 + gap ? ["S", "I"] : ["S"]
                }
            }
            var x = head.right
            for key in keys.reversed() {
                let reading = key == "S" ? ro.shortTerm : (key == "W" ? ro.window : ro.integrated)
                let cell = RECT(left: x - item, top: head.top, right: x, bottom: head.bottom)
                let delta = reading.delta ?? "—"
                let df = c.font(10), vf = c.font(12), kf = c.font(10, .semibold)
                let dw = c.width(delta, df), vw = c.width(reading.value, vf)
                c.text(delta, RECT(left: cell.right - dw, top: cell.top, right: cell.right, bottom: cell.bottom), df, reading.colour(c.p))
                c.text(reading.value, RECT(left: cell.right - dw - c.s(3) - vw, top: cell.top, right: cell.right - dw - c.s(3), bottom: cell.bottom), vf, c.p.text)
                c.text(key, RECT(left: cell.right - dw - vw - c.s(6) - c.width(key, kf), top: cell.top, right: cell.right - dw - vw - c.s(6), bottom: cell.bottom),
                       kf, c.p.muted)
                x = cell.left - gap
            }
            hit(RECT(left: head.left + titleW, top: head.top, right: head.right, bottom: head.bottom), "cloudsum",
                tip: "Short-term, windowed and integrated loudness against their targets. Double-click to reset the integrated and windowed readings.",
                double: { [unowned self] in self.grabber.resetLoudness() })
            return head.bottom
        }
        var y = head.bottom
        let left = r.left + pad, right = r.right - pad
        let info = "\(grabber.lufsWindowSeconds) s · target \(target(grabber.targetIntegrated))"
        let reset = RECT(x: right - c.s(12), y: y, width: c.s(12), height: c.s(16))
        c.icon("\u{E72C}", reset, size: 9, isHover("creset") ? c.p.text : c.p.muted)
        hit(reset, "creset", tip: "Reset the integrated and window readings (Ctrl+Shift+L)") { [unowned self] _ in self.grabber.resetLoudness() }
        c.text(info, RECT(left: left, top: y, right: reset.left - c.s(6), bottom: y + c.s(16)), c.font(10), c.p.muted, align: .right)
        y += c.s(22)
        for (label, reading, detail) in [
            ("Short-term", ro.shortTerm, "Short-term loudness — a fixed 3-second window, as BS.1770 defines it. This is the one that moves with the material."),
            ("Window \(grabber.lufsWindowSeconds) s", ro.window, "Windowed loudness — the last stretch of programme, gated the same way as integrated, with the length set in Settings → Loudness."),
            ("Integrated", ro.integrated, "Integrated loudness — everything since the last reset. Gated, and the figure a delivery specification means."),
        ] {
            let row = RECT(left: left, top: y, right: right, bottom: y + c.s(20))
            drawLoudnessRow(c, row, label, reading, detail: detail)
            y = row.bottom + c.s(4)
        }
        return y + c.s(6)
    }

    /// One loudness line (`LoudnessReadingRow`): the label, the figure, a deviation dot, the delta.
    func drawLoudnessRow(_ c: Canvas, _ r: RECT, _ label: String, _ reading: LoudnessReading, detail: String) {
        c.text(label, RECT(left: r.left, top: r.top, right: r.left + c.s(80), bottom: r.bottom), c.font(11), c.p.text)
        c.text(reading.value, RECT(left: r.left + c.s(80), top: r.top, right: r.left + c.s(126), bottom: r.bottom), c.font(14, .medium),
               reading.provisional || reading.delta == nil ? c.p.secondary : c.p.text, align: .right)
        let deltaRect = RECT(left: r.right - c.s(36), top: r.top, right: r.right, bottom: r.bottom)
        c.text(reading.delta ?? "—", deltaRect, c.font(11), reading.colour(c.p), align: .right)
        let barW = c.s(70)
        let bar = RECT(left: deltaRect.left - c.s(6) - barW, top: (r.top + r.bottom) / 2 - c.s(1.5), right: deltaRect.left - c.s(6),
                       bottom: (r.top + r.bottom) / 2 + c.s(1.5))
        if bar.left > r.left + c.s(130) {
            c.round(bar, 1.5, c.p.label, alpha: 0.10)
            let mid = (bar.left + bar.right) / 2
            c.fill(RECT(left: mid, top: bar.top - c.s(2), right: mid + 1, bottom: bar.bottom + c.s(2)), c.p.fill(0.4))
            if let dev = reading.deviation {
                let travel = Double(barW) / 2 - Double(c.s(3.5))
                let x = Double(mid) + max(-6, min(6, dev)) / 6 * travel
                c.ellipse(RECT(x: Int32(x) - c.s(3.5), y: (r.top + r.bottom) / 2 - c.s(3.5), width: c.s(7), height: c.s(7)), reading.colour(c.p))
            }
        }
        var now = "\(reading.value) LUFS"
        if let d = reading.delta { now += ", \(d) LU against the target" }
        if reading.provisional { now += " — provisional, still gathering gated blocks" }
        hit(r, "lrow-\(label)", tip: tooltip(detail, now: now), double: { [unowned self] in self.grabber.resetLoudness() })
    }

    private func drawCompactStreams(_ c: Canvas, _ r: RECT) -> Int32 {
        let pad = c.s(11)
        let passes: (DiscoveredStream) -> Bool = { [unowned self] s in self.grabber.sourceFilter.map { s.description.source == $0 } ?? true }
        let listening = grabber.streams.filter { (grabber.isSubscribed($0.id) || grabber.autoStopped[$0.id] != nil) && passes($0) }
        let available = grabber.streams.filter { !grabber.isSubscribed($0.id) && grabber.autoStopped[$0.id] == nil
            && !grabber.ignoredStreams.contains($0.id) && passes($0) }
        let head = RECT(left: r.left + pad, top: r.top, right: r.right - pad, bottom: r.top + c.s(30))
        drawFoldHeading(c, head, "Listening", open: view.streamsOpen, key: "fold-listen") { [unowned self] in self.view.streamsOpen.toggle() }
        if !view.streamsOpen {
            let summary = listening.isEmpty ? "nothing" : listening.count > 1
                ? "\(listening[0].description.name)  +\(listening.count - 1)" : listening[0].description.name
            let titleW = c.s(14) + c.width("Listening", c.font(12, .semibold)) + c.s(8)
            c.text(summary, RECT(left: head.left + titleW, top: head.top, right: head.right, bottom: head.bottom), c.font(10), c.p.muted,
                   align: .right, middle: true)
            return head.bottom
        }
        var y = head.bottom
        let left = r.left + pad, right = r.right - pad
        if grabber.sourceCounts.count > 1 || grabber.sourceFilter != nil {
            drawSourceFilterRow(c, RECT(left: left, top: y, right: right, bottom: y + c.s(18)), compact: true)
            y += c.s(22)
        }
        if grabber.streams.isEmpty {
            c.text("Nothing found on \(grabber.selectedInterface) yet.", RECT(left: left, top: y, right: right, bottom: y + c.s(16)), c.font(11, .medium), c.p.text)
            y += c.s(18)
            y += c.wrapped("AES67, RAVENNA and Dante in AES67 mode appear by themselves. VBAN and the rest are switched on in Settings.",
                           RECT(left: left, top: y, right: right, bottom: y + c.s(60)), c.font(10), c.p.muted) + c.s(6)
            var x = left
            for (title, action) in [("Sources…", { [unowned self] in self.view.settingsPane = .sources; self.view.showSettings = true }),
                                    ("SDP Address…", { [unowned self] in self.openAddStream() })] as [(String, () -> Void)] {
                let w = c.buttonWidth(title, size: 11)
                let b = RECT(x: x, y: y, width: w, height: c.s(20))
                c.button(title, b, hover: isHover("cempty-\(title)"))
                hit(b, "cempty-\(title)") { _ in action() }
                x = b.right + c.s(6)
            }
            y += c.s(28)
        } else if listening.isEmpty {
            c.text("Nothing selected yet.", RECT(left: left, top: y, right: right, bottom: y + c.s(18)), c.font(11), c.p.muted)
            y += c.s(22)
        } else {
            for (i, stream) in listening.enumerated() {
                y = drawCompactRow(c, RECT(left: left, top: y, right: right, bottom: y), stream.description)
                if i < listening.count - 1 { c.hline(y, left, right, c.p.hairline); y += 1 }
            }
        }
        if !available.isEmpty {
            let text = "\(available.count) available"
            let f = c.font(9)
            let w = c.width(text, f)
            let t = RECT(left: left, top: y + c.s(2), right: left + w + c.s(14), bottom: y + c.s(18))
            c.text(text, RECT(left: t.left, top: t.top, right: t.left + w + 2, bottom: t.bottom), f, c.p.muted)
            c.chevron(RECT(left: t.left + w + c.s(2), top: t.top, right: t.right, bottom: t.bottom), down: view.showAvailable, colour: c.p.muted, size: 8)
            hit(t, "cavail") { [unowned self] _ in self.view.showAvailable.toggle() }
            y = t.bottom + c.s(2)
            if view.showAvailable {
                for stream in available { y = drawCompactRow(c, RECT(left: left, top: y, right: right, bottom: y), stream.description) }
            }
        }
        return y + c.s(8)
    }

    /// One stream in the compact window: identity above, state below.
    private func drawCompactRow(_ c: Canvas, _ r: RECT, _ d: StreamDescription) -> Int32 {
        let id = d.id
        let active = grabber.isSubscribed(id)
        let receiving = grabber.isReceiving(id)
        var y = r.top + c.s(6)
        let play = RECT(x: r.left, y: y + c.s(1), width: c.s(17), height: c.s(17))
        c.playStop(play, active: active, hover: isHover("cplay-\(id)"))
        hit(play.inset(by: -c.s(3)), "cplay-\(id)", tip: active ? "Stop listening" : "Listen") { [unowned self] _ in self.grabber.toggle(d) }
        let left = play.right + c.s(8)
        // Line one: the source dot, the name, its badges, the count and any trouble.
        let line1 = RECT(left: left, top: y, right: r.right, bottom: y + c.s(18))
        c.ellipse(RECT(x: left, y: (line1.top + line1.bottom) / 2 - c.s(2.5), width: c.s(5), height: c.s(5)), c.p.tint(for: d.source.tint))
        var right = line1.right
        var trouble: (String, String, Colour, String)?
        if !active, let reason = grabber.joinFailures[id] { trouble = ("Can't join", "\u{EA39}", c.p.red, reason + " Press play to try again.") }
        else if !active, let note = grabber.autoStopNote(id) { trouble = ("Timed out", "\u{E916}", c.p.warning, note) }
        else if active, !receiving, grabber.isGone(id) {
            trouble = ("Gone", "\u{E708}", c.p.muted, "The sender has left: no audio and no announcement for a while. It plays again if it comes back.")
        }
        else if active, !receiving { trouble = ("No packets", "\u{E7BA}", c.p.warning, "No packets arriving") }
        if let (text, glyph, colour, tip) = trouble {
            let f = c.font(10)
            let w = c.width(text, f) + c.s(14)
            let tr = RECT(left: right - w, top: line1.top, right: right, bottom: line1.bottom)
            c.icon(glyph, RECT(x: tr.left, y: tr.top, width: c.s(11), height: tr.height), size: 9, colour)
            c.text(text, RECT(left: tr.left + c.s(13), top: tr.top, right: tr.right, bottom: tr.bottom), f, colour)
            hit(tr, "ctrouble-\(id)", tip: tip)
            right = tr.left - c.s(5)
        }
        let count = "\(d.channels) ch"
        let cf = c.font(10)
        c.text(count, RECT(left: right - c.width(count, cf), top: line1.top, right: right, bottom: line1.bottom), cf, c.p.muted)
        right -= c.width(count, cf) + c.s(6)
        let nf = c.font(12, .medium)
        c.text(d.name, RECT(left: left + c.s(10), top: line1.top, right: right, bottom: line1.bottom), nf, c.p.text, middle: true)
        hit(RECT(left: left, top: line1.top, right: right, bottom: line1.bottom), "cname-\(id)",
            tip: [.vban, .scream].contains(d.source) ? "\(d.name), from \(d.originAddress)" : d.name,
            right: { [unowned self] pt in self.rowContextMenu(d, at: pt) })
        y = line1.bottom + c.s(3)
        if active {
            let line2 = RECT(left: left, top: y, right: r.right, bottom: y + c.s(18))
            drawRowMeters(c, RECT(left: line2.left, top: line2.top, right: line2.left + c.s(66), bottom: line2.bottom), d, length: 60, slim: true)
            let pw = c.s(24)
            let s = RECT(x: line2.right - pw, y: line2.top, width: pw, height: line2.height)
            let m = RECT(x: s.left - c.s(3) - pw, y: line2.top, width: pw, height: line2.height)
            c.pill("M", m, on: grabber.isMuted(id), tint: c.p.mute, hover: isHover("cm-\(id)"))
            c.pill("S", s, on: grabber.soloed == id, tint: c.p.solo, hover: isHover("cs-\(id)"))
            hit(m, "cm-\(id)", tip: "Mute this stream") { [unowned self] _ in self.grabber.toggleMute(id) }
            hit(s, "cs-\(id)", tip: "Listen to this stream alone") { [unowned self] _ in self.grabber.toggleSolo(id) }
            if d.channels > 1 {
                let label = Downmix.label(for: grabber.mixMode(for: id), channels: d.channels)
                let mf = c.font(9)
                let w = c.width(label, mf) + c.s(14)
                let mr = RECT(left: m.left - c.s(6) - w, top: line2.top, right: m.left - c.s(6), bottom: line2.bottom)
                c.menuLabel(label, x: mr.left, mr, size: 9, colour: isHover("cmix-\(id)") ? c.p.text : c.p.active)
                hit(mr, "cmix-\(id)", tip: "How this stream reaches the monitor bus.") { [unowned self] _ in
                    self.mixMenu(d, at: POINT(x: mr.left, y: mr.bottom))
                }
            }
            y = line2.bottom + c.s(3)
        }
        if !active || grabber.detailed {
            let text = grabber.detailed && !d.originAddress.isEmpty ? "\(d.source.label) · from \(d.originAddress)" : d.source.label
            c.text(text, RECT(left: left, top: y, right: r.right, bottom: y + c.s(14)), c.font(10), c.p.muted, middle: true)
            y += c.s(14)
        }
        return y + c.s(6)
    }

    private func drawCompactFooter(_ c: Canvas, _ r: RECT) {
        let pad = c.s(11)
        var x = r.left + pad
        let cy = (r.top + r.bottom) / 2
        if grabber.soloed != nil {
            let f = c.font(11, .semibold)
            c.text("Solo", RECT(left: x, top: r.top, right: x + c.width("Solo", f) + 2, bottom: r.bottom), f, c.p.soloText)
            x += c.width("Solo", f) + c.s(8)
            let w = c.buttonWidth("Clear")
            let b = RECT(x: x, y: cy - c.s(10), width: w, height: c.s(20))
            c.button("Clear", b, hover: isHover("csoloclear"))
            hit(b, "csoloclear") { [unowned self] _ in self.grabber.soloed = nil }
            x = b.right + c.s(8)
        }
        let plus = RECT(x: x, y: cy - c.s(9), width: c.s(18), height: c.s(18))
        c.icon("\u{E710}", plus, size: 11, isHover("cadd") ? c.p.text : c.p.muted)
        hit(plus, "cadd", tip: "SDP Address…") { [unowned self] _ in self.openAddStream() }
        var bx = r.right - pad
        if view.compactTab == 1 {
            let playing = grabber.subscribed.count
            if playing > 0 {
                let ok = grabber.subscribed.allSatisfy { grabber.isReceiving($0) }
                let text = "Receiving · \(playing)"
                let f = c.font(11)
                let w = c.width(text, f) + c.s(22)
                let pill = RECT(x: bx - w, y: cy - c.s(9), width: w, height: c.s(18))
                c.round(pill, 9, c.p.label, alpha: 0.06)
                c.ellipse(RECT(x: pill.left + c.s(7), y: cy - c.s(3.5), width: c.s(7), height: c.s(7)), ok ? c.p.green : c.p.warning)
                c.text(text, RECT(left: pill.left + c.s(18), top: pill.top, right: pill.right, bottom: pill.bottom), f, ok ? c.p.text : c.p.warning)
                hit(pill, "crecv", tip: ok ? "Streams playing. Receive has them." : "A stream playing has no audio arriving. Receive says which.") {
                    [unowned self] _ in self.view.compactTab = 0
                }
            }
            return
        }
        if !grabber.subscribed.isEmpty {
            let w = c.buttonWidth("Stop all")
            let b = RECT(x: bx - w, y: cy - c.s(10), width: w, height: c.s(20))
            c.button("Stop all", b, hover: isHover("cstopall"))
            hit(b, "cstopall") { [unowned self] _ in self.grabber.unsubscribeAll() }
            bx = b.left - c.s(8)
        }
        let count = "\(grabber.subscribed.count) of \(grabber.streams.count)"
        let f = c.font(11)
        c.text(count, RECT(left: bx - c.width(count, f), top: r.top, right: bx, bottom: r.bottom), f, c.p.muted)
        bx -= c.width(count, f) + c.s(8)
        if let send = sendState, send.isSending {
            drawSendingPill(c, right: bx, centreY: cy) { [unowned self] in self.view.compactTab = 1 }
        }
    }
}
