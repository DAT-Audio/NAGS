import Foundation
import WinSDK
import Win32UI

/// The Grabber's look on Windows: **the Mac's, value for value** —
/// Light, Dark or the system's; a colour scheme of two roles (Window washes every surface, Active
/// marks what is switched on); and the schemes that bring a look of their own, the skins. The
/// tables are copied from `Sources/NetworkAudioShared/Theme.swift`, `Skin.swift` and
/// `SkinLooks.swift` and must move with them.
///
/// What stays fixed is the Mac's list too: meter green/amber/red, the transport tints, solo
/// yellow, delta magenta, mute and clip red.

/// A colour as three channels from 0 to 1, for the arithmetic GDI's `COLORREF` cannot do.
struct Colour: Equatable {
    var r: Double, g: Double, b: Double

    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

    /// `#RRGGBB`, or nil for anything else, so a corrupted preference falls back rather than
    /// turning black.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let v = UInt32(text, radix: 16) else { return nil }
        self.init(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    static func hex(_ s: String) -> Colour { Colour(hex: s) ?? Colour(0, 0, 0) }
    static let white = Colour(1, 1, 1)
    static let black = Colour(0, 0, 0)

    var ref: COLORREF {
        func byte(_ v: Double) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return COLORREF(byte(b) << 16 | byte(g) << 8 | byte(r))
    }

    var hexString: String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    /// `other` laid over this at `amount` opacity — how the Mac's translucent fills land.
    func over(_ other: Colour, _ amount: Double) -> Colour {
        Colour(r + (other.r - r) * amount, g + (other.g - g) * amount, b + (other.b - b) * amount)
    }

    /// WCAG relative luminance.
    var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// Black or white, whichever reads on this colour (the Mac's `readableForeground`).
    var readable: Colour { luminance > 0.45 ? .black : .white }

    // HSB, for `legible`.
    var hsb: (h: Double, s: Double, b: Double) {
        let maxV = max(r, g, b), minV = min(r, g, b), d = maxV - minV
        var h = 0.0
        if d > 0 {
            if maxV == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if maxV == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, maxV == 0 ? 0 : d / maxV, maxV)
    }

    init(h: Double, s: Double, b: Double) {
        let i = floor(h * 6), f = h * 6 - i
        let p = b * (1 - s), q = b * (1 - f * s), t = b * (1 - (1 - f) * s)
        switch Int(i) % 6 {
        case 0: self.init(b, t, p)
        case 1: self.init(q, b, p)
        case 2: self.init(p, b, t)
        case 3: self.init(p, q, b)
        case 4: self.init(t, p, b)
        default: self.init(b, p, q)
        }
    }

    /// Nudged until it reads as a foreground on this appearance — the Mac's `legible(on:)`: a
    /// too-light colour darkened on a light window (a yellow turned to gold first, so it does not
    /// go olive), a too-dark one lightened on a dark window.
    func legible(dark: Bool, lightTarget: Double = 0.26) -> Colour {
        var (h, s, v) = hsb
        if !dark {
            if (0.12...0.20).contains(h), Colour(h: h, s: s, b: v).luminance > lightTarget { h = 0.11 }
            while v > 0.30, Colour(h: h, s: s, b: v).luminance > lightTarget { v -= 0.03 }
        } else {
            while v < 0.97, Colour(h: h, s: s, b: v).luminance < 0.15 { v += 0.03 }
        }
        return Colour(h: h, s: s, b: v)
    }
}

enum Appearance: String, CaseIterable {
    case system, light, dark
    var label: String { rawValue.capitalized }
}

/// A named scheme: the Mac's `ThemePreset`.
struct ThemePreset {
    let name: String
    let primary: String
    let secondary: String
    var skin: Skin = .standard

    static let all: [ThemePreset] = [
        ThemePreset(name: "Ultramarine & Canary", primary: "#2B44C7", secondary: "#F5D90A"),
        ThemePreset(name: "Teal & Coral",         primary: "#0E8C8C", secondary: "#FF7F50"),
        ThemePreset(name: "Plum & Gold",          primary: "#7A3E8F", secondary: "#E0A526"),
        ThemePreset(name: "Slate & Lime",         primary: "#41596E", secondary: "#A8CF38"),
        ThemePreset(name: "Graphite & Amber",     primary: "#4A4A4F", secondary: "#F0A028"),
    ]

    static let looks: [ThemePreset] = [
        ThemePreset(name: "Rea-Theme Default", primary: "#466168", secondary: "#6B7C83", skin: .reaper),
        ThemePreset(name: "Lojick",            primary: "#2B2B2D", secondary: "#5A8FE6", skin: .lojick),
        ThemePreset(name: "Abletron",          primary: "#A3A3A3", secondary: "#1E1E1E", skin: .abletron),
        ThemePreset(name: "Wise",              primary: "#333333", secondary: "#5E9BF5", skin: .wise),
        ThemePreset(name: "FNod",              primary: "#2E2E2E", secondary: "#E6E043", skin: .fnod),
        ThemePreset(name: "MidTools",          primary: "#3C3C3E", secondary: "#5BE05B", skin: .midtools),
        ThemePreset(name: "Bitlick",           primary: "#262626", secondary: "#FF8C1A", skin: .bitlick),
        ThemePreset(name: "RogueSingleCell",   primary: "#ECECEC", secondary: "#FF9500", skin: .rogue),
        ThemePreset(name: "AudaTown",          primary: "#E4E4E4", secondary: "#6A6AE0", skin: .audatown),
    ]

    static let standard = all[4]
    static let previousFallback = all[0]
}

/// The skins, as data (the Mac's `SkinStyle`): surfaces, meters, faders, buttons, play.
enum Skin: String, CaseIterable {
    case standard, reaper, lojick, abletron, wise, fnod, midtools, bitlick, rogue, audatown

    static func forScheme(enabled: Bool, primary: String, secondary: String) -> Skin {
        guard enabled else { return .standard }
        for p in ThemePreset.all + ThemePreset.looks
        where p.primary.caseInsensitiveCompare(primary) == .orderedSame
            && p.secondary.caseInsensitiveCompare(secondary) == .orderedSame {
            return p.skin
        }
        return .standard
    }

    var style: SkinStyle {
        switch self {
        case .standard: return SkinStyle()
        case .reaper:   return .reaper
        case .lojick:   return .lojick
        case .abletron: return .abletron
        case .wise:     return .wise
        case .fnod:     return .fnod
        case .midtools: return .midtools
        case .bitlick:  return .bitlick
        case .rogue:    return .rogue
        case .audatown: return .audatown
        }
    }
}

struct SkinStyle {
    var dark: Bool? = nil
    var window: Colour? = nil
    var panel: Colour? = nil
    var figureText: Colour? = nil
    var warning: Colour? = nil
    var chipText: Colour? = nil
    var meterRamp: [Colour]? = nil
    var meterWell: Colour? = nil
    var wellRamp: [Colour]? = nil
    var meterHold: Colour? = nil
    var squareMeters = false
    var segmentPitch: Double? = nil
    var scaleBetween = false
    var fader: Fader? = nil
    var buttonRadius: Double = 5
    var chipRadius: Double? = nil
    var buttonFace: ButtonFace? = nil
    var play: Play? = nil
    var mute: Colour? = nil
    var solo: Colour? = nil

    struct Fader {
        var capWidth: Double, capHeight: Double, capRadius: Double
        var capTop: Colour, capBottom: Colour, capStroke: Colour?
        var gripLines: Int            // 0 none, -1 a centre line, n lines
        var gripColour: Colour
        var groove: Colour
        var grooveHeight: Double
        var fillsGroove: Bool
        var grooveFill: Colour? = nil
        var triangle = false
        var pentagon = false
    }

    struct ButtonFace {
        var top: Colour, bottom: Colour, stroke: Colour?, text: Colour, onText: Colour? = nil
    }

    struct Play {
        var square: Bool, radius: Double = 3
        var active: Colour, idle: Colour, activeGlyph: Colour, idleGlyph: Colour
    }

    private static func h(_ s: String) -> Colour { .hex(s) }
    private static func solid(_ c: String, amber: String = "#F2CC4D", red: String = "#F2453D") -> [Colour] {
        [h(c), h(c), h(c), h(c), h(amber), h(red)]
    }

    static let reaper = SkinStyle(
        dark: true,
        meterRamp: solid("#7DF0AB"), meterWell: h("#1A1A1A"), meterHold: h("#7DF0AB"),
        squareMeters: true, scaleBetween: true,
        fader: Fader(capWidth: 11, capHeight: 17, capRadius: 1.5, capTop: Colour(0.86, 0.86, 0.86),
                     capBottom: Colour(0.58, 0.58, 0.58), capStroke: Colour(0.12, 0.12, 0.12),
                     gripLines: -1, gripColour: Colour(0.18, 0.18, 0.18), groove: h("#1A1A1A"),
                     grooveHeight: 3, fillsGroove: false),
        buttonRadius: 2, chipRadius: 2,
        buttonFace: ButtonFace(top: Colour(0.24, 0.25, 0.26), bottom: Colour(0.20, 0.21, 0.22),
                               stroke: Colour(0.05, 0.05, 0.05), text: Colour(0.80, 0.80, 0.80)),
        play: Play(square: true, active: Colour(0.24, 0.77, 0.43), idle: .black,
                   activeGlyph: Colour(0.1, 0.1, 0.1), idleGlyph: Colour(0.87, 0.87, 0.87)))

    static let lojick = SkinStyle(
        dark: true, window: h("#2B2B2D"), panel: h("#3A3A3C"),
        meterRamp: [h("#3FD65C"), h("#3FD65C"), h("#3FD65C"), h("#E3DD45"), h("#F2A33A"), h("#FF3B30")],
        meterWell: h("#141414"), meterHold: h("#E8E8E8"), squareMeters: true,
        fader: Fader(capWidth: 13, capHeight: 20, capRadius: 2, capTop: h("#E6E6E6"), capBottom: h("#8C8C8C"),
                     capStroke: h("#1E1E1E"), gripLines: 3, gripColour: h("#6A6A6A"), groove: h("#111111"),
                     grooveHeight: 3, fillsGroove: false),
        buttonRadius: 3, chipRadius: 3,
        buttonFace: ButtonFace(top: h("#5C5C5E"), bottom: h("#4E4E50"), stroke: h("#262628"), text: h("#DCDCDC")),
        play: Play(square: true, active: h("#34C759"), idle: h("#4E4E50"), activeGlyph: .white, idleGlyph: h("#DCDCDC")),
        mute: h("#4299BD"), solo: h("#D9B900"))

    static let abletron = SkinStyle(
        dark: false, window: h("#A3A3A3"), panel: h("#B4B4B4"),
        warning: h("#6B2A00"), chipText: h("#111111"),
        meterRamp: [h("#00F758"), h("#00F758"), h("#00F758"), h("#FFD100"), h("#FF0A0A"), h("#FF0A0A")],
        meterWell: h("#262626"), meterHold: h("#E0E0E0"), squareMeters: true,
        fader: Fader(capWidth: 10, capHeight: 9, capRadius: 0, capTop: h("#2A2A2A"), capBottom: h("#2A2A2A"),
                     capStroke: nil, gripLines: 0, gripColour: .black, groove: h("#5A5A5A"),
                     grooveHeight: 1.5, fillsGroove: false, triangle: true),
        buttonRadius: 0, chipRadius: 0,
        buttonFace: ButtonFace(top: h("#C8C8C8"), bottom: h("#C8C8C8"), stroke: h("#6E6E6E"), text: h("#111111"), onText: h("#111111")),
        play: Play(square: true, radius: 0, active: h("#00D38D"), idle: h("#C8C8C8"), activeGlyph: h("#111111"), idleGlyph: h("#111111")),
        mute: h("#F7B92E"), solo: h("#6FB3E8"))

    static let wise = SkinStyle(
        dark: true, window: h("#333333"), panel: h("#2B2B2B"),
        meterRamp: [h("#6CBE4C"), h("#6CBE4C"), h("#6CBE4C"), h("#6CBE4C"), h("#F8DE35"), h("#DA332B")],
        meterWell: h("#232323"), meterHold: h("#8FD46E"), squareMeters: true,
        fader: Fader(capWidth: 10, capHeight: 16, capRadius: 1, capTop: h("#D0D0D0"), capBottom: h("#B4B4B4"),
                     capStroke: h("#0A0A0A"), gripLines: 0, gripColour: .black, groove: h("#1A1A1A"),
                     grooveHeight: 3, fillsGroove: true, grooveFill: h("#DB9951")),
        buttonRadius: 2, chipRadius: 2,
        buttonFace: ButtonFace(top: h("#454545"), bottom: h("#3C3C3C"), stroke: h("#1E1E1E"), text: h("#D0D0D0"), onText: h("#111111")),
        play: Play(square: true, active: h("#0597FF"), idle: h("#454545"), activeGlyph: .white, idleGlyph: h("#D0D0D0")),
        mute: h("#5E9BF5"), solo: h("#D9C43A"))

    static let fnod = SkinStyle(
        dark: true, window: h("#2E2E2E"), panel: h("#262626"),
        meterRamp: [h("#5ED12F"), h("#5ED12F"), h("#5ED12F"), h("#B8C82A"), h("#E18716"), h("#F2141F")],
        meterWell: h("#1E2A18"),
        wellRamp: [h("#1F3A16"), h("#1F3A16"), h("#3A3A16"), h("#3A3016"), h("#3A1616"), h("#3A1616")],
        meterHold: h("#E6E043"), squareMeters: true,
        fader: Fader(capWidth: 14, capHeight: 14, capRadius: 1, capTop: h("#F2F2F2"), capBottom: h("#D8D8D8"),
                     capStroke: h("#4A4A4A"), gripLines: 0, gripColour: .black, groove: h("#1A1A1A"),
                     grooveHeight: 2, fillsGroove: false, pentagon: true),
        buttonRadius: 2, chipRadius: 2,
        buttonFace: ButtonFace(top: h("#DCDCDC"), bottom: h("#C4C4C4"), stroke: h("#1A1A1A"), text: h("#111111"), onText: h("#111111")),
        play: Play(square: true, active: h("#6CC04A"), idle: h("#DCDCDC"), activeGlyph: h("#111111"), idleGlyph: h("#111111")),
        mute: h("#E66A3A"), solo: h("#E6E043"))

    static let midtools = SkinStyle(
        dark: true, window: h("#3C3C3E"), panel: h("#2E2E30"), figureText: h("#5BE05B"),
        meterRamp: [h("#2ECB46"), h("#2ECB46"), h("#2ECB46"), h("#E8D83A"), h("#F0962A"), h("#FF3B30")],
        meterWell: h("#000000"), meterHold: h("#E8D83A"), squareMeters: true, segmentPitch: 2,
        fader: Fader(capWidth: 12, capHeight: 20, capRadius: 1, capTop: h("#C4C4C4"), capBottom: h("#7E7E7E"),
                     capStroke: h("#141414"), gripLines: 4, gripColour: h("#3A3A3A"), groove: h("#000000"),
                     grooveHeight: 4, fillsGroove: false),
        buttonRadius: 3, chipRadius: 3,
        buttonFace: ButtonFace(top: h("#5E5E60"), bottom: h("#505052"), stroke: h("#1E1E1E"), text: h("#E0E0E0"), onText: h("#111111")),
        play: Play(square: true, active: h("#3DC85A"), idle: h("#505052"), activeGlyph: h("#111111"), idleGlyph: h("#E0E0E0")),
        mute: h("#F0962A"), solo: h("#E8D83A"))

    static let bitlick = SkinStyle(
        dark: true, window: h("#262626"), panel: h("#1E1E1E"), figureText: h("#FF9A2E"),
        meterRamp: [h("#7ED23A"), h("#7ED23A"), h("#A8D83A"), h("#E6D244"), h("#FF8C1A"), h("#F2453D")],
        meterWell: h("#141414"), meterHold: h("#FF8C1A"), squareMeters: true,
        fader: Fader(capWidth: 8, capHeight: 14, capRadius: 1.5, capTop: h("#B0B0B0"), capBottom: h("#B0B0B0"),
                     capStroke: nil, gripLines: 0, gripColour: .black, groove: h("#141414"),
                     grooveHeight: 2, fillsGroove: true, grooveFill: h("#FF8C1A")),
        buttonRadius: 2, chipRadius: 2,
        buttonFace: ButtonFace(top: h("#3A3A3A"), bottom: h("#3A3A3A"), stroke: nil, text: h("#D0D0D0"), onText: h("#111111")),
        play: Play(square: true, active: h("#56C45F"), idle: h("#3A3A3A"), activeGlyph: h("#111111"), idleGlyph: h("#D0D0D0")),
        mute: h("#FF8C1A"), solo: h("#E6D244"))

    static let rogue = SkinStyle(
        dark: false, window: h("#ECECEC"), panel: h("#E2E2E2"),
        meterRamp: [h("#FF9500"), h("#FF9500"), h("#FF9500"), h("#FF9500"), h("#FF6A00"), h("#F2453D")],
        meterWell: h("#FFE0B0"), meterHold: h("#FF6A00"),
        fader: Fader(capWidth: 15, capHeight: 15, capRadius: 7.5, capTop: .white, capBottom: h("#F2F2F2"),
                     capStroke: h("#B8B8B8"), gripLines: 0, gripColour: .black, groove: h("#C8C8C8"),
                     grooveHeight: 4, fillsGroove: true, grooveFill: h("#F5B82E")),
        buttonRadius: 10, chipRadius: 6,
        buttonFace: ButtonFace(top: h("#33A6E2"), bottom: h("#2594D0"), stroke: nil, text: .white, onText: .white),
        play: Play(square: false, active: h("#FF9500"), idle: h("#2A9FDB"), activeGlyph: .white, idleGlyph: .white),
        mute: h("#FF5A36"), solo: h("#FF9500"))

    static let audatown = SkinStyle(
        dark: false, window: h("#E4E4E4"), panel: h("#D8D8D8"),
        meterRamp: [h("#74D86A"), h("#74D86A"), h("#74D86A"), h("#74D86A"), h("#E3C23A"), h("#E0453A")],
        meterWell: .white, meterHold: h("#2A6FDB"), squareMeters: true, scaleBetween: true,
        fader: Fader(capWidth: 11, capHeight: 11, capRadius: 5.5, capTop: .white, capBottom: .white,
                     capStroke: h("#555555"), gripLines: 0, gripColour: .black, groove: h("#6E6E6E"),
                     grooveHeight: 1, fillsGroove: false),
        buttonRadius: 3, chipRadius: 3,
        buttonFace: ButtonFace(top: h("#7474EA"), bottom: h("#6868E0"), stroke: nil, text: .white, onText: .white),
        play: Play(square: true, active: h("#3AA850"), idle: h("#D8D8D8"), activeGlyph: .white, idleGlyph: h("#3AA850")),
        mute: h("#3E3EB8"), solo: h("#3E3EB8"))
}

/// Every colour the window draws with, worked out once when the scheme or the appearance
/// changes rather than on each frame.
struct Palette {
    let dark: Bool
    let skin: SkinStyle

    let window: Colour          // the ground
    let panel: Colour           // the signal panel and the sidebars
    let text: Colour            // primary text
    let secondary: Colour       // Color.secondary
    let muted: Colour           // Color.mutedLabel
    let label: Colour           // what the Mac's `Color.primary.opacity(…)` fills are taken over
    let active: Colour          // the theme's Active, legible on this appearance
    let solo: Colour            // fills
    let soloText: Colour        // solo as text, darkened on light
    let mute: Colour
    let warning: Colour
    let red = Colour(0.92, 0.27, 0.23)
    let green: Colour
    let delta = Colour(0.91, 0.42, 0.76)

    /// The Mac's `Color.primary.opacity(x)` over the ground.
    func fill(_ x: Double) -> Colour { window.over(label, x) }
    func fill(_ x: Double, on ground: Colour) -> Colour { ground.over(label, x) }

    var divider: Colour { fill(dark ? 0.12 : 0.13) }
    var hairline: Colour { fill(dark ? 0.08 : 0.09) }

    static func make(appearance: Appearance, themeEnabled: Bool, primaryHex: String, secondaryHex: String,
                     systemDark: Bool, systemAccent: Colour) -> Palette {
        let skinKind = Skin.forScheme(enabled: themeEnabled, primary: primaryHex, secondary: secondaryHex)
        let skin = skinKind.style
        let dark: Bool = skin.dark ?? {
            switch appearance {
            case .system: return systemDark
            case .light: return false
            case .dark: return true
            }
        }()
        // The Mac's window grounds: macOS's dark and light window colours.
        let base = dark ? Colour(0.118, 0.118, 0.122) : Colour(0.925, 0.925, 0.925)
        let label: Colour = dark ? .white : .black
        var window = base
        if themeEnabled, let primary = Colour(hex: primaryHex) {
            window = skin.window ?? base.over(primary, dark ? 0.22 : 0.13)
        }
        let panel = skin.panel ?? window.over(label, 0.03)
        let activeBase = themeEnabled ? (Colour(hex: secondaryHex) ?? systemAccent) : systemAccent
        let active = themeEnabled ? activeBase.legible(dark: dark) : activeBase
        let yellow = Colour(1.0, 0.80, 0.0)
        let orange = Colour(1.0, 0.58, 0.0)
        return Palette(dark: dark, skin: skin, window: window, panel: panel,
                       text: dark ? Colour(0.93, 0.93, 0.94) : Colour(0.11, 0.11, 0.12),
                       secondary: window.over(label, 0.55),
                       muted: window.over(label, 0.66),
                       label: label,
                       active: active,
                       solo: skin.solo ?? yellow,
                       soloText: (skin.solo ?? yellow).legible(dark: dark),
                       mute: skin.mute ?? Colour(0.92, 0.27, 0.23),
                       warning: skin.warning ?? orange.legible(dark: dark),
                       green: Colour(0.20, 0.78, 0.35).legible(dark: dark))
    }

    /// The transports' own colours, which a theme never changes.
    func tint(for source: DiscoverySourceTint) -> Colour {
        let base: Colour
        switch source {
        case .ravenna: base = Colour(0.36, 0.62, 0.94)
        case .dante:   base = Colour(0.36, 0.78, 0.55)
        case .sap:     base = Colour(0.75, 0.60, 0.95)
        case .manual:  return secondary
        case .vban:    base = Colour(0.94, 0.56, 0.40)
        case .scream:  base = Colour(0.86, 0.44, 0.66)
        case .web:     base = Colour(0.42, 0.70, 0.72)
        }
        return base.legible(dark: dark)
    }

    // MARK: Meters

    /// The bar colour at a fraction of the −60 dB scale: green to −18, amber by −6, red above −1,
    /// as the Mac's `meterStops` — or the skin's ramp at its stops.
    func meterColour(at fraction: Double) -> Colour {
        if let ramp = skin.meterRamp {
            let stops = [0, 0.70, 0.80, 0.90, 0.983, 1.0]
            return Self.ramp(ramp, stops, fraction)
        }
        let stops = [0.0, 0.70, 0.80, 0.90, 0.983, 1.0]
        let colours = [Colour(0.20, 0.78, 0.35), Colour(0.20, 0.78, 0.35), Colour(1.0, 0.80, 0.0),
                       Colour(1.0, 0.58, 0.0), Colour(1.0, 0.23, 0.19), Colour(1.0, 0.23, 0.19)]
        return Self.ramp(colours, stops, fraction)
    }

    func wellColour(at fraction: Double, dimmed: Bool = false) -> Colour {
        if let ramp = skin.wellRamp { return Self.ramp(ramp, [0, 0.70, 0.80, 0.90, 0.983, 1.0], fraction) }
        return skin.meterWell ?? fill(dimmed ? 0.05 : 0.10)
    }

    var meterHold: Colour { skin.meterHold ?? fill(0.6) }

    private static func ramp(_ colours: [Colour], _ stops: [Double], _ x: Double) -> Colour {
        let x = max(0, min(1, x))
        for i in 1..<stops.count where x <= stops[i] {
            let span = stops[i] - stops[i - 1]
            let t = span > 0 ? (x - stops[i - 1]) / span : 0
            return colours[i - 1].over(colours[i], t)
        }
        return colours.last!
    }
}

/// The transports, as the engine's `DiscoverySource` names them, without importing the engine
/// into the look.
enum DiscoverySourceTint { case ravenna, dante, sap, manual, vban, scream, web }

// MARK: - What Windows says

enum SystemLook {
    /// Whether Windows is set to dark for apps (Settings → Personalisation → Colours).
    static var prefersDark: Bool {
        var value: DWORD = 1
        var size = DWORD(MemoryLayout<DWORD>.size)
        let key = "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"
        let status = key.withCString(encodedAs: UTF16.self) { k in
            "AppsUseLightTheme".withCString(encodedAs: UTF16.self) { v in
                RegGetValueW(HKEY_CURRENT_USER, k, v, DWORD(RRF_RT_REG_DWORD), nil, &value, &size)
            }
        }
        return status == ERROR_SUCCESS ? value == 0 : true
    }

    /// Windows' accent colour, which is what "the system's own colours" means here. Read from the
    /// registry, as the accent the user picked: `DwmGetColorizationColor` gives the title-bar
    /// colorization instead, which is often grey. A grey accent, or none, gives
    /// the Mac's orange, so active things still stand out.
    static var accent: Colour {
        let macOrange = Colour(1.0, 0.58, 0.0)
        for (key, value) in [("Software\\Microsoft\\Windows\\DWM", "AccentColor"),
                             ("Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Accent", "AccentColorMenu")] {
            var abgr: DWORD = 0
            var size = DWORD(MemoryLayout<DWORD>.size)
            let status = key.withCString(encodedAs: UTF16.self) { k in
                value.withCString(encodedAs: UTF16.self) { v in
                    RegGetValueW(HKEY_CURRENT_USER, k, v, DWORD(RRF_RT_REG_DWORD), nil, &abgr, &size)
                }
            }
            guard status == ERROR_SUCCESS else { continue }
            let c = Colour(Double(abgr & 0xFF) / 255, Double((abgr >> 8) & 0xFF) / 255,
                           Double((abgr >> 16) & 0xFF) / 255)
            return c.hsb.s < 0.25 || c.hsb.b < 0.15 ? macOrange : c
        }
        return macOrange
    }
}
