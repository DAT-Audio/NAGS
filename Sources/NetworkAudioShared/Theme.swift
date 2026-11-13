import SwiftUI
import AppKit

// MARK: - The rule about de-emphasised text
//
// **Nothing in this app uses `.tertiary` or `.quaternary` for text.** They read as the obvious
// way to mark a label as secondary information, and on a dense interface they are used
// everywhere — which is how all thirty-nine of them came to be here. They cannot pass contrast:
// SwiftUI's hierarchical styles resolve to roughly 55 %, 25 % and 10 % of the label colour, so
// below `.secondary` no combination of foreground and background reaches 4.5:1. Measured before
// the change: section headers 2.47:1 in dark and 1.65:1 in light, column titles 1.50:1 and
// 1.19:1, against a 4.5:1 requirement — and at 7 to 9 points they are far too small to claim
// the 3:1 large-text allowance.
//
// So hierarchy is carried by **size and weight**, which cost nothing in contrast: a 9-point
// bold rounded capital and a 15-point medium figure read as different levels at the same
// colour. `Tools/measure_contrast.swift` re-checks this against a render.
//
// `.secondary` is not quite enough either, and only in one theme: the same 55 % lands on a
// near-black ground in dark mode (5.5:1, fine) and a near-white one in light (3.1:1, short).
// So labels use `Color.mutedLabel`, which is the same idea with a value per appearance.

public extension Color {
    /// Delta monitoring. Fixed rather than themeable, and magenta rather than any hue already
    /// in use: it has to stay distinct from Active (which the user chooses), from bypass amber
    /// and from the transport tints, because while it is lit you are not hearing the programme
    /// at all. Shared, so Δ is the same colour in the Sender.
    static let delta = Color(red: 0.91, green: 0.42, blue: 0.76)

    /// Text that names something — section headers, column titles, units, field labels.
    ///
    /// De-emphasised enough to sit under the figures it labels, dark or light enough to be
    /// read. Defined per appearance because a single alpha cannot do both; `NSColor`'s dynamic
    /// provider resolves it at draw time, so it follows a theme change without the views
    /// knowing anything about it.
    static let mutedLabel = Color(nsColor: .mutedLabel)
}

public extension NSColor {
    /// The same value for the AppKit-drawn meter labels, which cannot reach a SwiftUI style.
    static let mutedLabel = NSColor(name: "mutedLabel") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.66)
            // 0.66 rather than 0.62: the AppKit-drawn meter labels render a shade lighter
            // than the SwiftUI ones at the same alpha, and 0.62 left them at 4.34:1 — passing
            // everywhere except the one place the value was hardest to see.
            : NSColor(white: 0, alpha: 0.66)
    }
}

/// User-chosen colours.
///
/// Two roles, and they are not both accents:
///
/// * **primary** is the *window*. When theming is on it washes every surface — the list ground,
///   the toolbar, the signal panel, the compact window — so an ultramarine theme means a
///   lightened ultramarine window with the panel areas sitting slightly darker, instead of white
///   with off-white panels. It is applied as a translucent wash over the appearance's own
///   background rather than as a flat fill, which is what keeps the existing shading intact:
///   every `Color.primary.opacity(…)` overlay in the app still darkens in light mode and
///   lightens in dark mode, exactly as before, just over a tinted ground.
/// * **secondary** is *active*: a source you are listening to, its stop button, the `ACTIVE`
///   filter, the panel toggle, MONO, and the sliders.
///
/// Everything else keeps the colour it has, because its colour is information rather than
/// decoration, and letting it be overridden would make the app lie:
///
/// | Fixed | Why |
/// | --- | --- |
/// | Meter green / amber / red | The colour *is* the level. Green to −18 dBFS, amber to −6, red above. |
/// | RAVENNA blue, Dante green, SAP violet | They identify the transport a stream arrived on. |
/// | Solo yellow | Solo is yellow in every DAW there is, and it has to stay distinct from the active colour — which is now themeable. |
/// | Delta magenta | While delta is lit you are hearing a difference, not the programme. It has to be unmistakable, and distinct from the active colour the user picked. |
/// | Mute red, clip red | Danger, and conventionally red. |
/// | Warning amber, DIM amber | Matches the banner and log conventions. |
///
/// The text hierarchy and the dividers are untouched and still follow light/dark.
public struct ThemePreset: Identifiable, Hashable {
    public let name: String
    public let primary: String
    public let secondary: String
    /// The look that comes with the scheme (`Skin`); `.standard` for the colour-only schemes.
    public let skin: Skin

    public var id: String { name }

    public init(name: String, primary: String, secondary: String, skin: Skin = .standard) {
        self.name = name; self.primary = primary; self.secondary = secondary; self.skin = skin
    }

    /// The render harnesses' colours: the standard preset, or `NAG_PREVIEW_THEME="#primary,#secondary"`
    /// to try a proposed scheme on the real windows before it is offered.
    public static var harness: ThemePreset {
        let parts = (ProcessInfo.processInfo.environment["NAG_PREVIEW_THEME"] ?? "")
            .split(separator: ",").map(String.init)
        guard parts.count == 2 else { return standard }
        return ThemePreset(name: "Preview", primary: parts[0], secondary: parts[1])
    }

    /// Deliberately short. These are starting points; the colour pickers are right beside them.
    public static let all: [ThemePreset] = [
        ThemePreset(name: "Ultramarine & Canary", primary: "#2B44C7", secondary: "#F5D90A"),
        // Classic coral (16°) rather than #FF6F5E (6°), which sat on top of Mute's red.
        ThemePreset(name: "Teal & Coral",         primary: "#0E8C8C", secondary: "#FF7F50"),
        ThemePreset(name: "Plum & Gold",          primary: "#7A3E8F", secondary: "#E0A526"),
        ThemePreset(name: "Slate & Lime",         primary: "#41596E", secondary: "#A8CF38"),
        ThemePreset(name: "Graphite & Amber",     primary: "#4A4A4F", secondary: "#F0A028"),
    ]

    /// What a fresh install starts with.
    public static let standard = all.first { $0.name == "Graphite & Amber" }!
    /// The colours theming fell back to before that, when it was off by default. Kept so an
    /// install that switched theming on without picking colours keeps the ones it has had.
    public static let previousFallback = all[0]
}

/// Theme colours that adapt to light and dark by themselves.
///
/// Canary, gold and lime were chosen for dark windows; on a light one they washed out — pale
/// pills, pale switches and sliders, pale menu text — because most of the app draws the raw
/// colour and only a few glyphs went through `legible(on:)`. So the colour itself is made
/// appearance-dependent: the chosen colour in dark mode, and in light mode the same hue darkened
/// by `legible(on: .light)` (canary lands on gold, gold on ochre, lime on olive). Every use —
/// `.tint`, fills, strokes, labels — resolves the right one with no change at the call site.
///
/// **Made once per colour.** A dynamic `NSColor` is resolved on every draw, so the provider only
/// picks between two colours computed here, and each hex is computed once and cached.
public enum ThemeColors {
    private static var cache: [String: Color] = [:]
    /// Low enough that the darkened colour holds about 3:1 against a light, tinted window —
    /// the contrast macOS asks of controls — while still reading as the colour picked.
    static let lightTarget = 0.26

    /// The adaptive version of `base`, keyed by `key` (its hex, or a name).
    public static func adaptive(_ base: Color, key: String) -> Color {
        if let hit = cache[key] { return hit }
        // Dark: as chosen, unless it is too dark to read there (a custom colour can be).
        let dark = NSColor(base.legible(on: .dark))
        let light = NSColor(base.legible(on: .light, lightTarget: lightTarget))
        let dynamic = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
        let colour = Color(nsColor: dynamic)
        cache[key] = colour
        return colour
    }

    /// A theme's *active* colour from its hex, adaptive; nil for an unreadable hex.
    public static func active(hex: String) -> Color? {
        guard let base = Color(hex: hex) else { return nil }
        return adaptive(base, key: hex.uppercased())
    }

    /// Solo's yellow, adaptive for the same reason: a yellow "SOLO" on a light window was
    /// unreadable.
    public static let solo = adaptive(Color(nsColor: .systemYellow), key: "solo-yellow")
}

public extension Color {
    /// Nudges a colour until it is legible *as a foreground* on this appearance's background.
    ///
    /// Fills use the raw colour at low opacity and are fine whatever it is, but an icon or a
    /// label drawn in the colour itself is not: a canary-yellow stop button on a white window is
    /// invisible. This darkens a too-light colour in light mode and lightens a too-dark one in
    /// dark mode, keeping the hue.
    func legible(on scheme: ColorScheme) -> Color { legible(on: scheme, lightTarget: 0.45) }

    /// `lightTarget`: the relative luminance a colour is pulled down to in light mode. 0.45 for
    /// glyphs judged by eye; `ThemeColors` uses a stricter one, because its colour is also text,
    /// switches and slider fills that sit on a tinted ground.
    func legible(on scheme: ColorScheme, lightTarget: Double) -> Color {
        guard let hsb = NSColor(self).usingColorSpace(.sRGB) else { return self }
        var (h, sat, b) = (hsb.hueComponent, hsb.saturationComponent, hsb.brightnessComponent)
        // Targets chosen by eye against the washed grounds, not by a contrast ratio: these are
        // 17–20 px glyphs and chips, not body text. Pulling a canary yellow all the way down to
        // text contrast turns it olive, which loses the colour the user actually picked — gold
        // is the right landing place. Yellows read much lighter than their brightness suggests,
        // hence weighting by luminance rather than brightness.
        if scheme == .light {
            // A yellow darkened at its own hue turns olive — the canary accent and the solo text
            // both did on a light window. Turned to gold (40°) first,
            // it darkens into something that still reads as the colour picked.
            if (0.12...0.20).contains(h), NSColor(hue: h, saturation: sat, brightness: b, alpha: 1)
                .relativeLuminanceApprox > lightTarget {
                h = 0.11
            }
            while b > 0.30, NSColor(hue: h, saturation: sat, brightness: b, alpha: 1)
                    .relativeLuminanceApprox > lightTarget {
                b -= 0.03
            }
        } else {
            while b < 0.97, NSColor(hue: h, saturation: sat, brightness: b, alpha: 1)
                    .relativeLuminanceApprox < 0.15 {
                b += 0.03
            }
        }
        return Color(nsColor: NSColor(hue: h, saturation: sat, brightness: b, alpha: 1))
    }

    /// Parses `#rrggbb`. Returns nil on anything else, so a corrupted preference falls back to
    /// the system accent rather than to black.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255,
                  opacity: 1)
    }

    var hexString: String {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X",
                      Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()),
                      Int((rgb.blueComponent * 255).rounded()))
    }

    /// Black or white, whichever stays legible on this colour.
    ///
    /// The solo pill used to be white-on-yellow, which was already marginal; once the colour is
    /// user-chosen it has to be computed. Relative luminance per WCAG, with the threshold
    /// at 0.45 rather than 0.5 because white text on mid-tones reads worse than black does.
    var readableForeground: Color {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return .white }
        func linear(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(rgb.redComponent)
                      + 0.7152 * linear(rgb.greenComponent)
                      + 0.0722 * linear(rgb.blueComponent)
        return luminance > 0.45 ? .black : .white
    }
}

public extension NSColor {
    /// WCAG relative luminance, for the contrast decisions above. Approximate because it assumes
    /// the colour is already in sRGB, which both callers guarantee.
    var relativeLuminanceApprox: CGFloat {
        guard let rgb = usingColorSpace(.sRGB) else { return 0 }
        func linear(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent)
             + 0.7152 * linear(rgb.greenComponent)
             + 0.0722 * linear(rgb.blueComponent)
    }
}
