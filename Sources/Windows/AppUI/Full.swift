import Foundation
import WinSDK
import NetworkAudioEngine
import GrabberCore

/// The Mac's column widths (`StreamRowView.Column`), in one place: a list only reads as columns
/// if every row agrees about them.
enum Column {
    static let star = 12.0, play = 20.0, mix = 68.0, meter = 54.0, trim = 78.0, gain = 36.0
    static let states = 52.0, chips = 112.0, jitter = 50.0, status = 92.0, rowHeight = 30.0
    static let controls = mix + meter + trim + gain + states + 4 * 7
}

extension DiscoverySource {
    var tint: DiscoverySourceTint {
        switch self {
        case .ravenna: return .ravenna
        case .dante: return .dante
        case .sap: return .sap
        case .manual: return .manual
        case .vban: return .vban
        case .scream: return .scream
        case .web: return .web
        }
    }

    /// The sidebar's names.
    var sidebarName: String {
        switch self {
        case .ravenna: return "RAVENNA"
        case .dante: return "Dante (AES67)"
        case .sap: return "AES67 (SAP)"
        case .vban: return "VBAN"
        case .scream: return "Scream"
        case .web: return "Internet radio"
        case .manual: return "Manual"
        }
    }

    static let sidebarOrder: [DiscoverySource] = [.ravenna, .dante, .sap, .vban, .scream, .web, .manual]
}

extension GrabberWindow {
    // MARK: - The full window

    func drawFull(_ c: Canvas, _ client: RECT) {
        let toolbar = RECT(left: 0, top: 0, right: client.right, bottom: c.s(44))
        drawToolbar(c, toolbar, compact: false)
        c.hline(toolbar.bottom, 0, client.right, c.p.divider)
        var top = toolbar.bottom + 1
        var bottom = client.bottom
        if view.showLog {
            let drawer = RECT(left: 0, top: client.bottom - c.s(120), right: client.right, bottom: client.bottom)
            c.hline(drawer.top - 1, 0, client.right, c.p.divider)
            drawLogDrawer(c, drawer)
            bottom = drawer.top - 1
        }
        if grabber.danteNeedsAES67 { top = drawDanteBanner(c, RECT(left: 0, top: top, right: client.right, bottom: bottom)) }

        // The widths: the panel and the sidebar as dragged, giving way to a Stream column that
        // has been dragged wider than what is left for it.
        let showBar = view.showSourceBar && !view.showSettings && !view.sourceFilterRow
        var panelW = view.showPanel ? c.s(min(max(view.panelWidth, ViewState.panelRange.lowerBound), ViewState.panelRange.upperBound)) : 0
        var barW = showBar ? c.s(min(max(view.sidebarWidth, ViewState.sidebarRange.lowerBound), ViewState.sidebarRange.upperBound)) : 0
        if view.streamWidth > 0, !view.showSettings {
            let listW = client.width - panelW - barW - (view.showPanel ? 1 : 0) - (showBar ? 1 : 0)
            var short = c.s(view.streamWidth) - (listW - listFixedWidth(c))
            if short > 0, view.showPanel {
                let give = max(0, min(short, panelW - c.s(ViewState.panelRange.lowerBound)))
                panelW -= give
                short -= give
            }
            if short > 0, showBar {
                barW -= max(0, min(short, barW - c.s(ViewState.sidebarRange.lowerBound)))
            }
        }
        var left: Int32 = 0
        var right = client.right
        if view.showPanel {
            let panel = RECT(left: client.right - panelW, top: top, right: client.right, bottom: bottom)
            c.vline(panel.left - 1, top, bottom, isHover("split-panel") ? c.p.active : c.p.divider)
            drawSignalPanel(c, panel)
            right = panel.left - 1
            // Its edge, dragged to make the panel wider or narrower.
            sliderHit(RECT(left: panel.left - c.s(4), top: top, right: panel.left + c.s(3), bottom: bottom), track: client, "split-panel",
                      tip: "Drag to make the signal panel wider or narrower. Double-click for its usual width.",
                      set: { [unowned self] f in
                          let x = Int32(Double(client.width) * f)
                          self.view.panelWidth = min(max(c.pt(client.right - x), ViewState.panelRange.lowerBound), ViewState.panelRange.upperBound)
                          self.view.streamWidth = 0
                      }, reset: { [unowned self] in
                          self.view.panelWidth = PanelLayout.width
                          self.view.streamWidth = 0
                      })
        }
        if showBar {
            let bar = RECT(left: 0, top: top, right: barW, bottom: bottom)
            drawSourceSidebar(c, bar)
            c.vline(bar.right, top, bottom, isHover("split-bar") ? c.p.active : c.p.divider)
            left = bar.right + 1
            sliderHit(RECT(left: bar.right - c.s(3), top: top, right: bar.right + c.s(4), bottom: bottom), track: client, "split-bar",
                      tip: "Drag to make the source sidebar wider or narrower. Double-click for its usual width.",
                      set: { [unowned self] f in
                          let x = Int32(Double(client.width) * f)
                          self.view.sidebarWidth = min(max(c.pt(x), ViewState.sidebarRange.lowerBound), ViewState.sidebarRange.upperBound)
                      }, reset: { [unowned self] in self.view.sidebarWidth = 164 })
        }
        let column = RECT(left: left, top: top, right: right, bottom: bottom)
        if view.showSettings {
            drawSettings(c, column, compact: false)
        } else {
            let status = RECT(left: left, top: bottom - c.s(32), right: right, bottom: bottom)
            c.hline(status.top - 1, left, right, c.p.divider)
            drawStatusBar(c, status)
            // Send, along the bottom, above the status bar.
            var listBottom = status.top - 1
            let sendH = sendSectionHeight(c)
            if sendH > 0 {
                let section = RECT(left: left, top: listBottom - sendH, right: right, bottom: listBottom)
                c.hline(section.top - 1, left, right, c.p.divider)
                drawSendSection(c, section)
                listBottom = section.top - 1
            }
            drawStreamList(c, RECT(left: left, top: top, right: right, bottom: listBottom))
        }
    }

    // MARK: - Toolbar

    /// The emblem, the network, the output; on the right the window's own buttons.
    func drawToolbar(_ c: Canvas, _ r: RECT, compact: Bool) {
        let pad = c.s(compact ? 11 : 12)
        var x = r.left + pad
        let cy = (r.top + r.bottom) / 2
        // The emblem: the Mac's open ring and its dot, and the app's name beside it.
        // The Mac's sizes: 22 points in the full window, 18 in the compact one, the name at 0.6
        // of that beside it, the whole at 60 %.
        let size = compact ? 18.0 : 22.0
        let ring = c.s(size)
        let ringRect = RECT(x: x, y: cy - ring / 2, width: ring, height: ring)
        drawEmblem(c, ringRect)
        x = ringRect.right + c.s(size * 0.32)
        let name = "Grabber"
        let nameFont = c.font((size * 0.6).rounded(), .semibold)
        c.text(name, RECT(left: x, top: r.top, right: x + c.width(name, nameFont) + 2, bottom: r.bottom), nameFont,
               c.p.window.over(c.p.muted, 0.6))
        x += c.width(name, nameFont) + c.s(10)
        if !compact {
            c.vline(x, cy - c.s(9), cy + c.s(9), c.p.divider)
            x += c.s(10)
        }

        // The network AES67 is received on, as a menu.
        let iface = grabber.selectedInterface
        c.ellipse(RECT(x: x, y: cy - c.s(3), width: c.s(6), height: c.s(6)), iface.isEmpty ? c.p.warning : c.p.green)
        let netX = x + c.s(11)
        let netFont = c.font(11, .medium)
        let netName = iface.isEmpty ? "No interface" : iface
        var netRight = netX + min(c.width(netName, netFont), c.s(compact ? 70 : 150))
        // In the Active colour, as the Mac's header menus are.
        c.text(netName, RECT(left: netX, top: r.top, right: netRight + 2, bottom: r.bottom), netFont,
               iface.isEmpty ? c.p.warning : c.p.active)
        if !compact {
            let address = grabber.interfaceAddress
            let mono = c.font(10)
            c.text(address, RECT(left: netRight + c.s(5), top: r.top, right: netRight + c.s(5) + c.width(address, mono) + 2,
                                 bottom: r.bottom), mono, c.p.muted)
            netRight += c.s(5) + c.width(address, mono)
        }
        c.chevron(RECT(left: netRight + c.s(3), top: r.top, right: netRight + c.s(13), bottom: r.bottom), down: true,
                  colour: c.p.muted, size: 7)
        let netHit = RECT(left: x - c.s(2), top: r.top + c.s(6), right: netRight + c.s(14), bottom: r.bottom - c.s(6))
        hit(netHit, "net", tip: tooltip("The network interface multicast groups are joined on. Also rescans the "
                                        + "interface list and restarts discovery.",
                                        now: iface.isEmpty ? "None selected — nothing can arrive."
                                                           : "\(iface) — \(grabber.interfaceAddress)"),
            click: { [unowned self] pt in self.interfaceMenu(at: POINT(x: netHit.left, y: netHit.bottom)) })
        x = netHit.right + c.s(compact ? 6 : 10)
        if !compact {
            c.vline(x, cy - c.s(7), cy + c.s(7), c.p.divider)
            x += c.s(10)
        }

        // The window's own buttons, from the right.
        var bx = r.right - pad
        func toolButton(_ glyph: String, _ key: String, on: Bool, tip: String, size: Double = 12, action: @escaping () -> Void) {
            let w = c.s(22)
            let b = RECT(x: bx - w, y: cy - c.s(11), width: w, height: c.s(22))
            if isHover(key) { c.round(b, 5, c.p.label, alpha: 0.08) }
            c.icon(glyph, b, size: size, on ? c.p.active : (isHover(key) ? c.p.text : c.p.secondary))
            hit(b, key, tip: tip, click: { _ in action() })
            bx = b.left - c.s(4)
        }
        toolButton("\u{E713}", "gear", on: view.showSettings,
                   tip: view.showSettings ? "Back to the streams (Ctrl+,)" : "Settings (Ctrl+,)") { [unowned self] in
            self.commitField(); self.view.showSettings.toggle(); self.restyle()
        }
        if compact {
            toolButton("\u{E740}", "mode", on: false, tip: "Back to the full window", size: 11) { [unowned self] in
                self.switchMode(.full)
            }
        } else {
            toolButton("\u{E73F}", "mode", on: false,
                       tip: tooltip("Switches to the compact window — the same controls in a strip narrow enough "
                                    + "to leave beside something else. Each window remembers its own size.",
                                    now: "In the full window."), size: 11) { [unowned self] in self.switchMode(.compact) }
            toolButton("\u{E90D}", "panel", on: view.showPanel,
                       tip: tooltip("The signal panel: the whole monitor path top to bottom — the inserts, the "
                                    + "output meters and the loudness readings.", now: view.showPanel ? "Shown." : "Hidden."),
                       size: 11) { [unowned self] in self.view.showPanel.toggle() }
            toolButton("\u{E90C}", "sidebar", on: view.showSourceBar,
                       tip: tooltip("The source sidebar: show every kind of stream, or only one — RAVENNA, Dante, "
                                    + "VBAN and the rest — when the list gets long. The choice is remembered.",
                                    now: view.showSourceBar ? "Shown, " + (grabber.sourceFilter.map { "showing \($0.sidebarName) only." }
                                                                            ?? "showing all streams.") : "Hidden."),
                       size: 11) { [unowned self] in self.view.showSourceBar.toggle() }
        }

        // The output device, with its rate (and, compact, its width), in the room left.
        let room = RECT(left: x, top: r.top, right: bx - c.s(8), bottom: r.bottom)
        guard room.width > c.s(40) else { return }
        let rateText = String(format: "%.4g kHz", grabber.outputRate / 1000)
        let small = c.font(10)
        let extra = compact ? " \(grabber.wasapi.mixChannels) ch" : ""
        let figuresW = c.width(rateText + extra, small)
        let deviceFont = c.font(11)
        let glyphW = c.s(18)
        let device = grabber.outputRunning ? outputDeviceLabel() : "No output"
        let chevronW = c.s(12)
        let nameW = min(c.width(device, deviceFont), room.width - figuresW - glyphW - chevronW - c.s(16))
        let fallback = grabber.wasapi.usingFallback
        c.icon(fallback ? "\u{E7BA}" : "\u{E7F6}", RECT(x: room.left, y: r.top, width: glyphW, height: r.height), size: 11,
               fallback ? c.p.warning : c.p.active)
        c.text(device, RECT(left: room.left + glyphW + c.s(2), top: r.top, right: room.left + glyphW + c.s(2) + max(0, nameW), bottom: r.bottom),
               deviceFont, c.p.active)
        // The chevron after the name, as the Mac's menu.
        let chevronX = room.left + glyphW + c.s(5) + max(0, nameW)
        c.chevron(RECT(left: chevronX, top: r.top, right: chevronX + c.s(8), bottom: r.bottom), down: true,
                  colour: c.p.muted, size: 7)
        let fx = chevronX + chevronW
        c.text(rateText, RECT(left: fx, top: r.top, right: fx + c.width(rateText, small) + 2, bottom: r.bottom), small,
               grabber.outputRate == 48000 ? c.p.secondary : c.p.warning)
        if compact {
            let cx = fx + c.width(rateText, small)
            c.text(extra, RECT(left: cx, top: r.top, right: cx + c.width(extra, small) + 2, bottom: r.bottom), small, c.p.muted)
        }
        let deviceHit = RECT(left: room.left, top: r.top + c.s(8), right: fx + figuresW, bottom: r.bottom - c.s(8))
        hit(deviceHit, "device",
            tip: fallback ? "\(grabber.wasapi.chosenDeviceName) isn't connected: playing on the system default until it's back."
                : (grabber.wasapi.chosenDeviceID == nil
                   ? "The output device: the system default, following Windows' setting. Click to choose another."
                   : "The output device chosen for the Grabber. Click to change it."),
            click: { [unowned self] _ in self.outputDeviceMenu(at: POINT(x: deviceHit.left, y: deviceHit.bottom)) })
    }

    func outputDeviceLabel() -> String { grabber.outputDeviceName }

    func interfaceMenu(at pt: POINT) {
        grabber.rescanInterfaces()
        var entries: [MenuEntry] = grabber.interfaces.map { i in
            .item("\(i.name) — \(i.address)" + (i.kind == .wifi ? "  (Wi-Fi)" : ""), checked: i.name == grabber.selectedInterface) {
                [unowned self] in self.grabber.selectedInterface = i.name
            }
        }
        if !entries.isEmpty { entries.append(.separator) }
        entries.append(.item("Rescan interfaces") { [unowned self] in self.grabber.rescanInterfaces() })
        entries.append(.item("Restart discovery") { [unowned self] in self.grabber.refreshDiscovery() })
        popup(entries, at: pt)
    }

    func outputDeviceMenu(at pt: POINT) {
        let devices = WASAPIOutput.renderDevices()
        let chosen = grabber.wasapi.chosenDeviceID
        var entries: [MenuEntry] = [
            .item("System default — \(WASAPIOutput.defaultDeviceName() ?? "none")", checked: chosen == nil) {
                [unowned self] in self.grabber.chooseOutputDevice(nil)
            },
            .separator,
        ]
        for d in devices {
            entries.append(.item("\(d.name)  (\(d.channels) ch)", checked: d.id == chosen) { [unowned self] in
                self.grabber.chooseOutputDevice(d)
            })
        }
        entries.append(.separator)
        entries.append(.item("Open Windows' Sound settings…") { [unowned self] in self.shellOpen("ms-settings:sound") })
        popup(entries, at: pt)
    }

    // MARK: - Banner

    private func drawDanteBanner(_ c: Canvas, _ r: RECT) -> Int32 {
        let text = "\(grabber.danteDevices.count) Dante device(s) found, but none are publishing AES67. In Dante Controller: "
            + "enable AES67 mode on the device, then create a multicast flow with “AES67 flow” ticked — flows can take up "
            + "to 30 s to appear. Dante Virtual Soundcard and Dante Via cannot do AES67 at all."
        let fnt = c.font(10)
        let h = c.wrappedHeight(text, width: r.width - c.s(40), fnt) + c.s(12)
        let band = RECT(left: r.left, top: r.top, right: r.right, bottom: r.top + h)
        let tint = c.p.tint(for: .dante)
        c.fill(band, c.p.window.over(tint, 0.10))
        c.icon("\u{E7BA}", RECT(x: band.left + c.s(10), y: band.top + c.s(5), width: c.s(14), height: c.s(14)), size: 10, tint)
        c.wrapped(text, RECT(left: band.left + c.s(30), top: band.top + c.s(6), right: band.right - c.s(10), bottom: band.bottom), fnt, c.p.muted)
        c.hline(band.bottom, r.left, r.right, c.p.divider)
        return band.bottom + 1
    }

    // MARK: - Source sidebar

    private func drawSourceSidebar(_ c: Canvas, _ r: RECT) {
        c.fill(r, c.p.panel)
        let counts = grabber.sourceCounts
        let total = counts.values.reduce(0, +)
        var y = r.top + c.s(10)
        c.text("Sources", RECT(left: r.left + c.s(16), top: y, right: r.right, bottom: y + c.s(16)), c.font(11, .semibold), c.p.muted)
        y += c.s(20)
        func row(_ kind: DiscoverySource?, _ title: String, count: Int) {
            let selected = grabber.sourceFilter == kind
            let rr = RECT(left: r.left + c.s(6), top: y, right: r.right - c.s(6), bottom: y + c.s(24))
            let key = "src-\(kind?.rawValue ?? "all")"
            if selected { c.round(rr, 5, c.p.label, alpha: 0.09) } else if isHover(key) { c.round(rr, 5, c.p.label, alpha: 0.05) }
            let mark = RECT(x: rr.left + c.s(8), y: rr.top, width: c.s(10), height: rr.height)
            if let kind {
                c.ellipse(RECT(x: mark.left + c.s(1.5), y: (rr.top + rr.bottom) / 2 - c.s(3.5), width: c.s(7), height: c.s(7)),
                          c.p.tint(for: kind.tint))
            } else {
                c.icon("\u{E8A9}", mark, size: 10, c.p.muted)
            }
            let countText = "\(count)"
            let small = c.font(10)
            c.text(countText, RECT(left: rr.right - c.s(40), top: rr.top, right: rr.right - c.s(8), bottom: rr.bottom), small, c.p.muted, align: .right)
            c.text(title, RECT(left: mark.right + c.s(7), top: rr.top, right: rr.right - c.s(36), bottom: rr.bottom),
                   c.font(12, selected ? .semibold : .regular), c.p.text)
            hit(rr, key, tip: kind == nil ? "Every stream found, of every kind." : "Only \(title) streams.") { [unowned self] _ in
                self.grabber.sourceFilter = kind
            }
            y = rr.bottom + c.s(2)
        }
        row(nil, "All streams", count: total)
        for kind in DiscoverySource.sidebarOrder where (counts[kind] ?? 0) > 0 || grabber.sourceFilter == kind {
            row(kind, kind.sidebarName, count: counts[kind] ?? 0)
        }
    }

    /// The same filter as a row above the list (Settings → View), and in the compact window.
    func drawSourceFilterRow(_ c: Canvas, _ r: RECT, compact: Bool) {
        let counts = grabber.sourceCounts
        var items: [(DiscoverySource?, String, Int)] = [(nil, compact ? "All" : "All streams", counts.values.reduce(0, +))]
        for kind in DiscoverySource.sidebarOrder where (counts[kind] ?? 0) > 0 || grabber.sourceFilter == kind {
            items.append((kind, compact ? kind.label : kind.sidebarName, counts[kind] ?? 0))
        }
        var x = r.left
        let size: Double = compact ? 9 : 11
        for (kind, title, count) in items {
            let on = grabber.sourceFilter == kind
            let fnt = c.font(size, on ? .semibold : .regular)
            let countText = compact ? "" : " \(count)"
            let w = c.width(title, fnt) + c.width(countText, c.font(10)) + c.s(compact ? 10 : 16) + (kind != nil && !compact ? c.s(10) : 0)
            guard x + w <= r.right else { break }
            let chip = RECT(x: x, y: r.top, width: w, height: r.height)
            let tint = kind.map { c.p.tint(for: $0.tint) } ?? c.p.secondary
            let key = "chip-\(kind?.rawValue ?? "all")"
            c.round(chip, p(c, compact ? 20 : 5), on ? (compact ? tint : c.p.label) : c.p.label,
                    alpha: on ? (compact ? 0.24 : 0.10) : (isHover(key) ? 0.09 : 0.05))
            var tx = chip.left + c.s(compact ? 5 : 8)
            if let kind, !compact {
                c.ellipse(RECT(x: tx, y: (chip.top + chip.bottom) / 2 - c.s(3), width: c.s(6), height: c.s(6)), c.p.tint(for: kind.tint))
                tx += c.s(10)
            }
            c.text(title, RECT(left: tx, top: chip.top, right: chip.right, bottom: chip.bottom), fnt,
                   on ? (compact ? tint : c.p.text) : (compact ? c.p.muted : c.p.text))
            if !compact {
                let cx = tx + c.width(title, fnt)
                c.text(countText, RECT(left: cx, top: chip.top, right: chip.right, bottom: chip.bottom), c.font(10), c.p.muted)
            }
            hit(chip, key, tip: kind.map { "Only \($0.sidebarName) streams." } ?? "Every stream found, of every kind.") { [unowned self] _ in
                self.grabber.sourceFilter = on && kind != nil ? nil : kind
            }
            x = chip.right + c.s(4)
        }
    }

    private func p(_ c: Canvas, _ fallback: Double) -> Double { c.p.skin.chipRadius ?? fallback }

    // MARK: - The stream list

    private func drawStreamList(_ c: Canvas, _ r: RECT) {
        let pad = c.s(12)
        // The list bar: count, filter, ACTIVE, Connect…, Add stream….
        let bar = RECT(left: r.left + pad, top: r.top + c.s(8), right: r.right - pad, bottom: r.top + c.s(32))
        let titleFont = c.font(12, .semibold)
        c.text("Receive", RECT(left: bar.left, top: bar.top, right: bar.left + c.width("Receive", titleFont) + 2, bottom: bar.bottom),
               titleFont, c.p.muted)
        let countText = grabber.streams.isEmpty ? "none yet" : "\(grabber.subscribed.count) playing of \(grabber.streams.count)"
        let countX = bar.left + c.width("Receive", titleFont) + c.s(8)

        var bx = bar.right
        func barButton(_ title: String, glyph: String, key: String, tip: String, action: @escaping (RECT) -> Void) {
            let fnt = c.font(11)
            let w = c.width(title, fnt) + c.s(30)
            let b = RECT(x: bx - w, y: bar.top + c.s(1), width: w, height: c.s(22))
            c.button("", b, hover: isHover(key))
            c.icon(glyph, RECT(x: b.left + c.s(7), y: b.top, width: c.s(12), height: b.height), size: 10, c.p.secondary)
            c.text(title, RECT(left: b.left + c.s(22), top: b.top, right: b.right, bottom: b.bottom), fnt, c.p.text)
            hit(b, key, tip: tip) { _ in action(b) }
            bx = b.left - c.s(8)
        }
        barButton("SDP Address…", glyph: "\u{E710}", key: "addstream",
                  tip: "Paste a stream's SDP — for a sender that announces nothing.") { [unowned self] _ in self.openAddStream() }
        barButton("Connect / Send…", glyph: "\u{E8EE}", key: "connect",
                  tip: "Receive from Network Audio Sender, or send this PC's audio to other receivers.") { [unowned self] _ in
            self.openConnect(tab: 0)
        }
        // ACTIVE
        let activeW = c.pillWidth("ACTIVE")
        let active = RECT(x: bx - activeW, y: bar.top + c.s(3), width: activeW, height: c.s(18))
        c.pill("ACTIVE", active, on: grabber.showActiveOnly, tint: c.p.active, hover: isHover("activeonly"))
        hit(active, "activeonly", tip: tooltip("Filters the list to the streams you have joined, so a network announcing dozens "
                                               + "of flows stays readable. It changes nothing about what is playing.",
                                               now: grabber.showActiveOnly ? "ON — showing \(grabber.subscribed.count) joined of \(grabber.streams.count) discovered."
                                                   : "Off — showing all \(grabber.streams.count) discovered.")) { [unowned self] _ in
            self.grabber.showActiveOnly.toggle()
        }
        bx = active.left - c.s(6)
        // The filter.
        let filterW = c.s(160)
        let filter = RECT(x: bx - filterW, y: bar.top + c.s(2), width: filterW, height: c.s(20))
        c.round(filter, 10, c.p.label, alpha: 0.06)
        c.icon("\u{E721}", RECT(x: filter.left + c.s(6), y: filter.top, width: c.s(12), height: filter.height), size: 9, c.p.muted)
        let filterText = RECT(left: filter.left + c.s(20), top: filter.top, right: filter.right - c.s(18), bottom: filter.bottom)
        fieldFrames["filter"] = filterText
        if fieldKey != "filter" {
            c.text(grabber.searchText.isEmpty ? "Filter" : grabber.searchText, filterText, c.font(11),
                   grabber.searchText.isEmpty ? c.p.muted : c.p.text)
        }
        hit(filter, "filter", tip: "Filter the list by name, address or source.") { [unowned self] _ in
            self.beginField("filter", frame: filterText, text: self.grabber.searchText) { [unowned self] text in
                self.grabber.searchText = text
            }
        }
        if !grabber.searchText.isEmpty {
            let clear = RECT(x: filter.right - c.s(17), y: filter.top + c.s(3), width: c.s(14), height: c.s(14))
            c.icon("\u{E894}", clear, size: 8, c.p.muted)
            hit(clear, "filterclear", tip: "Clear the filter") { [unowned self] _ in self.cancelField(); self.grabber.searchText = "" }
        }
        c.text(countText, RECT(left: countX, top: bar.top, right: filter.left - c.s(8), bottom: bar.bottom), c.font(11), c.p.muted)

        var y = bar.bottom
        if view.showSourceBar && view.sourceFilterRow {
            drawSourceFilterRow(c, RECT(left: r.left + pad, top: y + c.s(6), right: r.right - pad, bottom: y + c.s(30)), compact: false)
            y += c.s(30)
        }

        // Column titles.
        let titles = RECT(left: r.left + pad, top: y + c.s(8), right: r.right - pad, bottom: y + c.s(8) + c.s(16))
        drawColumnTitles(c, titles)
        y = titles.bottom + c.s(6)
        c.hline(y, r.left, r.right, c.p.divider)
        y += 1

        let visible = grabber.visibleStreams
        let list = RECT(left: r.left, top: y, right: r.right, bottom: r.bottom)
        if visible.isEmpty && grabber.ignoredPresent.isEmpty && grabber.gonePresent.isEmpty {
            if grabber.streams.isEmpty { drawWelcome(c, list) } else { drawPlainEmpty(c, list) }
            return
        }
        // Keep open rows to what is shown.
        let shown = Set(visible.map(\.id))
        if !grabber.openStreamIDs.isSubset(of: shown) { grabber.openStreamIDs.formIntersection(shown) }

        let offset = beginScroll("list", list, c)
        var ry = list.top - offset
        for (i, stream) in visible.enumerated() {
            let h = rowHeight(c, stream)
            let rr = RECT(left: list.left, top: ry, right: list.right, bottom: ry + h)
            if rr.bottom > list.top && rr.top < list.bottom { drawRow(c, rr, stream.description) }
            ry = rr.bottom
            let nextOpen = i + 1 < visible.count && grabber.isOpen(visible[i + 1].id)
            if grabber.isOpen(stream.id) || nextOpen {
                c.hline(ry, list.left, list.right, c.p.hairline)
                ry += c.s(6)
                c.hline(ry, list.left, list.right, c.p.hairline)
                ry += 1
            } else {
                c.hline(ry, list.left, list.right, c.p.hairline)
                ry += 1
            }
        }
        if !grabber.gonePresent.isEmpty { ry = drawGone(c, RECT(left: list.left, top: ry, right: list.right, bottom: ry)) }
        if !grabber.ignoredPresent.isEmpty { ry = drawIgnored(c, RECT(left: list.left, top: ry, right: list.right, bottom: ry)) }
        endScroll("list", content: ry - (list.top - offset), c)
    }

    /// Everything in a row that is not the Stream column: the padding, star, play, the controls,
    /// the chips, the status, jitter in Detailed, the chevron, and the gaps between them.
    func listFixedWidth(_ c: Canvas) -> Int32 {
        let gap = c.s(7)
        var w = c.s(12) * 2 + c.s(Column.star) + c.s(Column.play) + gap * 2
        w += gap + c.s(Column.controls) + gap + c.s(Column.chips) + gap + c.s(Column.status) + gap + c.s(15)
        if grabber.detailed { w += c.s(Column.jitter) + gap }
        return w
    }

    private func drawColumnTitles(_ c: Canvas, _ r: RECT) {
        let fnt = c.font(11, .medium)
        let gap = c.s(7)
        var right = r.right - c.s(15) - gap
        func column(_ title: String, _ width: Double, align: Canvas.Align = .left, inset: Double = 0) {
            let w = c.s(width)
            let rr = RECT(left: right - w, top: r.top, right: right, bottom: r.bottom)
            c.text(title, RECT(left: rr.left + c.s(inset), top: rr.top, right: rr.right, bottom: rr.bottom), fnt, c.p.muted, align: align)
            right = rr.left - gap
        }
        if grabber.detailed { column("Jitter", Column.jitter, align: .right) }
        column("Status", Column.status)
        column("Source", Column.chips)
        // The controls block, in the Mac's order: Level, Bus, Trim, M / S.
        let block = RECT(left: right - c.s(Column.controls), top: r.top, right: right, bottom: r.bottom)
        var x = block.left
        for (title, w) in [("Level", Column.meter), ("Bus", Column.mix), ("Trim", Column.trim + 7 + Column.gain), ("M / S", Column.states)] {
            c.text(title, RECT(left: x + (title == "Trim" ? c.s(7) : 0), top: r.top, right: x + c.s(w), bottom: r.bottom), fnt, c.p.muted)
            x += c.s(w) + gap
        }
        let nameLeft = r.left + c.s(Column.star + Column.play) + gap * 2
        c.text("Stream", RECT(left: nameLeft, top: r.top, right: block.left - gap, bottom: r.bottom), fnt, c.p.muted)
        // The Stream column's edge, dragged to give names more room: the signal panel, then the
        // sidebar, make way. Double-click to let it take only what is left again.
        let edge = block.left - gap / 2
        var window = RECT()
        if let h = current.hwnd { GetClientRect(h, &window) }
        let dragging = isHover("split-stream") || current.dragging?.key == "split-stream"
        c.vline(edge, r.top - c.s(dragging ? 2 : -2), r.bottom + c.s(dragging ? 4 : -1), dragging ? c.p.active : c.p.divider)
        sliderHit(RECT(left: edge - c.s(4), top: r.top - c.s(4), right: edge + c.s(4), bottom: r.bottom + c.s(6)), track: window, "split-stream",
                  tip: "Drag to make the Stream column wider: the signal panel, then the sidebar, make room. Double-click to undo.",
                  set: { [unowned self] f in
                      let x = Int32(Double(window.width) * f)
                      self.view.streamWidth = max(80, c.pt(x - nameLeft))
                  }, reset: { [unowned self] in self.view.streamWidth = 0 })
    }

    // MARK: Rows

    func rowHeight(_ c: Canvas, _ stream: DiscoveredStream) -> Int32 {
        var h = c.s(Column.rowHeight)
        let active = grabber.isSubscribed(stream.id)
        if active && grabber.isOpen(stream.id) { h += detailHeight(c, stream.description) }
        if !active, grabber.joinFailures[stream.id] != nil { h += c.s(40) }
        return h
    }

    private func drawRow(_ c: Canvas, _ r: RECT, _ d: StreamDescription) {
        let id = d.id
        let active = grabber.isSubscribed(id)
        let open = grabber.isOpen(id)
        if open { c.fill(r, c.p.fill(0.06)) }
        let line = RECT(left: r.left + c.s(12), top: r.top, right: r.right - c.s(12), bottom: r.top + c.s(Column.rowHeight))
        let cy = (line.top + line.bottom) / 2
        let gap = c.s(7)
        let favourite = grabber.favourites.contains(id)

        // Right-click anywhere on the row: the Mac's context menu.
        hit(RECT(left: r.left, top: r.top, right: r.right, bottom: line.bottom), "row-\(id)",
            right: { [unowned self] pt in self.rowContextMenu(d, at: pt) })

        // Star.
        let star = RECT(x: line.left, y: line.top, width: c.s(Column.star), height: line.height)
        c.icon(favourite ? "\u{E735}" : "\u{E734}", star, size: 10,
               favourite ? Colour(1, 0.8, 0) : c.p.secondary.over(c.p.window, isHover("fav-\(id)") ? 0 : 0.45))
        hit(star, "fav-\(id)", tip: "Favourite") { [unowned self] _ in self.grabber.toggleFavourite(id) }

        // Play / stop.
        let play = RECT(x: star.right + gap + (c.s(Column.play) - c.s(18)) / 2, y: cy - c.s(9), width: c.s(18), height: c.s(18))
        c.playStop(play, active: active, hover: isHover("play-\(id)"))
        hit(RECT(x: star.right + gap, y: line.top, width: c.s(Column.play), height: line.height), "play-\(id)",
            tip: active ? "Stop listening" : "Listen") { [unowned self] _ in self.togglePlay(d) }

        // From the right: chevron, jitter, status, chips, controls.
        var right = line.right
        let chevron = RECT(left: right - c.s(15), top: line.top, right: right, bottom: line.bottom)
        if active {
            c.chevron(chevron, down: open, colour: c.p.muted, size: 9)
            hit(chevron, "open-\(id)", tip: open ? "Hide this stream's detail" : "Show this stream's detail") { [unowned self] _ in
                self.grabber.toggleOpen(id)
            }
        }
        right = chevron.left - gap
        if grabber.detailed {
            let jr = RECT(left: right - c.s(Column.jitter), top: line.top, right: right, bottom: line.bottom)
            if active, let f = grabber.figures(id) {
                c.text(String(format: "%.2f ms", f.jitterMs), jr, c.font(10), grabber.jitterIsNotable(f, for: d) ? c.p.warning : c.p.secondary,
                       align: .right)
            }
            right = jr.left - gap
        }
        let statusRect = RECT(left: right - c.s(Column.status), top: line.top, right: right, bottom: line.bottom)
        drawStatus(c, statusRect, d, active: active)
        right = statusRect.left - gap
        let chips = RECT(left: right - c.s(Column.chips), top: line.top, right: right, bottom: line.bottom)
        var chipX = chips.left
        let sourceW = c.chip(d.source.label, x: chipX, centreY: cy, tint: c.p.tint(for: d.source.tint), filled: true)
        if let note = sapNote(d) { hit(RECT(x: chipX, y: cy - c.s(8), width: sourceW, height: c.s(16)), "srcchip-\(id)", tip: note) }
        chipX += sourceW + c.s(4)
        _ = c.chip("\(d.channels) ch", x: chipX, centreY: cy, tint: c.p.secondary)
        right = chips.left - gap
        let block = RECT(left: right - c.s(Column.controls), top: line.top, right: right, bottom: line.bottom)
        if active { drawRowControls(c, block, d) }

        // The name, and its badges.
        let nameRect = RECT(left: play.right + gap + (c.s(Column.play) - c.s(18)) / 2, top: line.top, right: block.left - gap, bottom: line.bottom)
        // Bold while playing, as the Mac's list.
        let nameFont = c.font(13, active ? .bold : .regular)
        var badges: [(String, Colour, Bool)] = []
        if active, grabber.hasChannelSolo(id) {
            let names = grabber.channelLabels(for: d, folded: true)
            let text = grabber.soloedChannels(id).sorted().map { $0 < names.count ? names[$0] : "\($0 + 1)" }.joined(separator: " ")
            badges.append(("S " + text, c.p.solo, true))
        }
        // Where it comes from (`ConnectionBadge`): a VBAN stream says local, VPN or remote;
        // anything else only when it is remote.
        if d.source == .vban {
            if RemoteAddresses.isRemote(d.originAddress) {
                let enc = grabber.isEncryptedLink(d)
                badges.append((enc ? "REMOTE · ENCRYPTED" : "REMOTE · NOT ENCRYPTED", enc ? c.p.text : c.p.warning, false))
            } else if RemoteAddresses.isVPN(d.originAddress) {
                badges.append(("VPN", c.p.secondary, false))
            } else {
                badges.append(("LOCAL", c.p.secondary, false))
            }
        } else if d.source != .web, RemoteAddresses.isRemote(d.originAddress) {
            badges.append(("REMOTE · NOT ENCRYPTED", c.p.warning, false))
        }
        let badgeFont = c.font(8, .bold)
        // LOCAL carries the Mac's house icon.
        let house = "\u{E80F}", houseW = c.s(11)
        let badgesW = badges.reduce(Int32(0)) { $0 + c.width($1.0, badgeFont) + c.s(16) + ($1.0 == "LOCAL" ? houseW : 0) }
        let nameW = min(c.width(d.name, nameFont), max(c.s(30), nameRect.width - badgesW))
        c.text(d.name, RECT(left: nameRect.left, top: line.top, right: nameRect.left + nameW + 1, bottom: line.bottom), nameFont, c.p.text, middle: true)
        var bxp = nameRect.left + nameW + c.s(6)
        for (text, tint, solo) in badges where bxp < nameRect.right {
            let glyph = text == "LOCAL"
            let w = c.width(text, badgeFont) + c.s(10) + (glyph ? houseW : 0)
            let b = RECT(x: bxp, y: cy - c.s(7), width: w, height: c.s(14))
            if solo { c.round(b, 7, nil, border: tint, borderWidth: 1) } else { c.round(b, 7, c.p.label, alpha: 0.07) }
            if glyph {
                c.icon(house, RECT(x: b.left + c.s(4), y: b.top, width: houseW, height: b.height), size: 8, tint)
                c.text(text, RECT(left: b.left + c.s(3) + houseW, top: b.top, right: b.right, bottom: b.bottom), badgeFont, tint, align: .centre)
            } else {
                c.text(text, b, badgeFont, solo ? c.p.soloText : tint, align: .centre)
            }
            bxp = b.right + c.s(4)
        }
        let nowPlaying = grabber.nowPlaying[id]
        hit(nameRect, "name-\(id)",
            tip: nowPlaying.map { "Now playing: \($0)" }
                ?? ([.vban, .scream].contains(d.source) ? "\(d.name), from \(d.originAddress)"
                    : sapNote(d).map { "\(d.name)\n\n\($0)" } ?? d.name),
            right: { [unowned self] pt in self.rowContextMenu(d, at: pt) },
            click: { [unowned self] _ in if active { self.grabber.toggleOpen(id) } })

        var y = line.bottom
        if active && open {
            drawDetail(c, RECT(left: r.left, top: y, right: r.right, bottom: r.bottom), d)
        } else if !active, let reason = grabber.joinFailures[id] {
            let box = RECT(left: r.left + c.s(12 + 12 + 7 + 20 + 7), top: y, right: r.right - c.s(12), bottom: y + c.s(32))
            c.round(box, 6, c.p.red, alpha: 0.10, border: c.p.red, borderAlpha: 0.35)
            c.icon("\u{EA39}", RECT(x: box.left + c.s(8), y: box.top, width: c.s(14), height: box.height), size: 11, c.p.red)
            let tryW = c.buttonWidth("Try again")
            let again = RECT(x: box.right - c.s(8) - tryW, y: box.top + c.s(6), width: tryW, height: c.s(20))
            c.button("Try again", again, hover: isHover("retry-\(id)"))
            hit(again, "retry-\(id)") { [unowned self] _ in self.grabber.toggle(d) }
            c.text(reason, RECT(left: box.left + c.s(28), top: box.top, right: again.left - c.s(8), bottom: box.bottom), c.font(11), c.p.text)
            y = box.bottom + c.s(8)
        }
    }

    func togglePlay(_ d: StreamDescription) {
        grabber.toggle(d)
        // Joining opens the row only when no other is open; stopping closes it (the Mac's rule).
        if grabber.isSubscribed(d.id) {
            if grabber.openStreamIDs.isEmpty { grabber.openStreamIDs.insert(d.id) }
        } else { grabber.openStreamIDs.remove(d.id) }
    }

    private func drawStatus(_ c: Canvas, _ r: RECT, _ d: StreamDescription, active: Bool) {
        let id = d.id
        var label: (String, String, Colour, String)?
        if !active, let failure = grabber.joinFailures[id] {
            label = ("Can't join", "\u{EA39}", c.p.red, failure)
        } else if let approval = grabber.vbanApprovals[id] {
            label = approval == .waiting
                ? ("Asking…", "\u{E823}", c.p.warning, "The Sender's user has been asked to allow this Grabber. It plays as soon as they do.")
                : ("Declined", "\u{E711}", c.p.red, "The Sender's user declined this Grabber. It can be allowed again after the Sender is reopened.")
        } else if !active, let note = grabber.autoStopNote(id) {
            label = ("Timed out", "\u{E916}", c.p.warning, note)
        } else if active {
            let receiving = grabber.isReceiving(id)
            label = receiving ? ("OK", "\u{E73E}", c.p.secondary, "Receiving")
                : grabber.isGone(id) ? ("Gone", "\u{E708}", c.p.muted, "The sender has left: no audio and no announcement for a while. It plays again if it comes back.")
                : ("No packets", "\u{E7BA}", c.p.warning, "No packets arriving")
        }
        guard let (text, glyph, colour, tip) = label else { return }
        c.icon(glyph, RECT(x: r.left, y: r.top, width: c.s(14), height: r.height), size: 10, colour)
        c.text(text, RECT(left: r.left + c.s(18), top: r.top, right: r.right, bottom: r.bottom), c.font(11), colour)
        hit(r, "status-\(id)", tip: tip)
    }

    /// Level, bus, trim and its figure, M and S — the playing row's controls.
    private func drawRowControls(_ c: Canvas, _ block: RECT, _ d: StreamDescription) {
        let id = d.id
        let gap = c.s(7)
        let cy = (block.top + block.bottom) / 2
        var x = block.left
        // Every channel, one hairline each, before the fold-down.
        let meter = RECT(x: x, y: block.top, width: c.s(Column.meter), height: block.height)
        drawRowMeters(c, meter, d, length: Column.meter)
        x = meter.right + gap
        // The bus (mix) menu.
        let mixRect = RECT(x: x, y: block.top, width: c.s(Column.mix), height: block.height)
        let mixLabel = Downmix.label(for: grabber.mixMode(for: id), channels: d.channels)
        let ml = c.menuLabel(mixLabel, x: mixRect.left, mixRect, size: 10, colour: isHover("mix-\(id)") ? c.p.text : c.p.active)
        hit(RECT(left: ml.left, top: block.top + c.s(5), right: max(ml.right, mixRect.right), bottom: block.bottom - c.s(5)), "mix-\(id)",
            tip: tooltip("How this stream reaches the monitor bus, and the channel order it is read in. Nothing in the stream declares "
                         + "that order, so it is an assumption you can change.",
                         now: "\(mixLabel) · \(grabber.channelOrder(for: id).name)")) { [unowned self] _ in
            self.mixMenu(d, at: POINT(x: mixRect.left, y: block.bottom))
        }
        x = mixRect.right + gap
        // Trim: 0 to +3.5 dB, linear in gain as the Mac's (0…1.5).
        let trim = RECT(x: x, y: cy - c.s(8), width: c.s(Column.trim), height: c.s(16))
        let gain = grabber.gain(for: id)
        c.slider(trim.inset(by: 0), fraction: Double(gain) / 1.5, mini: true)
        sliderHit(RECT(left: trim.left - c.s(4), top: block.top, right: trim.right + c.s(4), bottom: block.bottom), track: trim, "trim-\(id)",
                  tip: "Trim for this stream. Double-click to return it to 0 dB.",
                  set: { [unowned self] f in self.grabber.setGain(id, Float(f * 1.5)) },
                  reset: { [unowned self] in self.grabber.setGain(id, 1) })
        x = trim.right + gap
        let gainText = gain <= 0.0001 ? "−∞" : String(format: "%+.1f", 20 * log10(Double(gain))).replacingOccurrences(of: "-", with: "−")
        c.text(gainText, RECT(x: x, y: block.top, width: c.s(Column.gain), height: block.height), c.font(11), c.p.muted)
        x += c.s(Column.gain) + gap
        // M and S.
        let pw = c.s(24)
        let m = RECT(x: x, y: cy - c.s(9), width: pw, height: c.s(18))
        let s = RECT(x: m.right + c.s(3), y: m.top, width: pw, height: m.height)
        c.pill("M", m, on: grabber.isMuted(id), tint: c.p.mute, hover: isHover("m-\(id)"))
        c.pill("S", s, on: grabber.soloed == id, tint: c.p.solo, hover: isHover("s-\(id)"))
        hit(m, "m-\(id)", tip: "Mute this stream") { [unowned self] _ in self.grabber.toggleMute(id) }
        hit(s, "s-\(id)", tip: "Listen to this stream alone") { [unowned self] _ in self.grabber.toggleSolo(id) }
    }

    /// One hairline a channel (`RowChannelMeters`), grey when out of circuit, outlined red when muted.
    func drawRowMeters(_ c: Canvas, _ r: RECT, _ d: StreamDescription, length: Double, slim: Bool = false) {
        let n = d.channels
        let thickness: Double = slim ? (n <= 2 ? 3 : 1) : (n <= 2 ? 3 : (n <= 8 ? 2 : 1))
        let slot: Double = slim ? (n <= 2 ? 4 : (n <= 8 ? 2 : 1)) : (n <= 2 ? 5 : (n <= 8 ? 3 : 1))
        let total = c.s(slot * Double(n))
        let cy = (r.top + r.bottom) / 2
        let area = RECT(left: r.left + c.s(3), top: cy - total / 2, right: r.left + c.s(3) + c.s(length) - c.s(6), bottom: cy - total / 2 + total)
        let silenced = grabber.isMuted(d.id) || (grabber.soloed != nil && grabber.soloed != d.id)
        let solo = grabber.soloedChannels(d.id)
        let noData = !(grabber.health[d.id]?.receiving ?? false)
        for ch in 0..<n {
            let y = area.top + c.s(slot * Double(ch))
            let bar = RECT(left: area.left, top: y, right: area.right, bottom: y + max(1, c.s(thickness)))
            c.bar(bar, level: grabber.channelPeak(d.id, ch), vertical: false,
                  dimmed: silenced || (!solo.isEmpty && !solo.contains(ch)), trackless: true, noData: noData && ch == 0)
        }
        if grabber.isMuted(d.id) {
            c.round(RECT(left: area.left - c.s(3), top: area.top - c.s(3), right: area.right + c.s(3), bottom: area.bottom + c.s(3)), 3, nil,
                    border: c.p.red, borderAlpha: 0.55, borderWidth: 1.5)
        }
    }

    func mixMenu(_ d: StreamDescription, at pt: POINT) {
        let id = d.id
        let layout = SMPTELayout.forChannelCount(d.channels)
        let current = grabber.mixMode(for: id)
        var entries: [MenuEntry] = []
        if grabber.busChannels > 2 {
            let reaches = min(d.channels, grabber.busChannels)
            entries.append(.item("\(Downmix.label(for: .passthrough, channels: d.channels)) — channels 1–\(reaches) straight out",
                                 checked: current == .passthrough) { [unowned self] in self.grabber.setMixMode(id, .passthrough) })
            entries.append(.separator)
        }
        if let layout, layout.foldsDown {
            entries.append(.item("Fold \(layout.rawValue) → 2.0 (assumes SMPTE order)", checked: current == .downmix) { [unowned self] in
                self.grabber.setMixMode(id, .downmix)
            })
            entries.append(.separator)
        }
        for start in stride(from: 0, to: d.channels, by: 2) {
            entries.append(.item(Downmix.label(for: .pair(start), channels: d.channels), checked: current == .pair(start)) { [unowned self] in
                self.grabber.setMixMode(id, .pair(start))
            })
        }
        if ChannelOrder.smpte.roles(channels: d.channels).count > 2 {
            entries.append(.separator)
            var orders: [MenuEntry] = [.item("Default (\(grabber.channelOrder.name))", checked: !grabber.hasOwnChannelOrder(id)) {
                [unowned self] in self.grabber.setChannelOrder(id, nil)
            }, .separator]
            for order in ChannelOrder.allCases {
                orders.append(.item(order.menuLabel(channels: d.channels),
                                    checked: grabber.hasOwnChannelOrder(id) && grabber.channelOrder(for: id) == order) { [unowned self] in
                    self.grabber.setChannelOrder(id, order)
                })
            }
            entries.append(.submenu("Channel order", orders))
        }
        if d.channels > 1 {
            entries.append(.separator)
            let names = layout?.channelNames ?? []
            entries.append(.submenu("Single channel", (0..<d.channels).map { ch in
                .item(ch < names.count ? "Ch \(ch + 1) — \(names[ch])" : "Ch \(ch + 1)", checked: current == .mono(ch)) {
                    [unowned self] in self.grabber.setMixMode(id, .mono(ch))
                }
            }))
        }
        popup(entries, at: pt)
    }

    func rowContextMenu(_ d: StreamDescription, at pt: POINT) {
        let id = d.id
        var entries: [MenuEntry] = [
            .item(grabber.favourites.contains(id) ? "Remove from favourites" : "Add to favourites") { [unowned self] in
                self.grabber.toggleFavourite(id)
            },
        ]
        if !d.rawSDP.isEmpty { entries.append(.item("Copy SDP") { [unowned self] in self.copyToClipboard(d.rawSDP) }) }
        entries.append(.item("Copy address") { [unowned self] in
            self.copyToClipboard(d.source == .web ? d.groupAddress : "\(d.groupAddress):\(d.port)")
        })
        entries.append(.separator)
        entries.append(.item("Ignore this stream") { [unowned self] in self.grabber.ignore(id) })
        if d.source == .manual {
            entries.append(.separator)
            entries.append(.item("Remove from the list") { [unowned self] in self.grabber.removeManualStream(id) })
        }
        popup(entries, at: pt)
    }

    // MARK: The open row's detail

    private func meterGeometry(_ c: Canvas, _ d: StreamDescription, labels: [String]) -> (bar: Double, slot: Double, rows: Int, showLabels: Bool) {
        let showLabels = d.channels <= 8
        let bar: Double = d.channels > 8 ? 5 : 8
        let longest = labels.prefix(d.channels).map(\.count).max() ?? 1
        let slot = showLabels ? max(bar, Double(longest) * 4.4) + 3 : bar + 3
        return (bar, slot, (d.channels + 15) / 16, showLabels)
    }

    private func detailLabels(_ d: StreamDescription) -> [String] {
        let folded = grabber.mixMode(for: d.id) == .downmix
        return grabber.channelLabels(for: d, folded: folded || grabber.hasChannelSolo(d.id))
    }

    private func figureCells(_ d: StreamDescription) -> [(String, String, Bool)] {
        let id = d.id
        if !grabber.detailed {
            return [(d.source == .vban ? "From" : "Group", "\(d.groupAddress):\(d.port)", false)]
        }
        let f = grabber.figures(id) ?? StreamFigures()
        let h = grabber.health[id]
        let lost = h?.lost ?? 0, under = h?.underruns ?? 0
        var cells: [(String, String, Bool)] = [
            ("Jitter", String(format: "%.2f ms", f.jitterMs), grabber.jitterIsNotable(f, for: d)),
            ("Worst", String(format: "%.2f ms", f.worstJitterMs), grabber.jitterIsNotable(f, for: d)),
            ("Buffer", String(format: "%.0f ms", f.bufferMs), false),
            ("Low water", String(format: "%.0f ms", f.minBufferMs), false),
            ("Drift", String(format: "%+.0f ppm", f.driftPPM).replacingOccurrences(of: "-", with: "−"), false),
            ("Lost", "\(lost)", lost > 0),
            ("Underruns", "\(under)", under > 0),
            ("Last underrun", ago(h?.lastUnderrun), false),
            ("Packets", "\(f.packets)", false),
            ("Clock", d.ptpRef ?? d.latencyClass.clockLabel, false),
        ]
        if [.vban, .scream].contains(d.source) { cells.append(("From", d.originAddress, false)) }
        return cells
    }

    func ago(_ date: Date?) -> String {
        guard let date else { return "—" }
        let s = max(0, Int(Date().timeIntervalSince(date)))
        if s < 60 { return "\(s) s ago" }
        if s < 3600 { return "\(s / 60) min ago" }
        return "\(s / 3600) h ago"
    }

    /// Under an SAP stream while Dante devices is off: why it may be a Dante stream labelled SAP,
    /// which the Mac labels Dante when Dante devices are on.
    func sapNote(_ d: StreamDescription) -> String? {
        guard d.source == .sap, !grabber.danteEnabled else { return nil }
        return "Announced over SAP. If it comes from a Dante device, turn on Dante devices in Settings → Discovery to label it."
    }

    func detailHeight(_ c: Canvas, _ d: StreamDescription) -> Int32 {
        let g = meterGeometry(c, d, labels: detailLabels(d))
        let meters = Int32(g.rows) * (c.s(46) + (g.showLabels ? c.s(12) : 0)) + Int32(max(0, g.rows - 1)) * c.s(4) + c.s(8)
        let cells = figureCells(d).count
        let columns = 4
        let rows = max(1, (cells + columns - 1) / columns)
        let right = c.s(14) + c.s(9) + Int32(rows) * c.s(30) + Int32(rows - 1) * c.s(7) + (sapNote(d) == nil ? 0 : c.s(34))
        return c.s(4) + max(meters, right) + c.s(7) + c.s(18) + c.s(10)
    }

    private func drawDetail(_ c: Canvas, _ r: RECT, _ d: StreamDescription) {
        let id = d.id
        let labels = detailLabels(d)
        let g = meterGeometry(c, d, labels: labels)
        let silenced = grabber.isMuted(id) || (grabber.soloed != nil && grabber.soloed != id)
        let solo = grabber.soloedChannels(id)
        let noData = !(grabber.health[id]?.receiving ?? false)
        let left = r.left + c.s(12)
        var y = r.top + c.s(4) + c.s(4)
        let perRow = 16
        var metersRight = left
        for row in 0..<g.rows {
            let first = row * perRow, last = min(d.channels, first + perRow)
            var x = left + c.s(4)
            for ch in first..<last {
                let slot = RECT(x: x, y: y, width: c.s(g.slot), height: c.s(46))
                let bar = RECT(x: slot.left + (slot.width - c.s(g.bar)) / 2, y: y, width: c.s(g.bar), height: c.s(46))
                let lit = !silenced && (solo.isEmpty || solo.contains(ch))
                c.bar(bar, level: grabber.channelPeak(id, ch), vertical: true, dimmed: !lit, noData: false)
                if noData { c.hline(bar.bottom - 1, bar.left, bar.right, c.p.secondary) }
                if g.showLabels {
                    let lr = RECT(x: slot.left - c.s(2), y: bar.bottom + c.s(2), width: slot.width + c.s(4), height: c.s(10))
                    let highlighted = !silenced && solo.contains(ch)
                    if highlighted { c.round(lr.inset(by: c.s(1)), 2, c.p.solo) }
                    c.text(ch < labels.count ? labels[ch] : "\(ch + 1)", lr, c.font(7, .semibold),
                           highlighted ? c.p.solo.readable : (lit ? c.p.muted : c.p.muted.over(c.p.window, 0.5)), align: .centre)
                }
                x = slot.right
            }
            metersRight = max(metersRight, x + c.s(4))
            y += c.s(46) + (g.showLabels ? c.s(12) : 0) + c.s(4)
        }
        if grabber.isMuted(id) {
            c.round(RECT(left: left, top: r.top + c.s(4), right: metersRight, bottom: y), 4, nil, border: c.p.red, borderAlpha: 0.55, borderWidth: 1.5)
        }

        // The right-hand column: what is assumed, then the figures.
        let colLeft = metersRight + c.s(18)
        let colRight = r.right - c.s(12)
        var cy = r.top + c.s(4)
        var cx = colLeft
        if grabber.hasOwnChannelOrder(id) {
            cx += c.chip(grabber.channelOrder(for: id).name, x: cx, centreY: cy + c.s(7), tint: c.p.warning) + c.s(8)
        }
        let caption = grabber.mixCaption(for: d)
        let soloing = grabber.hasChannelSolo(id)
        let capFont = c.font(9, soloing ? .bold : .regular)
        let capW = c.width(caption, capFont) + c.s(8)
        let capRect = RECT(x: cx, y: cy, width: min(capW, colRight - cx), height: c.s(14))
        if soloing { c.round(capRect, 3, c.p.solo) }
        c.text(caption, capRect, capFont, soloing ? c.p.solo.readable : c.p.muted, align: .centre)
        cy += c.s(14) + c.s(9)
        let cells = figureCells(d)
        let columns = 4
        let cellW = (colRight - colLeft - c.s(8) * Int32(columns - 1)) / Int32(columns)
        for (i, cell) in cells.enumerated() {
            let col = i % columns, row = i / columns
            let cr = RECT(x: colLeft + Int32(col) * (cellW + c.s(8)), y: cy + Int32(row) * c.s(37), width: cellW, height: c.s(30))
            c.text(cell.0, RECT(left: cr.left, top: cr.top, right: cr.right, bottom: cr.top + c.s(14)), c.font(10), c.p.muted)
            c.text(cell.1, RECT(left: cr.left, top: cr.top + c.s(14), right: cr.right, bottom: cr.bottom), c.font(12),
                   cell.2 ? c.p.warning : c.p.secondary, middle: true)
            hit(cr, "cell-\(id)-\(i)", tip: cell.1)
        }
        if let note = sapNote(d) {
            let rows = Int32((cells.count + columns - 1) / columns)
            let ny = cy + rows * c.s(37)
            c.wrapped(note, RECT(left: colLeft, top: ny, right: colRight, bottom: ny + c.s(30)), c.font(10), c.p.muted)
        }

        // The channel solo row, across the block.
        let soloY = r.bottom - c.s(10) - c.s(18)
        var sx = left
        let soloFont = c.font(11, .medium)
        c.text("Solo", RECT(left: sx, top: soloY, right: sx + c.width("Solo", soloFont) + 2, bottom: soloY + c.s(18)), soloFont, c.p.muted)
        hit(RECT(left: sx, top: soloY, right: sx + c.width("Solo", soloFont), bottom: soloY + c.s(18)), "solotitle-\(id)",
            tip: "Monitor these channels on their own, in their fold-down positions")
        sx += c.width("Solo", soloFont) + c.s(6)
        let layout = SMPTELayout.forChannelCount(d.channels)
        let names = layout?.channelNames ?? (1...max(1, d.channels)).map(String.init)
        for ch in 0..<d.channels {
            let on = solo.contains(ch)
            let title = ch < names.count ? names[ch] : "\(ch + 1)"
            let fnt = c.font(9, on ? .bold : .regular)
            let w = c.width(title, fnt) + c.s(8)
            guard sx + w < colRight - c.s(120) else { break }
            let b = RECT(x: sx, y: soloY + c.s(2), width: w, height: c.s(14))
            c.round(b, 4, on ? c.p.solo : c.p.label, alpha: on ? 0.85 : (isHover("chsolo-\(id)-\(ch)") ? 0.14 : 0.07))
            c.text(title, b, fnt, on ? c.p.solo.readable : c.p.secondary, align: .centre)
            hit(b, "chsolo-\(id)-\(ch)") { [unowned self] _ in self.grabber.toggleChannelSolo(id, ch) }
            sx = b.right + c.s(4)
        }
        let groups: [(String, [String])]
        switch layout {
        case .quad?: groups = [("Front", ["L", "R"]), ("Rears", ["Ls", "Rs"])]
        case .surround51?: groups = [("Front", ["L", "R", "C"]), ("Rears", ["Ls", "Rs"])]
        case .surround71?: groups = [("Front", ["L", "R", "C"]), ("Sides", ["Lss", "Rss"]), ("Rears", ["Lrs", "Rrs"])]
        default: groups = []
        }
        for (title, members) in groups {
            let fnt = c.font(9)
            let w = c.width(title, fnt) + c.s(4)
            let b = RECT(x: sx, y: soloY, width: w, height: c.s(18))
            c.text(title, b, fnt, isHover("group-\(id)-\(title)") ? c.p.text : c.p.muted, align: .centre)
            hit(b, "group-\(id)-\(title)", tip: "Solo \(members.joined(separator: " "))") { [unowned self] _ in
                self.grabber.soloChannels(id, named: members)
            }
            sx = b.right + c.s(4)
        }
        if !solo.isEmpty {
            let fnt = c.font(11, .medium)
            let w = c.width("Clear", fnt)
            let b = RECT(x: colRight - w, y: soloY, width: w, height: c.s(18))
            c.text("Clear", b, fnt, c.p.active)
            hit(b, "chsoloclear-\(id)") { [unowned self] _ in self.grabber.clearChannelSolo(id) }
        }
    }

    // MARK: Gone, Ignored, empty states

    /// Playing streams whose sender has left (the Mac's `GoneSection`): no audio and no
    /// announcement for a while. Under the list, above Ignored. Each is still joined and plays again
    /// if it comes back; left alone it stops by itself after five minutes, except one added by hand.
    private func drawGone(_ c: Canvas, _ r: RECT) -> Int32 {
        let gone = grabber.gonePresent
        var y = r.top
        let head = RECT(left: r.left + c.s(12), top: y, right: r.right - c.s(12), bottom: y + c.s(30))
        let cw = c.buttonWidth("Clear all")
        let clear = RECT(x: head.right - cw, y: head.top + c.s(5), width: cw, height: c.s(20))
        c.button("Clear all", clear, hover: isHover("goneclear"))
        hit(clear, "goneclear", tip: "Stop every gone stream and take it off the list.") { [unowned self] _ in self.grabber.clearGone() }
        let fold = RECT(left: head.left, top: head.top, right: clear.left - c.s(8), bottom: head.bottom)
        c.chevron(RECT(x: fold.left, y: fold.top, width: c.s(8), height: fold.height), down: grabber.goneOpen, colour: c.p.muted)
        c.text("Gone  \(gone.count)", RECT(left: fold.left + c.s(14), top: fold.top, right: fold.right, bottom: fold.bottom),
               c.font(11, .medium), c.p.muted)
        hit(fold, "gonehead", tip: "Streams that were playing and whose sender has left: no audio and no announcement "
            + "for a while. Each plays again if it comes back, and stops by itself after five minutes.") { [unowned self] _ in
            self.grabber.goneOpen.toggle()
        }
        y = head.bottom
        if grabber.goneOpen {
            for stream in gone {
                let id = stream.id
                let rr = RECT(left: r.left + c.s(12 + 12 + 7 + 20 + 7), top: y, right: r.right - c.s(12), bottom: y + c.s(28))
                let bw = c.buttonWidth("Stop")
                let b = RECT(x: rr.right - bw, y: rr.top + c.s(4), width: bw, height: c.s(20))
                c.button("Stop", b, hover: isHover("gonestop-\(id)"))
                hit(b, "gonestop-\(id)", tip: "Stop it and take it off the list. It is listed again if it comes back.") { [unowned self] _ in
                    self.grabber.stopGone(id)
                }
                let goneW = c.width("Gone", c.font(11)) + c.s(18)
                let nameW = min(c.width(stream.description.name, c.font(12)), b.left - rr.left - c.s(90) - goneW)
                c.text(stream.description.name, RECT(left: rr.left, top: rr.top, right: rr.left + nameW + 2, bottom: rr.bottom), c.font(12), c.p.muted)
                let chipLeft = rr.left + nameW + c.s(8)
                let chipRight = chipLeft + c.chip(stream.description.source.label, x: chipLeft, centreY: (rr.top + rr.bottom) / 2,
                                                  tint: c.p.tint(for: stream.description.source.tint), filled: true)
                let g = RECT(left: chipRight + c.s(8), top: rr.top, right: chipRight + c.s(8) + goneW, bottom: rr.bottom)
                c.icon("\u{E708}", RECT(x: g.left, y: g.top, width: c.s(14), height: g.height), size: 10, c.p.muted)
                c.text("Gone", RECT(left: g.left + c.s(18), top: g.top, right: g.right, bottom: g.bottom), c.font(11), c.p.muted)
                let rowHit = RECT(left: rr.left, top: rr.top, right: b.left - c.s(4), bottom: rr.bottom)
                hit(rowHit, "gonerow-\(id)", right: { [unowned self] pt in
                    self.popup([
                        .item("Stop and remove") { [unowned self] in self.grabber.stopGone(id) },
                        .item("Ignore this stream") { [unowned self] in self.grabber.ignore(id) },
                        .separator,
                        .item("Clear all gone streams") { [unowned self] in self.grabber.clearGone() },
                    ], at: pt)
                })
                y = rr.bottom
            }
        }
        return y + c.s(8)
    }

    private func drawIgnored(_ c: Canvas, _ r: RECT) -> Int32 {
        let ignored = grabber.ignoredPresent
        var y = r.top
        let head = RECT(left: r.left + c.s(12), top: y, right: r.right - c.s(12), bottom: y + c.s(30))
        c.chevron(RECT(x: head.left, y: head.top, width: c.s(8), height: head.height), down: grabber.ignoredOpen, colour: c.p.muted)
        c.text("Ignored  \(ignored.count)", RECT(left: head.left + c.s(14), top: head.top, right: head.right, bottom: head.bottom),
               c.font(11, .medium), c.p.muted)
        hit(head, "ignoredhead", tip: "Streams you chose to ignore. They are remembered, and not listed with the others.") { [unowned self] _ in
            self.grabber.ignoredOpen.toggle()
        }
        y = head.bottom
        if grabber.ignoredOpen {
            for stream in ignored {
                let rr = RECT(left: r.left + c.s(12 + 12 + 7 + 20 + 7), top: y, right: r.right - c.s(12), bottom: y + c.s(28))
                let bw = c.buttonWidth("Show in list")
                let b = RECT(x: rr.right - bw, y: rr.top + c.s(4), width: bw, height: c.s(20))
                c.button("Show in list", b, hover: isHover("unignore-\(stream.id)"))
                hit(b, "unignore-\(stream.id)") { [unowned self] _ in self.grabber.unignore(stream.id) }
                let nameW = min(c.width(stream.description.name, c.font(12)), b.left - rr.left - c.s(90))
                c.text(stream.description.name, RECT(left: rr.left, top: rr.top, right: rr.left + nameW + 2, bottom: rr.bottom), c.font(12), c.p.muted)
                _ = c.chip(stream.description.source.label, x: rr.left + nameW + c.s(8), centreY: (rr.top + rr.bottom) / 2,
                           tint: c.p.tint(for: stream.description.source.tint), filled: true)
                y = rr.bottom
            }
        }
        return y + c.s(8)
    }

    private func drawPlainEmpty(_ c: Canvas, _ r: RECT) {
        let cy = (r.top + r.bottom) / 2
        c.icon("\u{E71C}", RECT(x: r.left, y: cy - c.s(40), width: r.width, height: c.s(32)), size: 26, c.p.muted)
        c.text("Nothing matches the filter", RECT(x: r.left, y: cy, width: r.width, height: c.s(20)), c.font(13), c.p.muted, align: .centre)
    }

    /// First launch on a quiet network: what the Grabber can pick up and how (the Mac's welcome
    /// guide and `SourcesGuide`).
    private func drawWelcome(_ c: Canvas, _ r: RECT) {
        let offset = beginScroll("welcome", r, c)
        let width = min(c.s(560), r.width - c.s(48))
        let left = r.left + (r.width - width) / 2
        var y = r.top + c.s(24) - offset
        c.text("Listening on \(grabber.selectedInterface)…", RECT(left: left, top: y, right: left + width, bottom: y + c.s(22)),
               c.font(15, .semibold), c.p.text)
        y += c.s(26)
        c.text("Nothing has arrived yet. The Grabber plays these kinds of stream:", RECT(left: left, top: y, right: left + width, bottom: y + c.s(16)),
               c.font(12), c.p.muted)
        y += c.s(18)
        c.text("This list is kept in Settings → Sources.", RECT(left: left, top: y, right: left + width, bottom: y + c.s(16)), c.font(11), c.p.muted)
        y += c.s(34)
        y = drawSourcesGuide(c, RECT(left: left, top: y, right: left + width, bottom: y), icons: true)
        endScroll("welcome", content: y - (r.top - offset) + c.s(24), c)
    }

    /// Every kind the Grabber can receive, with the one control each needs. Returns its bottom.
    func drawSourcesGuide(_ c: Canvas, _ r: RECT, icons: Bool) -> Int32 {
        var y = r.top
        let textLeft = r.left + (icons ? c.s(36) : 0)
        func row(_ glyph: String, _ title: String, _ text: String, toggle: ReferenceWritableKeyPath<WindowsGrabber, Bool>? = nil,
                 beta: Bool = false, buttons: [(String, () -> Void)] = []) {
            if icons { c.icon(glyph, RECT(x: r.left, y: y, width: c.s(24), height: c.s(20)), size: 16, c.p.muted) }
            let tf = c.font(12, .semibold)
            c.text(title, RECT(left: textLeft, top: y, right: textLeft + c.width(title, tf) + 2, bottom: y + c.s(18)), tf, c.p.text)
            var bx = textLeft + c.width(title, tf) + c.s(6)
            if beta { bx += c.betaBadge(x: bx, centreY: y + c.s(9)) }
            if let toggle {
                let sw = RECT(x: r.right - c.s(26), y: y + c.s(2), width: c.s(26), height: c.s(15))
                let on = grabber[keyPath: toggle]
                c.toggleSwitch(sw, on: on)
                hit(sw, "guide-\(title)") { [unowned self] _ in self.grabber[keyPath: toggle].toggle() }
            }
            y += c.s(20)
            y += c.wrapped(text, RECT(left: textLeft, top: y, right: r.right, bottom: y + c.s(200)), c.font(11), c.p.muted) + c.s(4)
            if !buttons.isEmpty {
                var x = textLeft
                for (title, action) in buttons {
                    let w = c.buttonWidth(title, size: 11)
                    let b = RECT(x: x, y: y, width: w, height: c.s(20))
                    c.button(title, b, hover: isHover("guideb-\(title)"))
                    hit(b, "guideb-\(title)") { _ in action() }
                    x = b.right + c.s(6)
                }
                y += c.s(24)
            }
            y += c.s(12)
        }
        row("\u{EC05}", "AES67 and RAVENNA",
            "Found by themselves, from any AES67 or RAVENNA device or software, including the AES67 modes of Livewire+, Q-LAN "
            + "and WheatNet. If none appear, check that the network in the header is the audio network.")
        row("\u{E8EE}", "Dante, with AES67 turned on",
            "In Dante Controller, turn on AES67 for the device and give it a multicast AES67 flow; it then appears by itself. "
            + "Dante without AES67 can't be heard by this app.")
        var vbanButtons: [(String, () -> Void)] = []
        if !grabber.vbanEnabled { vbanButtons.append(("Turn on VBAN", { [unowned self] in self.grabber.vbanEnabled = true })) }
        vbanButtons.append(("Connect…", { [unowned self] in self.openConnect(tab: 0) }))
        row("\u{E7F4}", "VBAN",
            "Network Audio Sender on another computer, Voicemeeter and other VB-Audio apps, or any VBAN sender pointed at this PC. "
            + (grabber.vbanEnabled ? "VBAN is on." : "VBAN is off."), buttons: vbanButtons)
        row("\u{E7F8}", "Scream", "A free virtual sound card for Windows that sends the PC's audio over the network.",
            toggle: \.screamEnabled, beta: true)
        row("\u{E9D9}", "RTP without PTP", "PipeWire, PulseAudio, VLC and GStreamer senders, in L16 or L24, announced or added by hand.",
            toggle: \.plainRTPEnabled, beta: true)
        row("\u{E774}", "Internet radio", "Plays in the Mac Grabber. Not in this Windows beta yet.")
        c.hline(y, r.left, r.right, c.p.divider)
        y += c.s(12)
        let bw = c.buttonWidth("SDP Address…")
        let b = RECT(x: r.right - bw, y: y, width: bw, height: c.s(20))
        c.button("SDP Address…", b, hover: isHover("guide-sdp"))
        hit(b, "guide-sdp") { [unowned self] _ in self.openAddStream() }
        y += c.wrapped("A stream you know is there doesn't appear? Some devices send without advertising the stream on the network. "
                       + "Copy its SDP (a short text description of the stream, on the device's settings page) and paste it here.",
                       RECT(left: r.left, top: y, right: b.left - c.s(10), bottom: y + c.s(100)), c.font(11), c.p.muted)
        return y + c.s(8)
    }

    // MARK: - Status bar and log

    private func drawStatusBar(_ c: Canvas, _ r: RECT) {
        let pad = c.s(12)
        var x = r.left + pad
        let cy = (r.top + r.bottom) / 2
        if grabber.soloed != nil {
            let f = c.font(11, .semibold)
            c.text("Solo", RECT(left: x, top: r.top, right: x + c.width("Solo", f) + 2, bottom: r.bottom), f, c.p.soloText)
            x += c.width("Solo", f) + c.s(8)
            let w = c.buttonWidth("Clear")
            let b = RECT(x: x, y: cy - c.s(10), width: w, height: c.s(20))
            c.button("Clear", b, hover: isHover("soloclear"))
            hit(b, "soloclear") { [unowned self] _ in self.grabber.soloed = nil }
        }
        var bx = r.right - pad
        let logB = RECT(x: bx - c.s(20), y: cy - c.s(10), width: c.s(20), height: c.s(20))
        c.icon(view.showLog ? "\u{E70D}" : "\u{E8FD}", logB, size: 11, isHover("logtoggle") ? c.p.text : c.p.muted)
        hit(logB, "logtoggle", tip: "Activity log") { [unowned self] _ in self.view.showLog.toggle() }
        bx = logB.left - c.s(10)
        if !grabber.subscribed.isEmpty {
            let w = c.buttonWidth("Stop all")
            let b = RECT(x: bx - w, y: cy - c.s(10), width: w, height: c.s(20))
            c.button("Stop all", b, hover: isHover("stopall"))
            hit(b, "stopall") { [unowned self] _ in self.grabber.unsubscribeAll() }
            bx = b.left - c.s(10)
        }
        if let send = sendState, send.isSending {
            drawSendingPill(c, right: bx, centreY: cy) { [unowned self] in self.openConnect(tab: 1) }
        }
    }

    private func drawLogDrawer(_ c: Canvas, _ r: RECT) {
        let offset = beginScroll("drawer", r, c)
        var y = r.top + c.s(7) - offset
        let mono = c.font(9)
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        let entries = grabber.activity.entries.suffix(300)
        for entry in entries {
            let line = RECT(left: r.left + c.s(7), top: y, right: r.right - c.s(7), bottom: y + c.s(13))
            if line.bottom > r.top && line.top < r.bottom {
                c.text("\(clock.string(from: entry.date))  \(entry.text)", line, mono, c.p.muted)
            }
            y = line.bottom + c.s(1)
        }
        let content = y - (r.top - offset) + c.s(7)
        // Follow the newest line unless scrolled up to read.
        if var area = scrolls["drawer"], area.offset >= max(0, area.content - area.viewport.height) - c.s(20) {
            area.offset = max(0, content - r.height)
            scrolls["drawer"] = area
        }
        endScroll("drawer", content: content, c)
    }
}
