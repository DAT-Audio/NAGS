import SwiftUI
import AppKit

/// How the app's own controls are drawn, beyond their colours.
///
/// A colour scheme only recolours; a **skin** changes shapes too — meter bars, fader caps, button
/// faces, the play button, the master meter's scale. Each skin is a `SkinStyle`: data, not code,
/// so a new look is a new set of values and the views that draw it do not change. `.standard` is
/// the app as it has always been; each other skin goes with its own colour scheme only.
///
/// **Costs nothing per frame.** SwiftUI views read the skin from the environment, which changes
/// only when the scheme does; the AppKit meters and sliders read `Skin.current`, and the meters
/// fold it into the geometry key they already compare, so a change rebuilds them once.
public enum Skin: String, CaseIterable, Equatable, Sendable {
    case standard
    case reaper
    // The looks in the style of Logic Pro, Ableton Live, Wwise, FMOD Studio, Pro Tools, Bitwig
    // Studio, Audio Hijack and Audacity. See `SkinLooks.swift`.
    case lojick, abletron, wise, fnod, midtools, bitlick, rogue, audatown

    /// The skin a scheme brings: its preset's, when the colours are one of the skinned presets.
    public static func `for`(enabled: Bool, primary: String, secondary: String) -> Skin {
        guard enabled else { return .standard }
        let presets: [ThemePreset] = ThemePreset.all + ThemePreset.looks
        for preset in presets where preset.primary.caseInsensitiveCompare(primary) == .orderedSame
            && preset.secondary.caseInsensitiveCompare(secondary) == .orderedSame {
            return preset.skin
        }
        return .standard
    }

    /// For the AppKit-drawn controls, which cannot read the environment. Set by each app's root
    /// view whenever its scheme changes; main thread only.
    nonisolated(unsafe) public static var current: Skin = .standard

    public var style: SkinStyle {
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

    // Shorthands the views use.
    public var buttonRadius: CGFloat { style.buttonRadius }
    public var chipRadius: CGFloat? { style.chipRadius }
    public var squareMeters: Bool { style.squareMeters }
}

/// Everything a skin decides. `nil` in an optional field means "as the standard look".
public struct SkinStyle {
    // Surfaces — what most of an app's identity is.
    /// Light or dark, whatever the Appearance setting says: Audio Hijack and Audacity are light.
    public var appearance: ColorScheme? = nil
    /// The window's ground, opaque. nil: the scheme's translucent wash over the system window.
    public var window: NSColor? = nil
    /// The signal panel's and the source sidebar's ground.
    public var panel: NSColor? = nil
    /// The output figures' colour — Pro Tools' green LCD, Bitwig's orange values.
    public var figureText: Color? = nil
    /// Warnings in words ("No packets", "Asking…"), where the standard orange cannot be read on
    /// the skin's ground (Abletron's mid-grey).
    public var warning: Color? = nil
    /// Chip letters, with a stronger fill behind them, where coloured letters cannot be read.
    public var chipText: Color? = nil

    // Meters
    /// Six colours at the ramp's stops (0, 0.70, 0.80, 0.90, 0.983, 1 of the −60 dB scale).
    /// nil: the standard green, amber, red.
    public var meterRamp: [NSColor]? = nil
    /// The unlit part of a bar. nil: a faint tint of the label colour.
    public var meterWell: NSColor? = nil
    /// An unlit bar in zones — dim green, dim yellow, dim red, as FMOD's — at the ramp's stops.
    public var wellRamp: [NSColor]? = nil
    /// The peak-hold tick. nil: the label colour.
    public var meterHold: NSColor? = nil
    public var squareMeters = false
    /// Segmented meters (Logic, Pro Tools): a gap of the well's colour every this many points.
    public var segmentPitch: CGFloat? = nil
    public var scale: ScalePlacement = .beside

    // Fader
    public var fader: FaderStyle? = nil

    // Buttons and chips
    public var buttonRadius: CGFloat = 5
    public var chipRadius: CGFloat? = nil
    public var buttonFace: ButtonFace? = nil

    // Play / stop
    public var play: PlayStyle? = nil

    // Mute and solo, where the app's colours differ from the red and yellow used otherwise.
    public var mute: Color? = nil
    public var solo: Color? = nil

    public enum ScalePlacement { case beside, between }

    public struct FaderStyle {
        public var capSize: CGSize
        public var capRadius: CGFloat
        public var capTop: NSColor
        public var capBottom: NSColor
        public var capStroke: NSColor
        public var grip: Grip
        public var gripColour: NSColor
        public var groove: NSColor
        public var grooveHeight: CGFloat
        /// Fill the groove with the active colour up to the cap, as the standard slider does.
        public var fillsGroove: Bool
        /// The fill's own colour, where the app has one (Wwise's orange value line).
        public var grooveFill: NSColor? = nil
        /// A pointer rather than a cap (Ableton's).
        public var triangle = false
        /// A cap with a point, as FMOD's white fader head.
        public var pentagon = false
        public enum Grip { case none, centreLine, lines(Int) }
    }

    public struct ButtonFace {
        public var top: Color
        public var bottom: Color
        public var stroke: Color?
        public var text: Color
        /// Letters on a button that is on, where the tint's own readable colour is not the app's.
        public var onText: Color? = nil
    }

    public struct PlayStyle {
        public var square: Bool
        public var radius: CGFloat = 3
        public var active: Color
        public var idle: Color
        public var activeGlyph: Color
        public var idleGlyph: Color
    }
}

public extension NSColor {
    /// `#RRGGBB` as an sRGB colour, for the skins' tables.
    static func hex(_ s: String, alpha: CGFloat = 1) -> NSColor {
        var v: UInt64 = 0
        Scanner(string: s.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }
}

extension SkinStyle {
    /// One colour until the last few dB, then amber and red — how most DAWs colour a meter.
    static func solid(_ colour: String, amber: String = "#F2CC4D", red: String = "#F2453D") -> [NSColor] {
        let c = NSColor.hex(colour)
        return [c, c, c, c, .hex(amber), .hex(red)]
    }

    /// Rea-Theme Default: REAPER 7's square mint meters in a near-black well, fader caps in dark
    /// grooves, near-square bevelled buttons, a green-or-black square play button, and the scale
    /// between the master's bars.
    static let reaper = SkinStyle(
        // Drawn dark only, as every skinned scheme is one appearance.
        appearance: .dark,
        meterRamp: solid("#7DF0AB"), meterWell: .hex("#1A1A1A"), meterHold: .hex("#7DF0AB"),
        squareMeters: true, scale: .between,
        fader: FaderStyle(capSize: CGSize(width: 11, height: 17), capRadius: 1.5,
                          capTop: NSColor(white: 0.86, alpha: 1), capBottom: NSColor(white: 0.58, alpha: 1),
                          capStroke: NSColor(white: 0.12, alpha: 0.9), grip: .centreLine,
                          gripColour: NSColor(white: 0.18, alpha: 1), groove: .hex("#1A1A1A"),
                          grooveHeight: 3, fillsGroove: false),
        buttonRadius: 2, chipRadius: 2,
        buttonFace: ButtonFace(top: Color(red: 0.24, green: 0.25, blue: 0.26),
                               bottom: Color(red: 0.24, green: 0.25, blue: 0.26).opacity(0.75),
                               stroke: Color.black.opacity(0.55), text: Color.white.opacity(0.78)),
        play: PlayStyle(square: true, active: Color(red: 0.24, green: 0.77, blue: 0.43), idle: .black,
                        activeGlyph: Color.black.opacity(0.8), idleGlyph: Color.white.opacity(0.85)))
}

private struct SkinKey: EnvironmentKey { static let defaultValue: Skin = .standard }

public extension EnvironmentValues {
    var skin: Skin {
        get { self[SkinKey.self] }
        set { self[SkinKey.self] = newValue }
    }
}

public extension ThemePreset {
    static var reaperDefault: ThemePreset { looks.first { $0.skin == .reaper }! }
}
