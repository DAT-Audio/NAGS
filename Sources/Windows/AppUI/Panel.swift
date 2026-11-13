import Foundation
import WinSDK
import NetworkAudioEngine
import GrabberCore

/// The right-hand signal panel (the Mac's `SignalPanel`): the monitor path read top to bottom —
/// the inserts, then the output with every loudness reading beside its meters.
enum PanelLayout {
    static let width = 272.0
}

extension GrabberWindow {
    func drawSignalPanel(_ c: Canvas, _ r: RECT) {
        c.fill(r, c.p.panel)
        var y = r.top
        y = drawInsertsSection(c, RECT(left: r.left, top: y, right: r.right, bottom: r.bottom), compact: false)
        c.hline(y, r.left, r.right, c.p.divider)
        drawOutputSection(c, RECT(left: r.left, top: y + 1, right: r.right, bottom: r.bottom))
    }

    // MARK: - Output

    private static let scaleMarks: [Int] = [0, -6, -12, -18, -24, -30, -40, -50, -60]

    static func barGeometry(_ n: Int) -> (thickness: Double, slot: Double) {
        if n <= 2 { return (24, 30) }
        let slot = min(16, (96 / Double(n)).rounded(.down))
        return (max(3, slot - (slot >= 10 ? 4 : 2)), slot)
    }

    private func drawOutputSection(_ c: Canvas, _ r: RECT) {
        let pad = c.s(12)
        let inner = RECT(left: r.left + pad, top: r.top, right: r.right - pad, bottom: r.bottom - pad)
        // Heading: Output, the device, the bus menu, the rate.
        let head = RECT(left: inner.left, top: inner.top + c.s(9), right: inner.right, bottom: inner.top + c.s(27))
        let hf = c.font(12, .semibold)
        let titleX = head.left + c.s(14)
        c.text("Output", RECT(left: titleX, top: head.top, right: titleX + c.width("Output", hf) + 2, bottom: head.bottom), hf, c.p.muted)
        var right = head.right
        let rate = String(format: "%.4g kHz", grabber.outputRate / 1000)
        let rf = c.font(10)
        c.text(rate, RECT(left: right - c.width(rate, rf), top: head.top, right: right, bottom: head.bottom), rf, c.p.muted, align: .right)
        right -= c.width(rate, rf) + c.s(6)
        if grabber.busWidthOptions.count > 1 {
            let label = grabber.busChannels == 2 ? "Stereo" : grabber.busWidthLabel(grabber.busChannels)
            let bf = c.font(9, .medium)
            let w = c.width(label, bf) + c.s(14)
            let busRect = RECT(left: right - w, top: head.top, right: right, bottom: head.bottom)
            c.menuLabel(label, x: busRect.left, busRect, size: 9, colour: isHover("bus") ? c.p.active : c.p.text, weight: .medium)
            hit(busRect, "bus", tip: busWidthHelp()) { [unowned self] _ in self.busMenu(at: POINT(x: busRect.left, y: busRect.bottom)) }
            right = busRect.left - c.s(6)
        }
        let nameX = titleX + c.width("Output", hf) + c.s(6)
        c.text(grabber.outputDeviceName, RECT(left: nameX, top: head.top, right: right, bottom: head.bottom), c.font(11), c.p.muted)
        hit(RECT(left: nameX, top: head.top, right: right, bottom: head.bottom), "outdevice",
            tip: "The output device the monitor bus plays out of. Change it in Settings → Output, or from the toolbar.")

        // Below: volume, DIM/MONO and the history, from the bottom up.
        var bottom = inner.bottom
        if view.showLevelHistory {
            let strip = RECT(left: inner.left, top: bottom - c.s(36), right: inner.right, bottom: bottom)
            drawHistory(c, strip, height: 22)
            bottom = strip.top - c.s(10)
        }
        let pills = RECT(left: inner.left, top: bottom - c.s(20), right: inner.right, bottom: bottom)
        drawDimMono(c, pills)
        bottom = pills.top - c.s(10)
        let volume = RECT(left: inner.left, top: bottom - c.s(20), right: inner.right, bottom: bottom)
        drawVolume(c, volume)
        bottom = volume.top - c.s(10)

        // The figures and the meters share what is left.
        let area = RECT(left: inner.left, top: head.bottom + c.s(10), right: inner.right, bottom: bottom)
        let n = grabber.busChannels
        let reaper = c.p.skin.scaleBetween && n == 2
        let geometry = Self.barGeometry(n)
        let metersWidth = reaper ? c.s(22 + 26 + 22) : c.s(22 + 4) + c.s(geometry.slot * Double(n))
        let meters = RECT(left: area.right - metersWidth, top: area.top, right: area.right, bottom: area.bottom)
        let figures = RECT(left: area.left, top: area.top, right: meters.left - c.s(12), bottom: area.bottom)
        let scale = min(1, max(0.7, c.pt(figures.width) / 150))
        drawOutputFigures(c, figures, scale: scale)
        drawOutputMeters(c, meters, reaper: reaper, geometry: geometry)
    }

    func busWidthHelp() -> String {
        let what = "How wide the monitor bus is. Streams that fit go out channel for channel; anything wider than the bus folds to "
            + "stereo on the first pair. Remembered for this device. With Windows Sonic or Dolby Atmos for Headphones on, 7.1 is "
            + "placed around your head."
        let now = grabber.busChannels == 2 ? "Stereo — wider streams fold down."
            : "\(grabber.busWidthLabel(grabber.busChannels)). Fold-down no longer applies to streams that fit."
        return tooltip(what, now: now)
    }

    func busMenu(at pt: POINT) {
        popup(grabber.busWidthOptions.map { w in
            .item(grabber.busWidthLabel(w), checked: w == grabber.busChannels) { [unowned self] in self.grabber.setBusWidth(w) }
        }, at: pt)
    }

    private func drawOutputFigures(_ c: Canvas, _ r: RECT, scale: Double) {
        let ro = view.readouts
        var y = r.top
        let figureColour = c.p.skin.figureText ?? c.p.text
        // The peak maximum and its clip dot.
        let pf = c.font(28 * scale, .light)
        let ph = c.s(34 * scale)
        let pw = c.width(ro.outputMax, pf)
        c.text(ro.outputMax, RECT(left: r.left, top: y, right: r.left + pw + 2, bottom: y + ph), pf, figureColour)
        c.text("dBFS max", RECT(left: r.left, top: y + ph, right: r.right, bottom: y + ph + c.s(14)), c.font(10), c.p.muted)
        hit(RECT(left: r.left, top: y, right: r.left + max(pw, c.s(60)), bottom: y + ph + c.s(14)), "peakmax",
            tip: "Highest output level since it was last reset. Double-click to reset it and start logging a new maximum.",
            double: { [unowned self] in self.grabber.clearClip() })
        let dot = RECT(x: r.left + pw + c.s(6), y: y + c.s(10 * scale), width: c.s(8), height: c.s(8))
        c.ellipse(dot, grabber.clipped ? c.p.red : c.p.label, alpha: grabber.clipped ? 1 : 0.12)
        hit(dot.inset(by: -c.s(4)), "clip", tip: grabber.clipped ? "Clipped — click to reset the maximum and the clip indicator"
                                                                 : "Click to reset the maximum") { [unowned self] _ in self.grabber.clearClip() }
        y += ph + c.s(14)
        guard grabber.showLoudness else { return }
        y += c.s(16)
        let lf = c.font(11, .semibold)
        c.text("Loudness", RECT(left: r.left, top: y, right: r.right - c.s(16), bottom: y + c.s(15)), lf, c.p.muted)
        let reset = RECT(x: r.right - c.s(14), y: y, width: c.s(14), height: c.s(15))
        c.icon("\u{E72C}", reset, size: 10, isHover("lreset") ? c.p.text : c.p.muted)
        hit(reset, "lreset", tip: "Reset the integrated and window readings (Ctrl+Shift+L)") { [unowned self] _ in self.grabber.resetLoudness() }
        y += c.s(15)
        c.text("target \(target(grabber.targetIntegrated)) LUFS", RECT(left: r.left, top: y, right: r.right, bottom: y + c.s(14)), c.font(10), c.p.muted)
        y += c.s(14)
        let all: [(LoudnessPin, String, LoudnessReading)] = [
            (.shortTerm, "Short-term", ro.shortTerm),
            (.window, "Window \(grabber.lufsWindowSeconds) s", ro.window),
            (.integrated, "Integrated", ro.integrated),
        ]
        let pin = view.pinnedLoudness
        let ordered = all.filter { $0.0 == pin } + all.filter { $0.0 != pin }
        let left = r.left + c.s(8)
        for (kind, label, reading) in ordered {
            let large = kind == pin
            y += c.s(large ? 14 : 10)
            guard y + c.s(14) < r.bottom else { break }
            c.text(label, RECT(left: left, top: y, right: r.right, bottom: y + c.s(14)), c.font(10), c.p.muted)
            y += c.s(14)
            let vf = c.font((large ? 30 : 18) * scale, .light)
            let vh = c.s((large ? 36 : 22) * scale)
            let vw = c.width(reading.value, vf)
            c.text(reading.value, RECT(left: left, top: y, right: left + vw + 2, bottom: y + vh), vf, large ? reading.colour(c.p) : figureColour)
            if let delta = reading.delta {
                let df = c.font(max(9, 11 * scale), .medium)
                c.text(delta, RECT(left: left + vw + c.s(6), top: y, right: r.right, bottom: y + vh - c.s(large ? 5 : 2)), df,
                       reading.colour(c.p), top: false)
            }
            hit(RECT(left: left, top: y - c.s(14), right: r.right, bottom: y + vh), "reading-\(kind.rawValue)",
                tip: "\(label): \(reading.value) LUFS. Double-click to reset the measurement.",
                double: { [unowned self] in self.grabber.resetLoudness() })
            y += vh
        }
    }

    func target(_ v: Double) -> String {
        (v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.1f", v)).replacingOccurrences(of: "-", with: "−")
    }

    private func drawOutputMeters(_ c: Canvas, _ r: RECT, reaper: Bool, geometry: (thickness: Double, slot: Double)) {
        let n = grabber.busChannels
        let length = max(c.s(60), r.height - c.s(18))
        let top = r.top
        let hold = grabber.outputPeakHold
        let tip = tooltip("The monitor bus, peak, taken after the inserts and the monitor controls — the last thing before the output "
                          + "device. Green to −18 dBFS, amber to −6, red above; the tick is the peak hold. The loudness readings are "
                          + "measured ahead of all of this.",
                          now: "\(grabber.busWidthLabel(n)) out of \(grabber.outputDeviceName)."
                            + (grabber.monoFold ? " MONO: every channel carries the same sum." : "")
                            + (grabber.dimmed ? " DIM: 20 dB down." : ""))
        let scaleFont = c.font(9)
        if reaper {
            // REAPER's master: two bars with the scale between them.
            for ch in 0..<2 {
                let x = ch == 0 ? r.left : r.left + c.s(22 + 26)
                let bar = RECT(x: x, y: top, width: c.s(22), height: length)
                c.bar(bar, level: grabber.outputPeak(ch), vertical: true, hold: hold)
                c.text(ch == 0 ? "L" : "R", RECT(x: x, y: top + length + c.s(4), width: c.s(22), height: c.s(12)), c.font(9, .semibold),
                       c.p.muted, align: .centre)
            }
            for db in Self.scaleMarks {
                let y = top + Int32(Double(length) * Double(-db) / 60)
                c.text("\(db)".replacingOccurrences(of: "-", with: "−"), RECT(x: r.left + c.s(22), y: y - c.s(6), width: c.s(26), height: c.s(12)),
                       scaleFont, c.p.muted, align: .centre)
            }
        } else {
            for db in Self.scaleMarks {
                let y = top + Int32(Double(length) * Double(-db) / 60)
                c.text("\(db)".replacingOccurrences(of: "-", with: "−"), RECT(x: r.left, y: y - c.s(6), width: c.s(22), height: c.s(12)),
                       scaleFont, c.p.muted, align: .right)
            }
            let barsLeft = r.left + c.s(26)
            let names = barLabels()
            for ch in 0..<n {
                let slot = RECT(x: barsLeft + c.s(geometry.slot * Double(ch)), y: top, width: c.s(geometry.slot), height: length)
                let bar = RECT(x: slot.left + (slot.width - c.s(geometry.thickness)) / 2, y: top, width: c.s(geometry.thickness), height: length)
                c.bar(bar, level: grabber.outputPeak(ch), vertical: true, hold: hold)
                if ch < names.count, !names[ch].isEmpty {
                    c.text(names[ch], RECT(x: slot.left - c.s(4), y: top + length + c.s(4), width: slot.width + c.s(8), height: c.s(12)),
                           c.font(n <= 6 ? 8 : 7, .semibold), c.p.muted, align: .centre)
                }
            }
        }
        hit(RECT(left: r.left, top: top, right: r.right, bottom: top + length), "meters", tip: tip)
    }

    /// Channel names under the bars: in full to 6, two letters to 8, every fourth past that.
    private func barLabels() -> [String] {
        let names = grabber.busChannelLabels
        let n = grabber.busChannels
        if n > 8 { return names.indices.map { $0 % 4 == 0 ? names[$0] : "" } }
        if n > 6 { return names.map { $0.count <= 2 ? $0 : String($0.prefix(2)) } }
        return names
    }

    func drawVolume(_ c: Canvas, _ r: RECT) {
        let v = grabber.masterVolume
        c.icon(v > 0 ? "\u{E767}" : "\u{E74F}", RECT(x: r.left, y: r.top, width: c.s(14), height: r.height), size: 11, c.p.muted)
        let label = v > 0.0001 ? String(format: "%.1f dB", 20 * log10(v)).replacingOccurrences(of: "-", with: "−") : "−∞ dB"
        c.text(label, RECT(left: r.right - c.s(46), top: r.top, right: r.right, bottom: r.bottom), c.font(10), c.p.muted, align: .right)
        let track = RECT(left: r.left + c.s(22), top: r.top, right: r.right - c.s(52), bottom: r.bottom)
        c.slider(track, fraction: v)
        let db = v > 0.0001 ? String(format: "%+.1f dB", 20 * log10(v)).replacingOccurrences(of: "-", with: "−") : "−∞"
        sliderHit(track, track: track, "volume",
                  tip: "Monitor level: \(db), \(Int((v * 100).rounded())) % of the slider's travel. The slider is linear in amplitude, "
                    + "so 50 % is −6 dB." + (grabber.dimmed ? " DIM is engaged, taking a further −20 dB." : "")
                    + " Double-click to return to 0 dB.",
                  set: { [unowned self] f in self.grabber.masterVolume = f }, reset: { [unowned self] in self.grabber.masterVolume = 1 })
    }

    func drawDimMono(_ c: Canvas, _ r: RECT) {
        let dw = c.pillWidth("DIM"), mw = c.pillWidth("MONO")
        let dim = RECT(x: r.left, y: r.top, width: dw, height: r.height)
        let mono = RECT(x: dim.right + c.s(5), y: r.top, width: mw, height: r.height)
        c.pill("DIM", dim, on: grabber.dimmed, tint: c.p.active, hover: isHover("dim"))
        c.pill("MONO", mono, on: grabber.monoFold, tint: c.p.active, hover: isHover("mono"))
        hit(dim, "dim", tip: tooltip("Drops the monitor level by 20 dB — the conventional dim on a monitor controller. It sits after the "
                                     + "loudness measurement, so it cannot move a reading.",
                                     now: grabber.dimmed ? "ON — output is 20 dB down." : "Off.")) { [unowned self] _ in self.grabber.dimmed.toggle() }
        hit(mono, "mono", tip: tooltip("Sums the bus to one signal and sends it to every channel, for a phase check: anything that thins or "
                                       + "disappears is out of phase. Averaged, not added, so a correlated mix stays at the level it was.",
                                       now: grabber.monoFold ? "ON — you are hearing a mono sum, not the mix." : "Off — hearing the mix as it is.")) {
            [unowned self] _ in self.grabber.monoFold.toggle()
        }
    }

    /// The last 30 seconds of the output peak, muted colours, red where audio did not arrive.
    func drawHistory(_ c: Canvas, _ r: RECT, height: Double) {
        let graph = RECT(left: r.left, top: r.top, right: r.right, bottom: r.top + c.s(height))
        let store = view.history
        let n = LevelHistory.capacity
        let step = Double(graph.width) / Double(n)
        let bar = max(1, step * 0.6)
        let mid = Double(graph.top + graph.bottom) / 2
        for i in 0..<n {
            let k = (store.head + i) % n
            let x = Double(graph.left) + Double(i) * step
            guard i >= n - store.filled else {
                c.fill(RECT(left: Int32(x), top: Int32(mid), right: Int32(x + bar), bottom: Int32(mid) + 1), c.p.fill(0.08, on: c.p.panel))
                continue
            }
            if store.faults[k] {
                c.fill(RECT(left: Int32(x), top: graph.top, right: Int32(x + bar), bottom: graph.bottom), c.p.panel.over(c.p.red, 0.55))
                continue
            }
            let f = Canvas.fraction(store.peaks[k])
            let h = max(1, Double(graph.height) * f)
            c.fill(RECT(left: Int32(x), top: Int32(mid - h / 2), right: Int32(max(x + 1, x + bar)), bottom: Int32(mid + h / 2)),
                   c.p.panel.over(c.p.label, f > 0.8 ? 0.55 : 0.30))
        }
        let lf = c.font(9)
        c.text("30 s ago", RECT(left: r.left, top: graph.bottom + c.s(2), right: r.right, bottom: graph.bottom + c.s(14)), lf, c.p.muted)
        c.text("now", RECT(left: r.left, top: graph.bottom + c.s(2), right: r.right, bottom: graph.bottom + c.s(14)), lf, c.p.muted, align: .right)
        hit(r, "history", tip: "The output peak over the last 30 seconds. A red mark is a moment when audio stopped arriving or the buffer "
                                + "ran out. Turn it off in Settings → View.")
    }
}

extension GrabberWindow {
    /// The Grabber's Inserts section: the panel's folds apart from the compact window's.
    func drawInsertsSection(_ c: Canvas, _ r: RECT, compact: Bool) -> Int32 {
        let open = compact ? view.insertsOpen : view.panelInsertsOpen
        return drawInserts(inserts, c, r, open: open, key: compact ? "fold-cinserts" : "fold-pinserts", showCount: !compact) { [unowned self] in
            if compact { self.view.insertsOpen.toggle() } else { self.view.panelInsertsOpen.toggle() }
        }
    }
}
