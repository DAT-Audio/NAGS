import SwiftUI

/// The colour-scheme rows of both apps' Settings: one picker, then the two colour wells.
///
/// There is no on/off switch. **System colour scheme** is the first choice in the picker, and
/// means no tint at all: the system's own colours, which was once the default look.
/// Graphite & Amber is what a fresh install starts on (`ThemeChoice.stored`). Editing a colour
/// always means a custom scheme, so the wells stay usable under System and switch it off.
public struct ColourSchemeControls: View {
    @Binding var theme: ThemeChoice

    /// Every choice laid out as a list rather than a pop-up — for a screenshot of what the
    /// pop-up offers, which a closed menu cannot show.
    var listsChoices = false

    public init(theme: Binding<ThemeChoice>, listsChoices: Bool = false) {
        _theme = theme
        self.listsChoices = listsChoices
    }

    private static let system = "system", custom = "custom"

    private var selection: String {
        guard theme.enabled else { return Self.system }
        return theme.preset?.name ?? Self.custom
    }

    public var body: some View {
        LabeledContent("Colour scheme") {
            Picker("", selection: Binding(get: { selection }, set: choose)) {
                Text("System colour scheme").tag(Self.system)
                if !listsChoices { Divider() }
                ForEach(ThemePreset.all) { preset in Text(preset.name).tag(preset.name) }
                // The schemes that bring their own look, after the colour-only ones.
                if !listsChoices { Divider() }
                ForEach(ThemePreset.looks) { preset in Text(preset.name).tag(preset.name) }
                // "Rea-Theme Current", which read a REAPER installation's theme, was dropped: REAPER themes are managed too many ways to follow
                // reliably. Its colours, if chosen, stay as a custom scheme.
                if !listsChoices { Divider() }
                Text("Custom").tag(Self.custom)
            }
            .labelsHidden()
            .modifier(ChoiceListStyle(on: listsChoices))
        }
        .help(tooltip("Tints the window and marks what is switched on, in two colours. System "
                    + "colour scheme leaves the system's own colours alone.",
                      now: theme.enabled ? (theme.preset?.name ?? "custom colours") : "System colour scheme"))
        // A scheme with its own look says so where it is chosen: it brings its own controls and
        // sets light or dark itself.
        if let forced = Skin.for(enabled: theme.enabled, primary: theme.primaryHex,
                                 secondary: theme.secondaryHex).style.appearance {
            Text("This scheme has its own look — meters, faders and buttons — and is always "
               + "\(forced == .dark ? "dark" : "light"), so Appearance is set by it.")
                .font(.caption).foregroundStyle(Color.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        LabeledContent("Colours") {
            HStack(spacing: 8) {
                ColorPicker("", selection: Binding(
                    get: { Color(hex: theme.primaryHex) ?? .accentColor },
                    set: { theme.primaryHex = $0.hexString; theme.enabled = true }))
                    .labelsHidden()
                Text("Window").font(.caption).foregroundStyle(Color.mutedLabel)
                Spacer(minLength: 6)
                ColorPicker("", selection: Binding(
                    get: { Color(hex: theme.secondaryHex) ?? .yellow },
                    set: { theme.secondaryHex = $0.hexString; theme.enabled = true }))
                    .labelsHidden()
                Text("Active").font(.caption).foregroundStyle(Color.mutedLabel)
                Spacer(minLength: 0)
            }
            .opacity(theme.enabled ? 1 : 0.45)
        }
    }

    private struct ChoiceListStyle: ViewModifier {
        let on: Bool
        func body(content: Content) -> some View {
            if on { content.pickerStyle(.radioGroup) } else { content }
        }
    }

    private func choose(_ tag: String) {
        switch tag {
        case Self.system: theme.enabled = false
        case Self.custom: theme.enabled = true
        default:
            guard let preset = (ThemePreset.all + ThemePreset.looks).first(where: { $0.name == tag }) else { return }
            theme = ThemeChoice(enabled: true, primaryHex: preset.primary, secondaryHex: preset.secondary)
        }
    }
}
