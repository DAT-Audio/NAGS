import SwiftUI
import AppKit

// The looks, each "in the style of" an audio app's default
// look, under a parody name. Offered in the colour-scheme picker below the colour-only schemes.
// Each brings its own controls, surfaces and light or dark.
//
// Round 2 is drawn from screenshots of each app, with exact values
// where the apps' theme data gave them: Wwise's dark theme file, FMOD Studio's style strings,
// Logic's asset catalogue (mute #4299BD, solo #B39500) and Ableton Live 12's theme file (play
// #00D38D, meters #00F758 / #FFD100 / #FF0A0A). Each skin sets its surfaces as well as its
// controls — the window and panel grounds, and light or dark — because that is most of what
// makes one app look unlike another.

public extension ThemePreset {
    /// Schemes with their own look, listed after `all` in the picker. The primary is the skin's
    /// window colour, the secondary its accent.
    static let looks: [ThemePreset] = [
        // "Rea-Theme Default" (renamed from "Reaper Default"; saved by colour, so a
        // choice already made is unaffected). REAPER 7's default theme, from its own colour table:
        // the slate teal it selects with, and the grey-teal of its panels as the accent everywhere
        // (previously the teal-green #1ABC98 of a toolbar button that is on). This scheme also brings REAPER's look — see `Skin`.
        ThemePreset(name: "Rea-Theme Default",    primary: "#466168", secondary: "#6B7C83", skin: .reaper),
        ThemePreset(name: "Lojick",          primary: "#2B2B2D", secondary: "#5A8FE6", skin: .lojick),
        // Near-black accent: Live draws its text and controls black on grey; amber (kept for the
        // activator-style mute) could not be read as text on #A3A3A3.
        ThemePreset(name: "Abletron",        primary: "#A3A3A3", secondary: "#1E1E1E", skin: .abletron),
        ThemePreset(name: "Wise",            primary: "#333333", secondary: "#5E9BF5", skin: .wise),
        ThemePreset(name: "FNod",            primary: "#2E2E2E", secondary: "#E6E043", skin: .fnod),
        ThemePreset(name: "MidTools",        primary: "#3C3C3E", secondary: "#5BE05B", skin: .midtools),
        ThemePreset(name: "Bitlick",         primary: "#262626", secondary: "#FF8C1A", skin: .bitlick),
        ThemePreset(name: "RogueSingleCell", primary: "#ECECEC", secondary: "#FF9500", skin: .rogue),
        ThemePreset(name: "AudaTown",        primary: "#E4E4E4", secondary: "#6A6AE0", skin: .audatown),
    ]
}

extension SkinStyle {
    private static func c(_ hex: String) -> Color { Color(nsColor: .hex(hex)) }
    private static func face(_ top: String, _ bottom: String, stroke: String? = nil,
                             text: String, onText: String? = nil) -> ButtonFace {
        ButtonFace(top: c(top), bottom: c(bottom), stroke: stroke.map(c), text: c(text), onText: onText.map(c))
    }
    private static func play(_ active: String, _ idle: String, square: Bool = true, radius: CGFloat = 3,
                             activeGlyph: String, idleGlyph: String) -> PlayStyle {
        PlayStyle(square: square, radius: radius, active: c(active), idle: c(idle),
                  activeGlyph: c(activeGlyph), idleGlyph: c(idleGlyph))
    }

    /// Logic Pro: dark grey strips, rounded grey M / S / R buttons with the
    /// teal mute and gold solo from Logic's own assets, blue plug-in slots, a ribbed silver fader
    /// cap in a black slot, green meters in a black well.
    static let lojick = SkinStyle(
        appearance: .dark, window: .hex("#2B2B2D"), panel: .hex("#3A3A3C"),
        meterRamp: [.hex("#3FD65C"), .hex("#3FD65C"), .hex("#3FD65C"), .hex("#E3DD45"), .hex("#F2A33A"), .hex("#FF3B30")],
        meterWell: .hex("#141414"), meterHold: .hex("#E8E8E8"), squareMeters: true,
        fader: FaderStyle(capSize: CGSize(width: 13, height: 20), capRadius: 2,
                          capTop: .hex("#E6E6E6"), capBottom: .hex("#8C8C8C"), capStroke: .hex("#1E1E1E"),
                          grip: .lines(3), gripColour: .hex("#6A6A6A"), groove: .hex("#111111"),
                          grooveHeight: 3, fillsGroove: false),
        buttonRadius: 3, chipRadius: 3,
        buttonFace: face("#5C5C5E", "#4E4E50", stroke: "#262628", text: "#DCDCDC"),
        play: play("#34C759", "#4E4E50", activeGlyph: "#FFFFFF", idleGlyph: "#DCDCDC"),
        mute: c("#4299BD"), solo: c("#D9B900"))

    /// Ableton Live (the light grey look): flat mid-grey surfaces, square
    /// flat buttons with black letters, the amber track activator, bright green meters in a
    /// near-black well, a small dark pointer for the fader, a green play triangle.
    static let abletron = SkinStyle(
        appearance: .light, window: .hex("#A3A3A3"), panel: .hex("#B4B4B4"),
        // Dark enough to read on #A3A3A3, where orange status and coloured chip letters were hard to read.
        warning: c("#6B2A00"), chipText: c("#111111"),
        meterRamp: [.hex("#00F758"), .hex("#00F758"), .hex("#00F758"), .hex("#FFD100"), .hex("#FF0A0A"), .hex("#FF0A0A")],
        meterWell: .hex("#262626"), meterHold: .hex("#E0E0E0"), squareMeters: true,
        fader: FaderStyle(capSize: CGSize(width: 10, height: 9), capRadius: 0,
                          capTop: .hex("#2A2A2A"), capBottom: .hex("#2A2A2A"), capStroke: .clear,
                          grip: .none, gripColour: .clear, groove: .hex("#5A5A5A"),
                          grooveHeight: 1.5, fillsGroove: false, triangle: true),
        buttonRadius: 0, chipRadius: 0,
        buttonFace: face("#C8C8C8", "#C8C8C8", stroke: "#6E6E6E", text: "#111111", onText: "#111111"),
        play: play("#00D38D", "#C8C8C8", radius: 0, activeGlyph: "#111111", idleGlyph: "#111111"),
        mute: c("#F7B92E"), solo: c("#6FB3E8"))

    /// Wwise: dark grey, flat green meters with a light top edge in rounded
    /// dark wells, blue M, yellow S, square-ish buttons.
    static let wise = SkinStyle(
        appearance: .dark, window: .hex("#333333"), panel: .hex("#2B2B2B"),
        // A touch brighter than Wwise's #5DA540, which read too dark here.
        meterRamp: [.hex("#6CBE4C"), .hex("#6CBE4C"), .hex("#6CBE4C"), .hex("#6CBE4C"), .hex("#F8DE35"), .hex("#DA332B")],
        meterWell: .hex("#232323"), meterHold: .hex("#8FD46E"), squareMeters: true,
        fader: FaderStyle(capSize: CGSize(width: 10, height: 16), capRadius: 1,
                          capTop: .hex("#D0D0D0"), capBottom: .hex("#B4B4B4"), capStroke: .hex("#0A0A0A"),
                          grip: .none, gripColour: .clear, groove: .hex("#1A1A1A"),
                          grooveHeight: 3, fillsGroove: true, grooveFill: .hex("#DB9951")),
        buttonRadius: 2, chipRadius: 2,
        buttonFace: face("#454545", "#3C3C3C", stroke: "#1E1E1E", text: "#D0D0D0", onText: "#111111"),
        play: play("#0597FF", "#454545", activeGlyph: "#FFFFFF", idleGlyph: "#D0D0D0"),
        mute: c("#5E9BF5"), solo: c("#D9C43A"))

    /// FMOD Studio: dark, a yellow outline for what is selected, light grey
    /// SOLO / MUTE boxes with black letters, a white pointed fader head, and meters whose unlit
    /// part is zoned — dim green, dim olive, dim red — under a yellow peak line.
    static let fnod = SkinStyle(
        appearance: .dark, window: .hex("#2E2E2E"), panel: .hex("#262626"),
        meterRamp: [.hex("#5ED12F"), .hex("#5ED12F"), .hex("#5ED12F"), .hex("#B8C82A"), .hex("#E18716"), .hex("#F2141F")],
        meterWell: .hex("#1E2A18"),
        wellRamp: [.hex("#1F3A16"), .hex("#1F3A16"), .hex("#3A3A16"), .hex("#3A3016"), .hex("#3A1616"), .hex("#3A1616")],
        meterHold: .hex("#E6E043"), squareMeters: true,
        fader: FaderStyle(capSize: CGSize(width: 14, height: 14), capRadius: 1,
                          capTop: .hex("#F2F2F2"), capBottom: .hex("#D8D8D8"), capStroke: .hex("#4A4A4A"),
                          grip: .none, gripColour: .clear, groove: .hex("#1A1A1A"),
                          grooveHeight: 2, fillsGroove: false, pentagon: true),
        buttonRadius: 2, chipRadius: 2,
        buttonFace: face("#DCDCDC", "#C4C4C4", stroke: "#1A1A1A", text: "#111111", onText: "#111111"),
        play: play("#6CC04A", "#DCDCDC", activeGlyph: "#111111", idleGlyph: "#111111"),
        mute: c("#E66A3A"), solo: c("#E6E043"))

    /// Pro Tools: grey strips, segmented green meters with yellow and red
    /// at the top in black, grey S / M buttons (yellow and orange when on), a grey lined cap
    /// in a long slot, and green-on-black LCD figures.
    static let midtools = SkinStyle(
        appearance: .dark, window: .hex("#3C3C3E"), panel: .hex("#2E2E30"), figureText: c("#5BE05B"),
        meterRamp: [.hex("#2ECB46"), .hex("#2ECB46"), .hex("#2ECB46"), .hex("#E8D83A"), .hex("#F0962A"), .hex("#FF3B30")],
        meterWell: .hex("#000000"), meterHold: .hex("#E8D83A"), squareMeters: true, segmentPitch: 2,
        fader: FaderStyle(capSize: CGSize(width: 12, height: 20), capRadius: 1,
                          capTop: .hex("#C4C4C4"), capBottom: .hex("#7E7E7E"), capStroke: .hex("#141414"),
                          grip: .lines(4), gripColour: .hex("#3A3A3A"), groove: .hex("#000000"),
                          grooveHeight: 4, fillsGroove: false),
        buttonRadius: 3, chipRadius: 3,
        buttonFace: face("#5E5E60", "#505052", stroke: "#1E1E1E", text: "#E0E0E0", onText: "#111111"),
        play: play("#3DC85A", "#505052", activeGlyph: "#111111", idleGlyph: "#E0E0E0"),
        mute: c("#F0962A"), solo: c("#E8D83A"))

    /// Bitwig Studio: charcoal, orange everywhere that is on — the M button,
    /// values, knob arcs, the peak line — and meters running green to yellow to orange.
    static let bitlick = SkinStyle(
        appearance: .dark, window: .hex("#262626"), panel: .hex("#1E1E1E"), figureText: c("#FF9A2E"),
        meterRamp: [.hex("#7ED23A"), .hex("#7ED23A"), .hex("#A8D83A"), .hex("#E6D244"), .hex("#FF8C1A"), .hex("#F2453D")],
        meterWell: .hex("#141414"), meterHold: .hex("#FF8C1A"), squareMeters: true,
        fader: FaderStyle(capSize: CGSize(width: 8, height: 14), capRadius: 1.5,
                          capTop: .hex("#B0B0B0"), capBottom: .hex("#B0B0B0"), capStroke: .clear,
                          grip: .none, gripColour: .clear, groove: .hex("#141414"),
                          grooveHeight: 2, fillsGroove: true, grooveFill: .hex("#FF8C1A")),
        buttonRadius: 2, chipRadius: 2,
        buttonFace: face("#3A3A3A", "#3A3A3A", text: "#D0D0D0", onText: "#111111"),
        play: play("#56C45F", "#3A3A3A", activeGlyph: "#111111", idleGlyph: "#D0D0D0"),
        mute: c("#FF8C1A"), solo: c("#E6D244"))

    /// Audio Hijack: a light window, rounded blue blocks, capsule buttons —
    /// blue "Run", orange "Stop" — yellow-orange sliders with a white round knob, orange meters.
    static let rogue = SkinStyle(
        appearance: .light, window: .hex("#ECECEC"), panel: .hex("#E2E2E2"),
        meterRamp: [.hex("#FF9500"), .hex("#FF9500"), .hex("#FF9500"), .hex("#FF9500"), .hex("#FF6A00"), .hex("#F2453D")],
        meterWell: .hex("#FFE0B0"), meterHold: .hex("#FF6A00"),
        fader: FaderStyle(capSize: CGSize(width: 15, height: 15), capRadius: 7.5,
                          capTop: .hex("#FFFFFF"), capBottom: .hex("#F2F2F2"), capStroke: .hex("#B8B8B8"),
                          grip: .none, gripColour: .clear, groove: .hex("#C8C8C8"),
                          grooveHeight: 4, fillsGroove: true, grooveFill: .hex("#F5B82E")),
        buttonRadius: 10, chipRadius: 6,
        buttonFace: face("#33A6E2", "#2594D0", text: "#FFFFFF", onText: "#FFFFFF"),
        play: play("#FF9500", "#2A9FDB", square: false, activeGlyph: "#FFFFFF", idleGlyph: "#FFFFFF"),
        mute: c("#FF5A36"), solo: c("#FF9500"))

    /// Audacity: light grey toolbars, filled blue-violet Mute / Solo
    /// buttons with white letters, green horizontal meters in a white well, a thin line with a
    /// white round knob, a green play triangle on a grey button.
    static let audatown = SkinStyle(
        appearance: .light, window: .hex("#E4E4E4"), panel: .hex("#D8D8D8"),
        meterRamp: [.hex("#74D86A"), .hex("#74D86A"), .hex("#74D86A"), .hex("#74D86A"), .hex("#E3C23A"), .hex("#E0453A")],
        meterWell: .hex("#FFFFFF"), meterHold: .hex("#2A6FDB"), squareMeters: true, scale: .between,
        fader: FaderStyle(capSize: CGSize(width: 11, height: 11), capRadius: 5.5,
                          capTop: .hex("#FFFFFF"), capBottom: .hex("#FFFFFF"), capStroke: .hex("#555555"),
                          grip: .none, gripColour: .clear, groove: .hex("#6E6E6E"),
                          grooveHeight: 1, fillsGroove: false),
        buttonRadius: 3, chipRadius: 3,
        buttonFace: face("#7474EA", "#6868E0", text: "#FFFFFF", onText: "#FFFFFF"),
        play: play("#3AA850", "#D8D8D8", activeGlyph: "#FFFFFF", idleGlyph: "#3AA850"),
        mute: c("#3E3EB8"), solo: c("#3E3EB8"))
}
