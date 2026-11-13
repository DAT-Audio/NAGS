import SwiftUI

// The small controls both apps draw alike. Moved here unchanged from the Grabber when the Sender
// arrived, so the two cannot drift apart: a chip, a pill or a tooltip means the same thing in
// either window.

/// Tooltip text in one shape: **what the control is, then what it is doing right now.**
///
/// The second half is what every tooltip in the app was missing. "Take this insert out of
/// circuit" tells you what the button is for and leaves you to read its colour to find out
/// whether it is on — which is exactly the question someone hovering a monitor control is
/// asking. macOS supplies the hover delay itself, so there is no timing to build.
///
/// Keep `what` to a sentence or two of plain description and `now` to the live state, in the
/// present tense. Where a state has a figure attached — a delay being compensated, a level, a
/// channel mapping — put the figure in `now`, because that is the part a screenshot cannot
/// tell you.
public func tooltip(_ what: String, now: String) -> String {
    "\(what)\n\nNow: \(now)"
}

public enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    public var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}

/// Small capsule label used for the source, channel count and format chips.
public struct Chip: View {
    let text: String
    var tint: Color = .secondary
    var filled = false
    @Environment(\.skin) private var skin

    public init(text: String, tint: Color = .secondary, filled: Bool = false) {
        self.text = text
        self.tint = tint
        self.filled = filled
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            // A capsule, or in REAPER's look a near-square box (a large radius is a capsule).
            .background(RoundedRectangle(cornerRadius: skin.chipRadius ?? 20)
                .fill(tint.opacity(skin.style.chipText != nil ? 0.5 : (filled ? 0.22 : 0.13))))
            .foregroundStyle(skin.style.chipText ?? tint)
            .fixedSize()
    }
}

/// A filled state marker — `M`, `S` — for the signal panel's name line.
///
/// These used to be bare coloured letters, which disappeared against the panel. Filled blocks
/// match what the same states look like on a stream row, which is the point: one visual language
/// for mute and solo wherever they appear.
public struct StateBadge: View {
    let title: String
    let tint: Color
    var help: String = ""

    public init(title: String, tint: Color, help: String = "") {
        self.title = title
        self.tint = tint
        self.help = help
    }

    public var body: some View {
        Text(verbatim: title)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(tint))
            .foregroundStyle(tint.readableForeground)
            .fixedSize()
            .help(help)
    }
}

/// Compact toggle used for DIM / MONO / bypass.
public struct PillToggle: View {
    let title: String
    @Binding var isOn: Bool
    var tint: Color = .accentColor
    var help: String = ""
    /// What the letter stands for, for anything that cannot see the letter. `M` and `S` are
    /// obvious on a console and meaningless read aloud.
    var spokenName: String = ""
    @Environment(\.skin) private var skin

    public init(title: String, isOn: Binding<Bool>, tint: Color = .accentColor,
                help: String = "", spokenName: String = "") {
        self.title = title
        self._isOn = isOn
        self.tint = tint
        self.help = help
        self.spokenName = spokenName
    }

    public var body: some View {
        Button { isOn.toggle() } label: {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                // Never squeezed: a row that runs out of room must give way somewhere else.
                // Without this, adding a chip beside the insert controls crushed BYP into a
                // one-character column reading "B Y P" down the row.
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(face)
                // Not always white: the tint is the user's to choose now, and white on a
                // canary yellow is unreadable. See `Color.readableForeground`.
                // REAPER's dark face is dark in either appearance, so its letters are light.
                .foregroundStyle(isOn ? (skin.style.buttonFace?.onText ?? tint.readableForeground)
                                      : (skin.style.buttonFace?.text ?? Color.secondary))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(spokenName.isEmpty ? title : spokenName)
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
    /// The button's face: a soft rounded fill normally; in REAPER's look nearly square, with a
    /// dark bevelled face at rest and an outline, like its M / S / FX buttons.
    @ViewBuilder private var face: some View {
        let shape = RoundedRectangle(cornerRadius: skin.buttonRadius)
        if let f = skin.style.buttonFace {
            shape
                .fill(isOn ? AnyShapeStyle(tint.opacity(0.9))
                           : AnyShapeStyle(LinearGradient(colors: [f.top, f.bottom],
                                                          startPoint: .top, endPoint: .bottom)))
                .overlay(shape.stroke(f.stroke ?? .clear, lineWidth: 0.75))
        } else {
            shape.fill(isOn ? tint.opacity(0.85) : Color.primary.opacity(0.08))
        }
    }
}

/// Long-form guidance, shut until asked for.
///
/// Every one of these used to be a paragraph sitting permanently under its controls, which is
/// what made Settings read as a wall. They are worth keeping — each answers a question that
/// otherwise becomes a support email — but they are read once, so the default state is closed.
public struct Explainer: View {
    let title: String
    let text: String
    @State private var expanded = false

    public init(title: String, text: String) {
        self.title = title
        self.text = text
    }

    public var body: some View {
        Section {
            DisclosureGroup(isExpanded: $expanded) {
                // `LocalizedStringKey`, not the plain string: markdown in a `Text` is parsed for
                // a literal or a key and not for a `String`, and these paragraphs are written
                // with bold in them.
                Text(LocalizedStringKey(text))
                    .font(.caption2)
                    .foregroundStyle(Color.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle").font(.system(size: 10))
                    Text(title).font(.caption)
                }
                .foregroundStyle(Color.mutedLabel)
            }
        }
    }
}

public extension View {
    /// For fields that take a name, an address or a number rather than prose: no autocorrect,
    /// and no Writing Tools. Keeps macOS's text services, and the suggestion panel they can put
    /// under a focused field, out of a control that has no use for them.
    @ViewBuilder func plainEntry() -> some View {
        if #available(macOS 15.0, *) {
            self.autocorrectionDisabled().writingToolsBehavior(.disabled)
        } else {
            self.autocorrectionDisabled()
        }
    }
}


/// The one thing to know before connecting over VBAN, said the same way in both apps.
public enum TrustNotice {
    public static let title = "Only on a network you trust"
    public static let message = "The audio is not encrypted: anyone who can see this network's traffic could capture it. "
        + "Connect like this at home, in a studio or an office — not on public or guest Wi-Fi."
    public static let shortLine = "Not encrypted: use this on a network you trust, such as at home, in a studio or an office."
    /// "Don't show this again", per app.
    public static let skipKey = "skipTrustNotice"
}

public extension View {
    /// Asks, once per click, before the connect guide opens: a plain statement that the audio is
    /// not encrypted, with Continue, Continue and don't show again, and Cancel.
    func trustNotice(isPresented: Binding<Bool>, onContinue: @escaping () -> Void) -> some View {
        alert(TrustNotice.title, isPresented: isPresented) {
            Button("Continue", action: onContinue)
            Button("Continue, and Don't Show Again") {
                UserDefaults.standard.set(true, forKey: TrustNotice.skipKey)
                onContinue()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(TrustNotice.message)
        }
    }
}

/// An insert whose plugin stopped by itself: the fault shown on the slot that has it, in
/// the red the app uses for faults, with the one thing to do about it. Shared by both apps.
public struct FailedInsertRow: View {
    let menu: AnyView
    let reason: String
    let reload: () -> Void

    public init(menu: AnyView, reason: String, reload: @escaping () -> Void) {
        self.menu = menu; self.reason = reason; self.reload = reload
    }

    public var body: some View {
        HStack(spacing: 6) {
            menu.layoutPriority(-1)
            Label(reason, systemImage: "xmark.octagon.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.red)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button("Reload", action: reload)
                .controlSize(.small)
                .help("Load this plugin again, with the settings it last had.")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.red.opacity(0.35), lineWidth: 1))
        .help("The plugin's process ended, so it was taken out of the chain and the audio carried "
            + "on without it. Plugins run in their own process so that one crashing cannot stop "
            + "the app. The first time, it is reloaded by itself; if it stops again within a "
            + "minute it stays out until Reload is pressed.")
    }
}

/// In → out for one insert: the level going into the plugin and the level coming
/// out, side by side, so a plugin passing nothing — or silencing everything — shows at once,
/// without reaching for Δ. Two one-bar `MeterStrip`s on the shared clock.
public struct InsertThroughMeter: View {
    let level: (Bool) -> Float
    let paused: Bool

    public init(paused: Bool, level: @escaping (_ output: Bool) -> Float) {
        self.paused = paused; self.level = level
    }

    public var body: some View {
        HStack(spacing: 3) {
            MeterStrip(count: 1, orientation: .horizontal, thickness: 3, slot: 3, length: 22,
                       paused: paused, level: { _ in level(false) })
                .frame(width: 22, height: 3)
            Image(systemName: "arrow.right").font(.system(size: 7)).foregroundStyle(Color.mutedLabel)
            MeterStrip(count: 1, orientation: .horizontal, thickness: 3, slot: 3, length: 22,
                       paused: paused, level: { _ in level(true) })
                .frame(width: 22, height: 3)
        }
        .help("Level going into this plugin, and coming out of it.")
        .accessibilityHidden(true)
    }
}

/// "BETA", beside a switch for something that works but has not been proven in real use: the
/// receivers added later on.
public struct BetaBadge: View {
    public init() {}
    public var body: some View {
        Text(verbatim: "BETA")
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .overlay(Capsule().stroke(Color.orange.opacity(0.7), lineWidth: 1))
            .foregroundStyle(Color.orange)
            .fixedSize()
            .help("Beta: works in testing here, not yet proven with real senders. Off unless you switch it on.")
            .accessibilityLabel("Beta")
    }
}

/// For the render harnesses: a window that reports itself key and main, so controls draw as
/// they do in the window being used. An off-screen harness window is never key, and AppKit draws
/// an inactive window's slider fills and switches grey — every screenshot showed the themed
/// controls uncoloured, which is not what anyone using the app sees.
public final class ActiveLookingWindow: NSWindow {
    public override var isKeyWindow: Bool { true }
    public override var isMainWindow: Bool { true }
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }
}

/// A switch in the scheme's secondary colour. macOS 26 draws its own switch in the
/// system accent and ignores `.tint`, so a themed window's switches came out grey or blue, never
/// the colour every other active control in the app uses. Same shape and sizes as the system's;
/// VoiceOver gets a real `Toggle` through `accessibilityRepresentation`.
public struct ThemedSwitchStyle: ToggleStyle {
    public let tint: Color
    public init(tint: Color) { self.tint = tint }

    public func makeBody(configuration: Configuration) -> some View {
        LabeledContent {
            ThemedSwitch(isOn: configuration.$isOn, tint: tint)
        } label: {
            configuration.label
        }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

private struct ThemedSwitch: View {
    @Binding var isOn: Bool
    let tint: Color
    @Environment(\.controlSize) private var size
    @Environment(\.isEnabled) private var enabled

    private var dims: (w: CGFloat, h: CGFloat) {
        switch size {
        case .mini:  return (26, 15)
        case .small: return (32, 18)
        default:     return (38, 22)
        }
    }

    var body: some View {
        let (w, h) = dims
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? tint : Color.primary.opacity(0.14))
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                .padding(2)
                .frame(width: h, height: h)
        }
        .frame(width: w, height: h)
        .opacity(enabled ? 1 : 0.45)
        .contentShape(Capsule())
        .onTapGesture { if enabled { withAnimation(.easeOut(duration: 0.12)) { isOn.toggle() } } }
    }
}

/// The play / stop button's face. The app's own: a stop disc in the active colour, a play ring
/// at rest. REAPER's look: a small square button — green, as
/// REAPER's transport play button, while the stream plays, and black at rest.
public struct PlayStopIcon: View {
    let active: Bool
    let tint: Color
    let size: CGFloat
    @Environment(\.skin) private var skin

    public init(active: Bool, tint: Color, size: CGFloat) {
        self.active = active; self.tint = tint; self.size = size
    }

    public var body: some View {
        if let p = skin.style.play {
            let side = size + 1
            let shape = RoundedRectangle(cornerRadius: p.square ? p.radius : side / 2)
            shape
                .fill(active ? p.active : p.idle)
                .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 0.75))
                .overlay(Image(systemName: active ? "stop.fill" : "play.fill")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(active ? p.activeGlyph : p.idleGlyph))
                .frame(width: side, height: side)
        } else {
            Image(systemName: active ? "stop.circle.fill" : "play.circle")
                .font(.system(size: size))
                .foregroundStyle(active ? tint : Color.secondary)
        }
    }
}

/// Light / Dark / System, shared by both apps' Settings. A skinned scheme — Rea-Theme
/// Default and the others — is drawn for one appearance only, so while one is chosen the choice
/// is greyed out and says so, rather than offering an option that would change nothing.
public struct AppearanceControl: View {
    @Binding var appearance: Appearance
    let skin: Skin

    public init(appearance: Binding<Appearance>, skin: Skin) {
        _appearance = appearance; self.skin = skin
    }

    public var body: some View {
        let forced = skin.style.appearance
        LabeledContent("Appearance") {
            VStack(alignment: .trailing, spacing: 3) {
                Picker("", selection: $appearance) {
                    ForEach(Appearance.allCases) { a in Text(a.label).tag(a) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 210)
                .disabled(forced != nil)
                if let forced {
                    Text("Set by the colour scheme: always \(forced == .dark ? "dark" : "light").")
                        .font(.caption).foregroundStyle(Color.mutedLabel)
                }
            }
        }
        .help(forced == nil ? "Light, dark, or follow the system."
              : "This colour scheme has its own look, drawn \(forced == .dark ? "dark" : "light") only, so it "
              + "sets the appearance. Choose a scheme without its own look to pick light or dark.")
    }
}
