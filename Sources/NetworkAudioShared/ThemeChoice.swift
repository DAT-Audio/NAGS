import SwiftUI

/// The user's colour scheme as the Sender applies it: the same two roles, strengths and
/// fallbacks the Grabber uses (see `ThemePreset`), so a theme picked in one app reads the same in
/// the other.
///
/// The Grabber still computes these on its own `AppState`, where they predate this type; the
/// values here are copied from there and must move with them.
public struct ThemeChoice: Equatable {
    public var enabled: Bool
    public var primaryHex: String
    public var secondaryHex: String

    public init(enabled: Bool, primaryHex: String, secondaryHex: String) {
        self.enabled = enabled
        self.primaryHex = primaryHex
        self.secondaryHex = secondaryHex
    }

    /// How strongly the primary colour washes the window's surfaces — a tinted ground, not a
    /// painted one. Dark needs more because a wash over near-black shows less.
    public static let washLight = 0.13
    public static let washDark = 0.22

    /// The window wash. `Color.clear` when theming is off.
    public func surfaceWash(_ scheme: ColorScheme) -> Color {
        guard enabled, let primary = Color(hex: primaryHex) else { return .clear }
        // A skin with its own ground paints it outright.
        if let window = Skin.for(enabled: enabled, primary: primaryHex, secondary: secondaryHex).style.window {
            return Color(nsColor: window)
        }
        return primary.opacity(scheme == .dark ? Self.washDark : Self.washLight)
    }

    /// Anything meaning *active*. Falls back to the system accent colour.
    public var active: Color {
        enabled ? (ThemeColors.active(hex: secondaryHex) ?? .accentColor) : .accentColor
    }

    /// The same colour, safe to draw as an icon or label rather than a low-opacity fill.
    ///
    /// Already so: a theme colour is adaptive (`ThemeColors`), and the system accent is passed
    /// on untouched. It used to go through `legible(on:)`, which turned the live accent into a
    /// fixed sRGB copy — so the Sender's menus came out blue where the Grabber's, handed the
    /// live accent, showed the native label colour, and neither followed a change of accent
    /// while open.
    public func active(on scheme: ColorScheme) -> Color { active }

    /// The saved choice, with the default for anyone who never set one.
    ///
    /// **The default is the system's own colours** (theming off). For a time a fresh install
    /// started at Graphite & Amber, and then the default went back to following the system after all. A fresh install — or one that never touched
    /// the setting, the same thing on disk, since nothing is written until the user changes
    /// it — follows the system accent, and Graphite & Amber is what it gets if theming is then
    /// switched on without picking colours. Anyone who did set it, on or off, keeps exactly
    /// what they had, including the old colour fallback if they switched it on long ago
    /// without picking colours.
    public static func stored(in defaults: UserDefaults) -> ThemeChoice {
        guard let enabled = defaults.object(forKey: "themeEnabled") as? Bool else {
            return ThemeChoice(enabled: false,
                               primaryHex: defaults.string(forKey: "themePrimaryHex") ?? ThemePreset.standard.primary,
                               secondaryHex: defaults.string(forKey: "themeSecondaryHex") ?? ThemePreset.standard.secondary)
        }
        let primary = defaults.string(forKey: "themePrimaryHex") ?? ThemePreset.previousFallback.primary
        var secondary = defaults.string(forKey: "themeSecondaryHex") ?? ThemePreset.previousFallback.secondary
        // Teal & Coral's coral moved from #FF6F5E to #FF7F50, away from Mute's red.
        // Someone who picked it keeps the preset, at its new colour, rather than finding it
        // turned into an unnamed custom scheme.
        if primary == "#0E8C8C", secondary == "#FF6F5E" { secondary = "#FF7F50" }
        // "Rea-Theme Current" is gone: forget that it was chosen; its colours stay.
        defaults.removeObject(forKey: "themeFollowsReaper")
        // Rea-Theme Default's accent moved from #1ABC98 to #6B7C83, the same way.
        if primary == "#466168", secondary == "#1ABC98" { secondary = "#6B7C83" }
        return ThemeChoice(enabled: enabled, primaryHex: primary, secondaryHex: secondary)
    }

    /// The preset these colours match, if any.
    public var preset: ThemePreset? {
        (ThemePreset.all + ThemePreset.looks).first { $0.primary == primaryHex && $0.secondary == secondaryHex }
    }
}
