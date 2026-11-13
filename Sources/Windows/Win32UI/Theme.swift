import Foundation
import WinSDK

/// The Windows apps' colours and type, shared by the Sender and the Grabber.
///
/// Graphite and amber, as the Mac Sender opens in (`docs/sender-dark.png`). The wording and the
/// order of things follow the Mac so the two can be explained in one quick-start; the drawing
/// does not, because this is Win32 and should look like Windows — square corners where the Mac
/// has round ones, Segoe UI rather than SF Pro, Windows' own focus and hover.
public enum Theme {
    // MARK: Colours

    /// Win32 wants colours the other way round from everyone else: 0x00BBGGRR.
    public static func rgb(_ hex: UInt32) -> COLORREF {
        let r = (hex >> 16) & 0xFF, g = (hex >> 8) & 0xFF, b = hex & 0xFF
        return COLORREF(b << 16 | g << 8 | r)
    }

    public static let windowBackground = rgb(0x1A1A1C)
    public static let headerBackground = rgb(0x111113)
    public static let cardBackground = rgb(0x232326)
    public static let rowBackground = rgb(0x1F1F22)
    public static let rowAlternate = rgb(0x242428)
    public static let divider = rgb(0x2E2E33)
    /// Behind a text field, which has to read as somewhere to type rather than somewhere to look.
    public static let fieldBackground = rgb(0x121214)

    public static let text = rgb(0xF2F2F4)
    public static let textDim = rgb(0x9A9AA2)
    public static let textFaint = rgb(0x6E6E77)

    /// The accent the Mac opens with.
    public static let amber = rgb(0xE8912D)
    public static let amberDim = rgb(0x8A5A22)
    public static let green = rgb(0x5DC26B)
    public static let red = rgb(0xD9453E)

    /// The meter, green through to amber at the top, as the Mac draws it.
    public static let meterLow = rgb(0x5DC26B)
    public static let meterHigh = rgb(0xE8B32D)
    public static let meterTrack = rgb(0x2A2A2E)

    // MARK: Type

    /// Segoe UI Variable on Windows 11, Segoe UI before it. Asking for the first and letting
    /// Windows substitute gets the right one either way.
    public static let faceName = "Segoe UI Variable Display"
    public static let fallbackFaceName = "Segoe UI"

    /// Everything is sized in points at 96 dpi and scaled by the window's own dpi, so the window
    /// is right on a 4K laptop screen as well as an office monitor.
    public static func font(_ points: Int, bold: Bool = false, dpi: Int = 96) -> HFONT? {
        let height = -MulDiv(Int32(points), Int32(dpi), 72)
        var created: HFONT?
        for name in [faceName, fallbackFaceName] {
            created = name.withCString(encodedAs: UTF16.self) { face in
                CreateFontW(height, 0, 0, 0, bold ? FW_SEMIBOLD : FW_NORMAL, 0, 0, 0,
                            DWORD(DEFAULT_CHARSET), DWORD(OUT_TT_PRECIS), DWORD(CLIP_DEFAULT_PRECIS),
                            DWORD(CLEARTYPE_QUALITY), DWORD(DEFAULT_PITCH) | DWORD(FF_DONTCARE), face)
            }
            if created != nil { break }
        }
        return created
    }

    /// Windows' own icon font: Segoe Fluent Icons on Windows 11, Segoe MDL2 Assets before it.
    /// The glyphs used here (gear, add, play, stop, headphone, star) are in both, at the same
    /// code points, so either font draws the window correctly.
    public static func iconFont(_ points: Int, dpi: Int = 96) -> HFONT? {
        let height = -MulDiv(Int32(points), Int32(dpi), 72)
        for name in ["Segoe Fluent Icons", "Segoe MDL2 Assets"] {
            let made = name.withCString(encodedAs: UTF16.self) { face in
                CreateFontW(height, 0, 0, 0, 400, 0, 0, 0,
                            DWORD(DEFAULT_CHARSET), DWORD(OUT_TT_PRECIS), DWORD(CLIP_DEFAULT_PRECIS),
                            DWORD(CLEARTYPE_QUALITY), DWORD(DEFAULT_PITCH) | DWORD(FF_DONTCARE), face)
            }
            if made != nil { return made }
        }
        return font(points, dpi: dpi)
    }

    // MARK: Measurements, in points at 96 dpi

    public static let headerHeight = 44
    public static let statusBarHeight = 40
    public static let rowHeight = 56
    public static let gutter = 16
    public static let windowWidth = 480
    public static let windowHeight = 720
}

/// `FW_SEMIBOLD` and friends are macros, so Swift does not get them from WinSDK.
private let FW_NORMAL: Int32 = 400
private let FW_SEMIBOLD: Int32 = 600
