import Foundation
import WinSDK

/// GDI, wrapped so the window's drawing code reads like drawing and not like Win32. Everything is drawn into an off-screen bitmap and copied over in one go, so nothing
/// flickers while the meters move.
///
/// GDI rather than Direct2D: this window is rectangles, text and two level meters, which GDI does
/// well and without a dependency. If the meters ever want a gradient per sample or a shadow, that
/// is the point to think again.
public final class Painter {
    private let dc: HDC
    private var brushes: [COLORREF: HBRUSH] = [:]
    private var pens: [COLORREF: HPEN] = [:]
    public let dpi: Int

    public init(dc: HDC, dpi: Int) {
        self.dc = dc
        self.dpi = dpi
        SetBkMode(dc, TRANSPARENT)
    }

    deinit {
        for (_, brush) in brushes { DeleteObject(brush) }
        for (_, pen) in pens { DeleteObject(pen) }
    }

    /// Points at 96 dpi to this window's pixels.
    public func scaled(_ points: Int) -> Int32 { Int32(MulDiv(Int32(points), Int32(dpi), 96)) }

    private func brush(_ colour: COLORREF) -> HBRUSH {
        if let found = brushes[colour] { return found }
        let made = CreateSolidBrush(colour)!
        brushes[colour] = made
        return made
    }

    private func pen(_ colour: COLORREF, width: Int32 = 1) -> HPEN {
        if width == 1, let found = pens[colour] { return found }
        let made = CreatePen(PS_SOLID, width, colour)!
        if width == 1 { pens[colour] = made }
        return made
    }

    // MARK: Shapes

    public func fill(_ rect: RECT, _ colour: COLORREF) {
        var r = rect
        FillRect(dc, &r, brush(colour))
    }

    /// A horizontal hairline, for the dividers between rows.
    public func line(y: Int32, from x0: Int32, to x1: Int32, _ colour: COLORREF) {
        fill(RECT(left: x0, top: y, right: x1, bottom: y + 1), colour)
    }

    /// A rounded rectangle, for the cards and the pill-shaped buttons.
    public func rounded(_ rect: RECT, radius: Int32, fill colour: COLORREF, border: COLORREF? = nil) {
        let oldBrush = SelectObject(dc, brush(colour))
        let oldPen = SelectObject(dc, pen(border ?? colour))
        RoundRect(dc, rect.left, rect.top, rect.right, rect.bottom, radius * 2, radius * 2)
        SelectObject(dc, oldBrush)
        SelectObject(dc, oldPen)
    }

    public func ellipse(_ rect: RECT, _ colour: COLORREF) {
        let oldBrush = SelectObject(dc, brush(colour))
        let oldPen = SelectObject(dc, pen(colour))
        Ellipse(dc, rect.left, rect.top, rect.right, rect.bottom)
        SelectObject(dc, oldBrush)
        SelectObject(dc, oldPen)
    }

    /// Draws only inside `rect` until `clipOff()`. The scrolling parts of the window use it so a
    /// half-scrolled row stops at the edge of its area instead of over the status bar.
    public func clip(to rect: RECT) {
        let region = CreateRectRgn(rect.left, rect.top, rect.right, rect.bottom)
        SelectClipRgn(dc, region)
        DeleteObject(region)
    }

    public func clipOff() { SelectClipRgn(dc, nil) }

    // MARK: Text

    public enum Align { case left, centre, right }

    @discardableResult
    public func text(_ string: String, in rect: RECT, font: HFONT?, colour: COLORREF,
              align: Align = .left, middle: Bool = true, ellipsis: Bool = true) -> Int32 {
        guard !string.isEmpty else { return 0 }
        let oldFont = font.map { SelectObject(dc, $0) }
        SetTextColor(dc, colour)
        var r = rect
        var flags = DT_NOPREFIX | DT_SINGLELINE
        switch align {
        case .left: flags |= DT_LEFT
        case .centre: flags |= DT_CENTER
        case .right: flags |= DT_RIGHT
        }
        if middle { flags |= DT_VCENTER }
        if ellipsis { flags |= DT_END_ELLIPSIS }
        let height = string.withCString(encodedAs: UTF16.self) {
            DrawTextW(dc, $0, -1, &r, UInt32(flags))
        }
        if let oldFont { SelectObject(dc, oldFont) }
        return height
    }

    /// Several lines, wrapped at the width of `rect`: the explanatory notes under a setting, and
    /// the log's messages, which are sentences rather than labels.
    public func textWrapped(_ string: String, in rect: RECT, font: HFONT?, colour: COLORREF) {
        guard !string.isEmpty else { return }
        let oldFont = font.map { SelectObject(dc, $0) }
        SetTextColor(dc, colour)
        var r = rect
        _ = string.withCString(encodedAs: UTF16.self) {
            DrawTextW(dc, $0, -1, &r, UInt32(DT_NOPREFIX | DT_WORDBREAK | DT_TOP | DT_LEFT))
        }
        if let oldFont { SelectObject(dc, oldFont) }
    }

    /// How wide a string is, for laying things out beside each other.
    public func width(_ string: String, font: HFONT?) -> Int32 {
        guard !string.isEmpty else { return 0 }
        let oldFont = font.map { SelectObject(dc, $0) }
        var size = SIZE()
        _ = string.withCString(encodedAs: UTF16.self) {
            GetTextExtentPoint32W(dc, $0, Int32(string.utf16.count), &size)
        }
        if let oldFont { SelectObject(dc, oldFont) }
        return size.cx
    }

    // MARK: The level meter

    /// One channel's bar: a track, and the level over it running green into amber. `level` is
    /// 0…1 as the engine reports it, shown on the same curve the Mac uses so a quiet signal is
    /// still visible — level meters that are linear in amplitude look dead.
    public func meter(_ rect: RECT, level: Float) {
        fill(rect, Theme.meterTrack)
        guard level > 0.0001 else { return }
        let shown = CGFloatish(min(1, max(0, decibelScale(level))))
        let full = rect.right - rect.left
        let filled = Int32(CGFloatish(full) * shown)
        guard filled > 0 else { return }
        // Green up to about −12 dBFS, then into amber: one FillRect each rather than a per-pixel
        // gradient, which at this size no one could tell apart.
        let crossover = Int32(CGFloatish(full) * CGFloatish(decibelScale(0.25)))
        let greenEnd = min(filled, crossover)
        if greenEnd > 0 {
            fill(RECT(left: rect.left, top: rect.top, right: rect.left + greenEnd, bottom: rect.bottom),
                 Theme.meterLow)
        }
        if filled > crossover {
            fill(RECT(left: rect.left + crossover, top: rect.top, right: rect.left + filled, bottom: rect.bottom),
                 Theme.meterHigh)
        }
    }

    /// Amplitude to a bar position: −60 dBFS at the left, 0 dBFS at the right.
    private func decibelScale(_ level: Float) -> Float {
        let db = 20 * log10(max(level, 0.000_001))
        return max(0, min(1, (db + 60) / 60))
    }
}

/// `Double`, named so the arithmetic above says what it is doing without dragging in CoreGraphics.
private typealias CGFloatish = Double

/// Win32 `RECT` is four numbers in a fixed order; these make one read like a frame.
extension RECT {
    public init(x: Int32, y: Int32, width: Int32, height: Int32) {
        self.init(left: x, top: y, right: x + width, bottom: y + height)
    }
    public var width: Int32 { right - left }
    public var height: Int32 { bottom - top }
    public func contains(_ point: POINT) -> Bool {
        point.x >= left && point.x < right && point.y >= top && point.y < bottom
    }
    public func inset(by d: Int32) -> RECT {
        RECT(left: left + d, top: top + d, right: right - d, bottom: bottom - d)
    }
}
