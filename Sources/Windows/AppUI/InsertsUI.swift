import Foundation
import WinSDK
import NetworkAudioEngine

extension DrawnWindow {
    // MARK: - Inserts (shared by the Grabber's panel and compact window, and the Sender)

    /// The folding Inserts section; returns its bottom.
    func drawInserts(_ ins: InsertsModel, _ c: Canvas, _ r: RECT, open: Bool, key: String, showCount: Bool,
                     toggle: @escaping () -> Void) -> Int32 {
        let compact = !showCount
        let pad = c.s(compact ? 11 : 12)
        let head = RECT(left: r.left + pad, top: r.top, right: r.right - pad, bottom: r.top + c.s(compact ? 30 : 32))
        drawFoldHeading(c, head, "Inserts", open: open, key: key, toggle: toggle)
        let titleW = c.s(14) + c.width("Inserts", c.font(12, .semibold)) + c.s(8)
        let summary = RECT(left: head.left + titleW, top: head.top, right: head.right, bottom: head.bottom)
        if open && showCount {
            let count = ins.scanning ? "scanning…" : "\(ins.available.count) VST3\(chainLatencyText(ins))"
            c.text(count, summary, c.font(10), c.p.muted, align: .right)
        } else if !open {
            let failed = (0..<ins.slotCount).compactMap { ins.failure($0) }.count
            if failed > 0 {
                c.text(failed == 1 ? "1 insert stopped" : "\(failed) inserts stopped", summary, c.font(10), c.p.red, align: .right)
            } else {
                let loaded = (0..<ins.slotCount).compactMap { i in
                    ins.info(i).map { ins.isBypassed(i) ? "\($0.name) (bypassed)" : $0.name }
                }
                c.text(loaded.isEmpty ? "none" : loaded.joined(separator: ", "), summary, c.font(10), c.p.muted, align: .right, middle: true)
            }
        }
        var y = head.bottom
        guard open else { return y }
        for slot in 0..<ins.slotCount {
            let h = slotHeight(ins, c, slot)
            drawInsertSlot(ins, c, RECT(left: r.left + pad, top: y, right: r.right - pad, bottom: y + h), slot)
            y += h + c.s(5)
        }
        return y + c.s(5)
    }

    private func chainLatencyText(_ ins: InsertsModel) -> String {
        let total = (0..<ins.slotCount).filter { ins.isLive($0) && !ins.isBypassed($0) }.map { ins.latencyMs($0) }.reduce(0, +)
        return total > 0.05 ? String(format: " · +%.1f ms", total) : ""
    }

    func slotHeight(_ ins: InsertsModel, _ c: Canvas, _ slot: Int) -> Int32 {
        if ins.failure(slot) != nil { return c.s(52) }
        return c.s(ins.info(slot) != nil && ins.showMix() ? 50 : 30)
    }

    /// One slot (the Mac's `InsertSlotView`): the plugin chooser, BYP, Δ, its editor.
    private func drawInsertSlot(_ ins: InsertsModel, _ c: Canvas, _ r: RECT, _ slot: Int) {
        let info = ins.info(slot)
        if let failure = ins.failure(slot) {
            c.round(r, 6, c.p.red, alpha: 0.10, border: c.p.red, borderAlpha: 0.35)
            c.icon("\u{EA39}", RECT(x: r.left + c.s(8), y: r.top + c.s(6), width: c.s(12), height: c.s(14)), size: 10, c.p.red)
            c.text(info?.name ?? "Plug-in", RECT(left: r.left + c.s(24), top: r.top + c.s(4), right: r.right - c.s(70), bottom: r.top + c.s(22)),
                   c.font(11, .medium), c.p.text)
            c.text(failure, RECT(left: r.left + c.s(8), top: r.top + c.s(24), right: r.right - c.s(8), bottom: r.bottom - c.s(4)), c.font(10), c.p.muted)
            let w = c.buttonWidth("Reload", size: 10)
            let b = RECT(x: r.right - c.s(8) - w, y: r.top + c.s(5), width: w, height: c.s(18))
            c.button("Reload", b, hover: isHover("reload-\(slot)"), size: 10)
            hit(b, "reload-\(slot)") { _ in ins.reload(slot) }
            return
        }
        c.round(r, 6, c.p.label, alpha: 0.05)
        let line = RECT(left: r.left + c.s(8), top: r.top + c.s(5), right: r.right - c.s(8), bottom: r.top + c.s(25))
        let cy = (line.top + line.bottom) / 2
        var right = line.right
        if info != nil {
            // The editor, Δ, BYP, the through meter, from the right.
            let editor = RECT(x: right - c.s(16), y: line.top, width: c.s(16), height: line.height)
            c.icon("\u{E9E9}", editor, size: 10, isHover("edit-\(slot)") ? c.p.text : c.p.muted)
            hit(editor, "edit-\(slot)", tip: tooltip("Opens this plug-in's own window, with its own controls.",
                                                     now: info.map { "\($0.name) — \($0.vendor)" } ?? "Nothing loaded.")) { [unowned self] _ in
                ins.openEditor(slot, parent: self.hwnd)
            }
            right = editor.left - c.s(3)
            let live = ins.isLive(slot), bypassed = ins.isBypassed(slot)
            let dw = c.pillWidth("Δ")
            let delta = RECT(x: right - dw, y: cy - c.s(9), width: dw, height: c.s(18))
            c.pill("Δ", delta, on: ins.deltaSlot == slot, tint: c.p.delta, hover: isHover("delta-\(slot)"), enabled: live && !bypassed)
            hit(delta, "delta-\(slot)", tip: deltaHelp(ins, slot)) { [unowned self] _ in
                if live && !bypassed { ins.toggleDelta(slot) }
            }
            right = delta.left - c.s(3)
            let bw = c.pillWidth("BYP")
            let byp = RECT(x: right - bw, y: cy - c.s(9), width: bw, height: c.s(18))
            c.pill("BYP", byp, on: bypassed, tint: Colour(1, 0.58, 0), hover: isHover("byp-\(slot)"))
            hit(byp, "byp-\(slot)", tip: tooltip("Bypass — takes the plug-in out of circuit entirely, so you hear the signal without it. "
                                                 + "A hard bypass: the wet path is silenced rather than the plug-in being asked to stop, "
                                                 + "which several plug-ins ignore. It is also the only path with no insert latency in it.",
                                                 now: bypassed ? "ON — this plug-in is out of circuit." : "Off — the plug-in is processing.")) {
                _ in ins.toggleBypass(slot)
            }
            right = byp.left - c.s(4)
            if live {
                let meterW = c.s(22) * 2 + c.s(10)
                let m = RECT(x: right - meterW, y: cy - c.s(1.5), width: meterW, height: c.s(3))
                c.bar(RECT(x: m.left, y: m.top, width: c.s(22), height: m.height), level: ins.level(slot, output: false), vertical: false)
                c.icon("\u{E72A}", RECT(x: m.left + c.s(22), y: cy - c.s(5), width: c.s(10), height: c.s(10)), size: 7, c.p.muted)
                c.bar(RECT(x: m.right - c.s(22), y: m.top, width: c.s(22), height: m.height), level: ins.level(slot, output: true), vertical: false)
                hit(RECT(left: m.left, top: line.top, right: m.right, bottom: line.bottom), "through-\(slot)",
                    tip: "Level going into this plug-in, and coming out of it.")
                right = m.left - c.s(4)
            }
            if ins.isRefused(slot) {
                let text = "needs \(ins.width()) ch"
                let w = c.width(text, c.font(9, .semibold)) + c.s(10)
                _ = c.chip(text, x: right - w, centreY: cy, tint: c.p.warning, filled: true)
                hit(RECT(left: right - w, top: line.top, right: right, bottom: line.bottom), "refused-\(slot)",
                    tip: tooltip("This plug-in will not take a bus this wide, so it is held out of the chain entirely rather than "
                                 + "applied to part of it — what you hear would not be what the meters show.",
                                 now: "Out of circuit. Narrow the \(ins.widthName), or use a plug-in that handles \(ins.width()) channels."))
                right -= w + c.s(4)
            }
        }
        // The chooser: the plug-in's name as a menu.
        let title = info?.name ?? "Empty"
        let ml = c.menuLabel(title, x: line.left, RECT(left: line.left, top: line.top, right: right, bottom: line.bottom), size: 11,
                             colour: info == nil ? c.p.muted : (isHover("choose-\(slot)") ? c.p.active : c.p.text))
        hit(RECT(left: line.left, top: line.top, right: max(ml.right, line.left + c.s(40)), bottom: line.bottom), "choose-\(slot)",
            tip: ins.scanning ? "Still looking for VST3 plug-ins…" : "Choose a VST3 plug-in for insert \(slot + 1).") { [unowned self] _ in
            self.pluginMenu(ins, slot, at: POINT(x: line.left, y: line.bottom))
        }
        // Dry/wet, ours rather than the plug-in's.
        if info != nil && ins.showMix() {
            let row = RECT(left: line.left, top: line.bottom + c.s(3), right: line.right, bottom: line.bottom + c.s(19))
            let dimmed = ins.isBypassed(slot) || ins.deltaSlot == slot
            let lab = c.font(8, .bold)
            let col = dimmed ? c.p.muted.over(c.p.panel, 0.5) : c.p.muted
            c.text("DRY", RECT(left: row.left, top: row.top, right: row.left + c.s(22), bottom: row.bottom), lab, col)
            let pct = "\(Int((ins.mix[slot] * 100).rounded())) %"
            c.text(pct, RECT(left: row.right - c.s(34), top: row.top, right: row.right, bottom: row.bottom), c.font(10), col, align: .right)
            c.text("WET", RECT(left: row.right - c.s(62), top: row.top, right: row.right - c.s(36), bottom: row.bottom), lab, col)
            let track = RECT(left: row.left + c.s(28), top: row.top, right: row.right - c.s(74), bottom: row.bottom)
            c.slider(track, fraction: ins.mix[slot], mini: true, enabled: !dimmed)
            sliderHit(track, track: track, "mix-\(slot)",
                      tip: tooltip("Dry/wet balance for this insert — ours, not the plug-in's, so it works for every plug-in. The dry path "
                                   + "is delayed to match the plug-in's reported latency, so a partial blend sums instead of comb-filtering.",
                                   now: "\(Int((ins.mix[slot] * 100).rounded())) % wet."),
                      set: { f in ins.setMix(slot, f) }, reset: { ins.setMix(slot, 1) })
        }
    }

    private func deltaHelp(_ ins: InsertsModel, _ slot: Int) -> String {
        let what = "Delta — hear only what this plug-in changed: wet minus dry, and none of the programme. Silence means it is "
            + "doing nothing at all. One insert at a time, and it overrides the dry/wet balance while it is on."
        if ins.isBypassed(slot) { return tooltip(what, now: "Unavailable — the insert is bypassed, so there is no difference to hear.") }
        if ins.isRefused(slot) { return tooltip(what, now: "Unavailable — this plug-in will not take a \(ins.width())-channel bus.") }
        if !ins.isLive(slot) { return tooltip(what, now: "Unavailable — waiting for the plug-in to finish loading.") }
        guard ins.deltaSlot == slot else { return tooltip(what, now: "Off — you are hearing the processed signal.") }
        let ms = ins.latencyMs(slot)
        return tooltip(what, now: "ON — you are hearing the difference, not the programme; "
                       + (ms > 0.05 ? String(format: "the dry path is delayed %.1f ms to match the plug-in.", ms)
                                    : "the plug-in reports no latency, so nothing is compensated — if it has any, this combs rather than nulls."))
    }

    /// Plug-ins grouped by vendor, as the Mac's picker groups them by manufacturer.
    func pluginMenu(_ ins: InsertsModel, _ slot: Int, at pt: POINT) {
        var entries: [MenuEntry] = []
        if ins.info(slot) != nil {
            entries.append(.item("None") { ins.setPlugin(slot, nil) })
            entries.append(.separator)
        }
        if ins.available.isEmpty {
            entries.append(.heading(ins.scanning ? "Looking for VST3 plug-ins…" : "No VST3 plug-ins found"))
        } else {
            let byVendor = Dictionary(grouping: ins.available, by: { $0.vendor.isEmpty ? "Other" : $0.vendor })
            for vendor in byVendor.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
                let plugins = byVendor[vendor]!.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                entries.append(.submenu(vendor, plugins.map { plugin in
                    .item(plugin.name, checked: ins.info(slot)?.id == plugin.id) { ins.setPlugin(slot, plugin) }
                }))
            }
        }
        entries.append(.separator)
        entries.append(.item("Look for plug-ins again") { ins.rescan() })
        popup(entries, at: pt)
    }

}
