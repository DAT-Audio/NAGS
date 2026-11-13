import Foundation
import WinSDK
import Win32UI
import NAGDraw

/// One frame's drawing for the full window: GDI for text, so it keeps ClearType, and
/// GDI+ (`NAGDraw`) for shapes, so circles and rounded corners are smooth. Everything is laid out
/// in **the Mac's points**, taken as device-independent pixels at 96 dpi and scaled by the
/// window's dpi — so a 30-point row is 30 pixels on an office monitor and 60 on a 4K laptop, and
/// the Mac's measurements carry over unchanged.
final class Canvas {
    let dc: HDC
    let dpi: Int
    let p: Palette
    private let shapes: NAGDrawRef?
    private var clips: [RECT] = []

    init(dc: HDC, dpi: Int, palette: Palette) {
        self.dc = dc
        self.dpi = dpi
        self.p = palette
        SetBkMode(dc, TRANSPARENT)
        shapes = nag_draw_begin(UnsafeMutableRawPointer(dc))
    }

    func finish() { nag_draw_end(shapes) }

    /// Points to pixels.
    func s(_ v: Double) -> Int32 { Int32((v * Double(dpi) / 96).rounded()) }
    func f(_ v: Double) -> Float { Float(v * Double(dpi) / 96) }
    func pt(_ px: Int32) -> Double { Double(px) * 96 / Double(dpi) }

    private func argb(_ c: Colour, _ alpha: Double = 1) -> UInt32 {
        func byte(_ v: Double) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return byte(alpha) << 24 | byte(c.r) << 16 | byte(c.g) << 8 | byte(c.b)
    }

    // MARK: - Fonts

    enum Weight: Int32 { case light = 300, regular = 400, medium = 500, semibold = 600, bold = 700 }

    private static var fonts: [String: HFONT] = [:]

    /// A font at a size in points (the Mac's) and a weight. Cached for the life of the app.
    func font(_ size: Double, _ weight: Weight = .regular, icon: Bool = false) -> HFONT? {
        let key = "\(size)-\(weight.rawValue)-\(icon)-\(dpi)"
        if let hit = Self.fonts[key] { return hit }
        let height = -Int32((size * Double(dpi) / 96).rounded())
        let faces = icon ? ["Segoe Fluent Icons", "Segoe MDL2 Assets"]
                         : (size >= 20 ? ["Segoe UI Variable Display", "Segoe UI"] : ["Segoe UI Variable Text", "Segoe UI"])
        var made: HFONT?
        for face in faces {
            made = face.withCString(encodedAs: UTF16.self) { name in
                CreateFontW(height, 0, 0, 0, icon ? 400 : weight.rawValue, 0, 0, 0,
                            DWORD(DEFAULT_CHARSET), DWORD(OUT_TT_PRECIS), DWORD(CLIP_DEFAULT_PRECIS),
                            DWORD(CLEARTYPE_QUALITY), DWORD(DEFAULT_PITCH) | DWORD(FF_DONTCARE), name)
            }
            if made != nil { break }
        }
        if let made { Self.fonts[key] = made }
        return made
    }

    // MARK: - Shapes

    func fill(_ r: RECT, _ c: Colour) {
        var rect = r
        let brush = CreateSolidBrush(c.ref)
        FillRect(dc, &rect, brush)
        DeleteObject(brush)
    }

    func hline(_ y: Int32, _ x0: Int32, _ x1: Int32, _ c: Colour) {
        fill(RECT(left: x0, top: y, right: x1, bottom: y + max(1, s(1) / 1)), c)
    }

    func vline(_ x: Int32, _ y0: Int32, _ y1: Int32, _ c: Colour) {
        fill(RECT(left: x, top: y0, right: x + 1, bottom: y1), c)
    }

    func round(_ r: RECT, _ radius: Double, _ c: Colour?, alpha: Double = 1,
               border: Colour? = nil, borderAlpha: Double = 1, borderWidth: Double = 1) {
        nag_draw_round_rect(shapes, Float(r.left), Float(r.top), Float(r.width), Float(r.height), f(radius),
                            c.map { argb($0, alpha) } ?? 0,
                            border.map { argb($0, borderAlpha) } ?? 0, f(borderWidth))
    }

    func gradient(_ r: RECT, _ radius: Double, top: Colour, bottom: Colour, border: Colour? = nil) {
        nag_draw_gradient_round_rect(shapes, Float(r.left), Float(r.top), Float(r.width), Float(r.height), f(radius),
                                     argb(top), argb(bottom), border.map { argb($0) } ?? 0, f(0.75))
    }

    func ellipse(_ r: RECT, _ c: Colour?, alpha: Double = 1, border: Colour? = nil, borderWidth: Double = 1) {
        nag_draw_ellipse(shapes, Float(r.left), Float(r.top), Float(r.width), Float(r.height),
                         c.map { argb($0, alpha) } ?? 0, border.map { argb($0) } ?? 0, f(borderWidth))
    }

    func polygon(_ points: [(Double, Double)], _ c: Colour, alpha: Double = 1) {
        var xy: [Float] = []
        for (x, y) in points { xy.append(Float(x)); xy.append(Float(y)) }
        nag_draw_polygon(shapes, xy, Int32(points.count), argb(c, alpha))
    }

    func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ c: Colour, width: Double = 1, alpha: Double = 1) {
        nag_draw_line(shapes, Float(x0), Float(y0), Float(x1), Float(y1), argb(c, alpha), f(width))
    }

    func polyline(_ points: [(Double, Double)], _ c: Colour, width: Double, alpha: Double = 1) {
        var xy: [Float] = []
        for (x, y) in points { xy.append(Float(x)); xy.append(Float(y)) }
        nag_draw_polyline(shapes, xy, Int32(points.count), argb(c, alpha), Float(width))
    }

    // MARK: - Clipping

    /// Draws only inside `r` until the matching `unclip()`; nests.
    func clip(_ r: RECT) {
        let inner = clips.last.map { RECT(left: max($0.left, r.left), top: max($0.top, r.top),
                                           right: min($0.right, r.right), bottom: min($0.bottom, r.bottom)) } ?? r
        clips.append(inner)
        apply(inner)
    }

    func unclip() {
        clips.removeLast()
        if let last = clips.last { apply(last) } else {
            SelectClipRgn(dc, nil)
            nag_draw_clip(shapes, 0, 0, 0, 0)
        }
    }

    private func apply(_ r: RECT) {
        let region = CreateRectRgn(r.left, r.top, max(r.left, r.right), max(r.top, r.bottom))
        SelectClipRgn(dc, region)
        DeleteObject(region)
        nag_draw_clip(shapes, Float(r.left), Float(r.top), Float(max(1, r.width)), Float(max(1, r.height)))
    }

    // MARK: - Text

    enum Align { case left, centre, right }

    /// One line, vertically centred in `r`. `middle` truncates in the middle, as the Mac does
    /// for stream names and addresses, where both ends say something.
    func text(_ string: String, _ r: RECT, _ font: HFONT?, _ c: Colour,
              align: Align = .left, middle: Bool = false, top: Bool = false) {
        guard !string.isEmpty, r.width > 0 else { return }
        var shown = string
        if middle, width(string, font) > r.width { shown = truncateMiddle(string, font, r.width) }
        let old = font.map { SelectObject(dc, $0) }
        SetTextColor(dc, c.ref)
        var rect = r
        var flags = UInt32(DT_NOPREFIX | DT_SINGLELINE | DT_END_ELLIPSIS)
        flags |= top ? UInt32(DT_TOP) : UInt32(DT_VCENTER)
        switch align {
        case .left: flags |= UInt32(DT_LEFT)
        case .centre: flags |= UInt32(DT_CENTER)
        case .right: flags |= UInt32(DT_RIGHT)
        }
        _ = shown.withCString(encodedAs: UTF16.self) { DrawTextW(dc, $0, -1, &rect, flags) }
        if let old { SelectObject(dc, old) }
    }

    func width(_ string: String, _ font: HFONT?) -> Int32 {
        guard !string.isEmpty else { return 0 }
        let old = font.map { SelectObject(dc, $0) }
        var size = SIZE()
        _ = string.withCString(encodedAs: UTF16.self) { GetTextExtentPoint32W(dc, $0, Int32(string.utf16.count), &size) }
        if let old { SelectObject(dc, old) }
        return size.cx
    }

    private func truncateMiddle(_ s: String, _ font: HFONT?, _ room: Int32) -> String {
        let chars = Array(s)
        var keep = chars.count
        while keep > 2 {
            keep -= 1
            let head = keep / 2 + keep % 2, tail = keep / 2
            let candidate = String(chars.prefix(head)) + "…" + String(chars.suffix(tail))
            if width(candidate, font) <= room { return candidate }
        }
        return "…"
    }

    /// Wrapped at the width of `r`, from its top; returns the height used.
    @discardableResult
    func wrapped(_ string: String, _ r: RECT, _ font: HFONT?, _ c: Colour, align: Align = .left) -> Int32 {
        guard !string.isEmpty else { return 0 }
        let old = font.map { SelectObject(dc, $0) }
        SetTextColor(dc, c.ref)
        var rect = r
        var flags = UInt32(DT_NOPREFIX | DT_WORDBREAK | DT_TOP)
        flags |= align == .centre ? UInt32(DT_CENTER) : (align == .right ? UInt32(DT_RIGHT) : UInt32(DT_LEFT))
        var measure = r
        _ = string.withCString(encodedAs: UTF16.self) { DrawTextW(dc, $0, -1, &measure, flags | UInt32(DT_CALCRECT)) }
        _ = string.withCString(encodedAs: UTF16.self) { DrawTextW(dc, $0, -1, &rect, flags) }
        if let old { SelectObject(dc, old) }
        return measure.height
    }

    /// The height a wrapped string would take, without drawing it.
    func wrappedHeight(_ string: String, width: Int32, _ font: HFONT?) -> Int32 {
        guard !string.isEmpty else { return 0 }
        let old = font.map { SelectObject(dc, $0) }
        var measure = RECT(left: 0, top: 0, right: width, bottom: 0)
        _ = string.withCString(encodedAs: UTF16.self) {
            DrawTextW(dc, $0, -1, &measure, UInt32(DT_NOPREFIX | DT_WORDBREAK | DT_TOP | DT_CALCRECT))
        }
        if let old { SelectObject(dc, old) }
        return measure.height
    }

    /// Text with **bold** runs, as the Mac's footers and explainers write them; wrapped.
    @discardableResult
    func rich(_ string: String, _ r: RECT, size: Double, _ c: Colour) -> Int32 {
        // Drawn word by word so a bold run can sit inside a sentence.
        let regular = font(size), bold = font(size, .semibold)
        let space = width(" ", regular)
        let lineHeight = s(size * 1.35)
        var x = r.left, y = r.top
        var isBold = false
        for paragraph in string.components(separatedBy: "\n") {
            if paragraph.isEmpty { y += lineHeight / 2; x = r.left; continue }
            for raw in paragraph.split(separator: " ", omittingEmptySubsequences: false) {
                var word = String(raw)
                var parts: [(String, Bool)] = []
                while let range = word.range(of: "**") {
                    let before = String(word[..<range.lowerBound])
                    if !before.isEmpty { parts.append((before, isBold)) }
                    isBold.toggle()
                    word = String(word[range.upperBound...])
                }
                if !word.isEmpty { parts.append((word, isBold)) }
                let w = parts.reduce(Int32(0)) { $0 + width($1.0, $1.1 ? bold : regular) }
                if x > r.left, x + w > r.right { x = r.left; y += lineHeight }
                for (text, b) in parts {
                    let fw = width(text, b ? bold : regular)
                    self.text(text.replacingOccurrences(of: "*", with: ""),
                              RECT(left: x, top: y, right: x + fw + 2, bottom: y + lineHeight), b ? bold : regular,
                              b ? p.text : c)
                    x += fw
                }
                x += space
            }
            x = r.left
            y += lineHeight
        }
        return y - r.top
    }

    func icon(_ glyph: String, _ r: RECT, size: Double, _ c: Colour, align: Align = .centre) {
        text(glyph, r, font(size, icon: true), c, align: align)
    }
}

// MARK: - The controls, as the Mac draws them

extension Canvas {
    /// The Mac's `PillToggle`: DIM, MONO, M, S, BYP, Δ, ACTIVE.
    func pill(_ title: String, _ r: RECT, on: Bool, tint: Colour, hover: Bool = false, enabled: Bool = true) {
        let radius = p.skin.buttonRadius
        if let face = p.skin.buttonFace {
            if on { round(r, radius, tint, alpha: 0.9, border: face.stroke) }
            else { gradient(r, radius, top: face.top, bottom: face.bottom, border: face.stroke) }
        } else {
            round(r, radius, on ? tint : p.label, alpha: on ? 0.85 : (hover ? 0.14 : 0.08))
        }
        let colour = on ? (p.skin.buttonFace?.onText ?? tint.readable) : (p.skin.buttonFace?.text ?? p.secondary)
        text(title, r, font(10, .semibold), enabled ? colour : colour.over(p.window, 0.6), align: .centre)
    }

    func pillWidth(_ title: String) -> Int32 { width(title, font(10, .semibold)) + s(16) }

    /// The Mac's `Chip`: a source or a channel count.
    func chip(_ title: String, x: Int32, centreY: Int32, tint: Colour, filled: Bool = false) -> Int32 {
        let fnt = font(9, .semibold)
        let w = width(title, fnt) + s(10)
        let h = s(15)
        let r = RECT(x: x, y: centreY - h / 2, width: w, height: h)
        let radius = p.skin.chipRadius ?? 20
        round(r, radius, tint, alpha: p.skin.chipText != nil ? 0.5 : (filled ? 0.22 : 0.13))
        text(title, r, fnt, p.skin.chipText ?? tint, align: .centre)
        return w
    }

    /// A plain button: Cancel, Add, Try again, Done.
    func button(_ title: String, _ r: RECT, hover: Bool = false, prominent: Bool = false, enabled: Bool = true,
                size: Double = 11) {
        let radius = max(4, p.skin.buttonRadius)
        if prominent {
            round(r, radius, p.active, alpha: hover ? 1 : 0.9)
            text(title, r, font(size, .medium), p.active.readable, align: .centre)
        } else if let face = p.skin.buttonFace {
            gradient(r, radius, top: face.top, bottom: face.bottom, border: face.stroke)
            text(title, r, font(size), enabled ? face.text : face.text.over(face.top, 0.5), align: .centre)
        } else {
            round(r, radius, p.label, alpha: hover && enabled ? 0.16 : 0.09, border: p.label, borderAlpha: 0.10)
            text(title, r, font(size), enabled ? p.text : p.secondary.over(p.window, 0.4), align: .centre)
        }
    }

    func buttonWidth(_ title: String, size: Double = 11) -> Int32 { width(title, font(size)) + s(18) }

    /// The Mac's `ThemedSwitch`.
    func toggleSwitch(_ r: RECT, on: Bool, enabled: Bool = true) {
        round(r, Double(pt(r.height)) / 2, on ? p.active : p.label, alpha: (on ? 1 : 0.14) * (enabled ? 1 : 0.45))
        let knob = r.height - s(4)
        let x = on ? r.right - knob - s(2) : r.left + s(2)
        let k = RECT(x: x, y: r.top + s(2), width: knob, height: knob)
        ellipse(RECT(x: k.left, y: k.top + s(0.5), width: knob, height: knob), .black, alpha: 0.18)
        ellipse(k, .white, alpha: enabled ? 1 : 0.7)
    }

    /// The play / stop face (`PlayStopIcon`): a stop disc in the active colour and a play ring
    /// at rest, or the skin's square button.
    func playStop(_ r: RECT, active: Bool, hover: Bool = false) {
        if let play = p.skin.play {
            let shape = r
            round(shape, play.square ? play.radius : Double(pt(r.width)) / 2, active ? play.active : play.idle,
                  border: .white, borderAlpha: 0.12, borderWidth: 0.75)
            glyph(active: active, in: r, colour: active ? play.activeGlyph : play.idleGlyph, scale: 0.42)
            return
        }
        if active {
            ellipse(r, p.active)
            let side = Double(r.width) * 0.32
            let c = (Double(r.left + r.right) / 2, Double(r.top + r.bottom) / 2)
            round(RECT(left: Int32(c.0 - side / 2), top: Int32(c.1 - side / 2), right: Int32(c.0 + side / 2),
                       bottom: Int32(c.1 + side / 2)), 1.2, p.active.readable)
        } else {
            let colour = hover ? p.text : p.secondary
            ellipse(r.inset(by: s(0.75)), nil, border: colour, borderWidth: 1.5)
            glyph(active: false, in: r, colour: colour, scale: 0.40)
        }
    }

    private func glyph(active: Bool, in r: RECT, colour: Colour, scale: Double) {
        let w = Double(r.width), cx = Double(r.left) + w / 2, cy = Double(r.top) + Double(r.height) / 2
        if active {
            let side = w * scale * 0.85
            round(RECT(left: Int32(cx - side / 2), top: Int32(cy - side / 2), right: Int32(cx + side / 2),
                       bottom: Int32(cy + side / 2)), 1, colour)
        } else {
            let h = w * scale, wd = h * 0.9
            polygon([(cx - wd * 0.38, cy - h / 2), (cx + wd * 0.62, cy), (cx - wd * 0.38, cy + h / 2)], colour)
        }
    }

    /// A chevron, drawn rather than taken from a font so it sits where it is put.
    func chevron(_ r: RECT, down: Bool, colour: Colour, size: Double = 8) {
        let cx = Double(r.left + r.right) / 2, cy = Double(r.top + r.bottom) / 2
        let a = Double(s(size)) * 0.32
        if down {
            line(cx - a, cy - a / 2, cx, cy + a / 2, colour, width: 1.5)
            line(cx, cy + a / 2, cx + a, cy - a / 2, colour, width: 1.5)
        } else {
            line(cx - a / 2, cy - a, cx + a / 2, cy, colour, width: 1.5)
            line(cx + a / 2, cy, cx - a / 2, cy + a, colour, width: 1.5)
        }
    }

    /// A slider (the Mac's `ResettableSlider`): a groove filled in the active colour to the knob,
    /// or the skin's fader. `fraction` 0…1.
    func slider(_ track: RECT, fraction: Double, tint: Colour? = nil, mini: Bool = false, enabled: Bool = true) {
        let tint = tint ?? p.active
        let cy = (track.top + track.bottom) / 2
        let x = track.left + Int32(Double(track.width) * max(0, min(1, fraction)))
        if let fader = p.skin.fader {
            let gh = max(1, s(fader.grooveHeight))
            let groove = RECT(left: track.left, top: cy - gh / 2, right: track.right, bottom: cy - gh / 2 + gh)
            round(groove, fader.grooveHeight / 2, fader.groove)
            if fader.fillsGroove {
                round(RECT(left: groove.left, top: groove.top, right: x, bottom: groove.bottom), fader.grooveHeight / 2,
                      fader.grooveFill ?? tint)
            }
            let scale = mini ? 0.8 : 1.0
            let cw = s(fader.capWidth * scale), ch = s(fader.capHeight * scale)
            let cap = RECT(x: x - cw / 2, y: cy - ch / 2, width: cw, height: ch)
            if fader.triangle {
                polygon([(Double(x), Double(cap.top)), (Double(cap.right), Double(cap.bottom)),
                         (Double(cap.left), Double(cap.bottom))], fader.capTop)
            } else if fader.pentagon {
                polygon([(Double(cap.left), Double(cap.top)), (Double(cap.right), Double(cap.top)),
                         (Double(cap.right), Double(cap.bottom) - Double(ch) * 0.35), (Double(x), Double(cap.bottom)),
                         (Double(cap.left), Double(cap.bottom) - Double(ch) * 0.35)], fader.capTop)
            } else {
                gradient(cap, fader.capRadius * scale, top: fader.capTop, bottom: fader.capBottom, border: fader.capStroke)
                if fader.gripLines == -1 {
                    hline(cy, cap.left + s(2), cap.right - s(2), fader.gripColour)
                } else if fader.gripLines > 0 {
                    let n = fader.gripLines
                    for i in 0..<n {
                        let gy = cap.top + ch * Int32(i + 1) / Int32(n + 1)
                        hline(gy, cap.left + s(2), cap.right - s(2), fader.gripColour)
                    }
                }
            }
            return
        }
        let gh = s(mini ? 3 : 4)
        let groove = RECT(left: track.left, top: cy - gh / 2, right: track.right, bottom: cy - gh / 2 + gh)
        round(groove, Double(pt(gh)) / 2, p.label, alpha: 0.14)
        round(RECT(left: groove.left, top: groove.top, right: max(groove.left + gh, x), bottom: groove.bottom),
              Double(pt(gh)) / 2, enabled ? tint : p.secondary)
        let k = s(mini ? 11 : 16)
        let knob = RECT(x: x - k / 2, y: cy - k / 2, width: k, height: k)
        ellipse(RECT(x: knob.left, y: knob.top + s(0.5), width: k, height: k), .black, alpha: 0.22)
        ellipse(knob, .white, border: p.label.over(.white, 0.7), borderWidth: 0.5)
    }

    /// A segmented control: the options across, the chosen one raised. Returns each segment.
    func segmented(_ options: [String], _ r: RECT, selected: Int, size: Double = 11, hover: Int? = nil) -> [RECT] {
        round(r, 6, p.label, alpha: 0.08)
        let fnt = font(size)
        let total = options.reduce(Int32(0)) { $0 + width($1, fnt) + s(20) }
        var x = r.left
        var rects: [RECT] = []
        for (i, option) in options.enumerated() {
            let w = total > 0 ? Int32(Double(r.width) * Double(width(option, fnt) + s(20)) / Double(total)) : r.width
            let seg = RECT(left: x, top: r.top, right: i == options.count - 1 ? r.right : x + w, bottom: r.bottom)
            if i == selected {
                round(seg.inset(by: s(2)), 5, p.dark ? p.label.over(p.window, 0.75) : .white, alpha: p.dark ? 0.22 : 1,
                      border: p.label, borderAlpha: 0.08)
            } else if i == hover {
                round(seg.inset(by: s(2)), 5, p.label, alpha: 0.06)
            }
            text(option, seg, fnt, i == selected ? p.text : p.secondary, align: .centre)
            rects.append(seg)
            x = seg.right
        }
        return rects
    }

    func segmentedWidth(_ options: [String], size: Double = 11) -> Int32 {
        options.reduce(Int32(0)) { $0 + width($1, font(size)) + s(20) }
    }

    /// A pop-up button: the choice and a chevron, opening a menu.
    func popup(_ title: String, _ r: RECT, hover: Bool = false, size: Double = 11, colour: Colour? = nil) {
        round(r, 5, p.label, alpha: hover ? 0.14 : 0.08, border: p.label, borderAlpha: 0.08)
        text(title, RECT(left: r.left + s(8), top: r.top, right: r.right - s(18), bottom: r.bottom), font(size),
             colour ?? p.text)
        chevron(RECT(left: r.right - s(18), top: r.top, right: r.right - s(4), bottom: r.bottom), down: true,
                colour: p.secondary, size: 9)
    }

    /// A checkbox-free menu label: text with a chevron after it, as the Mac's borderless menus.
    @discardableResult
    func menuLabel(_ title: String, x: Int32, _ r: RECT, size: Double = 11, colour: Colour, weight: Weight = .regular) -> RECT {
        let fnt = font(size, weight)
        let w = min(width(title, fnt), r.right - x - s(14))
        text(title, RECT(left: x, top: r.top, right: x + w + 2, bottom: r.bottom), fnt, colour)
        let c = RECT(left: x + w + s(3), top: r.top, right: x + w + s(13), bottom: r.bottom)
        chevron(c, down: true, colour: colour, size: 7)
        return RECT(left: x, top: r.top, right: c.right, bottom: r.bottom)
    }

    /// A text field's box, for a value that is typed: drawn, and replaced by Windows' own edit
    /// control while it is being typed in.
    func field(_ value: String, _ r: RECT, placeholder: String = "", hover: Bool = false, align: Align = .left,
               mono: Bool = false) {
        round(r, 5, p.dark ? Colour(0, 0, 0) : .white, alpha: p.dark ? 0.25 : 1,
              border: hover ? p.active : p.label, borderAlpha: hover ? 0.8 : 0.18)
        let inner = RECT(left: r.left + s(7), top: r.top, right: r.right - s(7), bottom: r.bottom)
        if value.isEmpty { text(placeholder, inner, font(11), p.secondary.over(p.window, 0.3), align: align) }
        else { text(value, inner, font(11), p.text, align: align) }
    }

    /// The "BETA" badge.
    func betaBadge(x: Int32, centreY: Int32) -> Int32 {
        let fnt = font(8, .bold)
        let w = width("BETA", fnt) + s(8)
        let r = RECT(x: x, y: centreY - s(6), width: w, height: s(12))
        round(r, 6, nil, border: Colour(1, 0.58, 0), borderAlpha: 0.7)
        text("BETA", r, fnt, Colour(1, 0.58, 0), align: .centre)
        return w
    }

    // MARK: - Meters

    static func fraction(_ peak: Float) -> Double {
        guard peak > 0.0002 else { return 0 }
        return min(1, max(0, (20 * log10(Double(peak)) + 60) / 60))
    }

    /// One bar, vertical or horizontal, coloured by level at each point as the Mac's ramp is.
    /// `dimmed`: out of circuit — grey, as the Mac draws a muted or solo-silenced channel.
    func bar(_ r: RECT, level: Float, vertical: Bool, dimmed: Bool = false, hold: Float? = nil,
             trackless: Bool = false, noData: Bool = false) {
        let length = vertical ? r.height : r.width
        let thick = vertical ? r.width : r.height
        let radius = p.skin.squareMeters ? 0 : Double(pt(min(thick, s(8)))) / 2.5
        if !trackless {
            if p.skin.wellRamp != nil {
                // Zoned wells (FNod): drawn in a few bands.
                let bands = 6
                for i in 0..<bands {
                    let a = Double(i) / Double(bands), b = Double(i + 1) / Double(bands)
                    let c = p.wellColour(at: (a + b) / 2)
                    fill(segment(r, from: a, to: b, vertical: vertical), dimmed ? c.over(p.window, 0.5) : c)
                }
            } else {
                round(r, radius, p.skin.meterWell ?? p.label,
                      alpha: p.skin.meterWell != nil ? (dimmed ? 0.6 : 1) : (dimmed ? 0.05 : 0.10))
            }
        }
        let shown = Self.fraction(level)
        if shown > 0, length > 0 {
            // Bands of colour along the lit part: enough steps that the ramp reads as a ramp.
            let steps = max(1, min(24, Int(Double(length) * shown / Double(max(2, s(4))))))
            for i in 0..<steps {
                let a = shown * Double(i) / Double(steps), b = shown * Double(i + 1) / Double(steps)
                var c = p.meterColour(at: (a + b) / 2)
                if dimmed { c = p.window.over(c, 0.22) }
                fill(segment(r, from: a, to: b, vertical: vertical), c)
            }
            if let pitch = p.skin.segmentPitch {
                // Segmented meters (Pro Tools): a line of the well every few points.
                let step = max(2, s(pitch * 2))
                var k: Int32 = step
                let lit = Int32(Double(length) * shown)
                while k < lit {
                    if vertical { fill(RECT(left: r.left, top: r.bottom - k, right: r.right, bottom: r.bottom - k + 1), p.skin.meterWell ?? .black) }
                    else { fill(RECT(left: r.left + k, top: r.top, right: r.left + k + 1, bottom: r.bottom), p.skin.meterWell ?? .black) }
                    k += step
                }
            }
        }
        if let hold, hold > 0.0002, !dimmed {
            let h = Self.fraction(hold)
            let c = hold >= 0.999 ? p.red : p.meterHold
            let at = Int32(Double(length) * h)
            if vertical {
                fill(RECT(left: r.left, top: r.bottom - at - s(0.75), right: r.right, bottom: r.bottom - at + s(0.75)), c)
            } else {
                fill(RECT(left: r.left + at - s(0.75), top: r.top, right: r.left + at + s(0.75), bottom: r.bottom), c)
            }
        }
        if noData, trackless {
            // A dotted line where a stream that should be sending is not: the Mac's "no data".
            var x = r.left
            while x < r.right {
                fill(RECT(left: x, top: (r.top + r.bottom) / 2, right: x + s(1.5), bottom: (r.top + r.bottom) / 2 + s(1.5)),
                     p.secondary)
                x += s(4)
            }
        }
    }

    private func segment(_ r: RECT, from a: Double, to b: Double, vertical: Bool) -> RECT {
        if vertical {
            let h = Double(r.height)
            return RECT(left: r.left, top: r.bottom - Int32((h * b).rounded()), right: r.right,
                        bottom: r.bottom - Int32((h * a).rounded()))
        }
        let w = Double(r.width)
        return RECT(left: r.left + Int32((w * a).rounded()), top: r.top, right: r.left + Int32((w * b).rounded()),
                    bottom: r.bottom)
    }
}
