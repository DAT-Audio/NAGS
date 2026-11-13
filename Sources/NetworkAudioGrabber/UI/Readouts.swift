import SwiftUI

/// One loudness reading, pre-formatted.
struct LoudnessReading: Equatable {
    var value = "−∞"
    var delta: String?
    var deviation: Double?
    /// How far off target, as a band, so the view does not have to know the thresholds.
    var band: Band = .none
    var provisional = false

    enum Band { case none, onTarget, near, off }

    private static let green = ThemeColors.adaptive(Color(nsColor: .systemGreen), key: "loudness-green")
    private static let orange = ThemeColors.adaptive(Color(nsColor: .systemOrange), key: "loudness-orange")

    var colour: Color {
        switch band {
        case .none:     return .secondary
        // Adaptive, so the deltas stay readable on a light window: plain yellow on white was
        // the one figure in the loudness block that could not be read.
        case .onTarget: return Self.green
        case .near:     return ThemeColors.solo
        case .off:      return Self.orange
        }
    }
}

/// The numbers under the meters, on **their own observable object**.
///
/// This exists because of two findings that pull in opposite directions. Publishing through
/// `AppState` is ruinous — every view in the window observes it, and four publishes a second
/// cost about 20 % of a core. But drawing the numbers continuously is not the answer either:
/// as a SwiftUI `TimelineView` they cost 15 %, and hand-drawn in AppKit they crashed inside
/// CoreText.
///
/// So they are published, but on an object only the readout views observe, and **only when the
/// formatted text actually changes**. A figure rounded to one decimal place changes a few times
/// a second at most, and the master figure — now a maximum rather than a live level — changes
/// hardly at all. No timer, no custom drawing, and a dirty flag that reaches three labels
/// instead of the whole window.
@Observable
final class Readouts {
    /// Highest output level since it was last reset, in dBFS.
    ///
    /// A live figure was redrawn tens of times a second to show something the bars already show
    /// better. A maximum answers the question a number is actually good for — "how hot did this
    /// get" — and only changes when a new peak beats the old one.
    fileprivate(set) var outputMax = "−∞"

    fileprivate(set) var shortTerm = LoudnessReading()
    fileprivate(set) var window = LoudnessReading()
    fileprivate(set) var integrated = LoudnessReading()

    /// Assigns only on change, which is the whole point of the class.
    fileprivate func update(outputMax: String,
                            shortTerm: LoudnessReading,
                            window: LoudnessReading,
                            integrated: LoudnessReading) {
        if self.outputMax != outputMax { self.outputMax = outputMax }
        if self.shortTerm != shortTerm { self.shortTerm = shortTerm }
        if self.window != window { self.window = window }
        if self.integrated != integrated { self.integrated = integrated }
    }
}

extension AppState {
    /// Recomputes the formatted readouts. Called from the 0.25 s tick — four times a second is
    /// ample for a number, and nothing is published unless the text moved.
    func refreshReadouts() {
        func reading(_ value: Double, _ target: Double, provisional: Bool = false) -> LoudnessReading {
            guard value.isFinite else { return LoudnessReading() }
            let delta = value - target
            let band: LoudnessReading.Band
            switch abs(delta) {
            case ..<1: band = .onTarget
            case ..<3: band = .near
            default:   band = .off
            }
            return LoudnessReading(value: String(format: "%.1f", value),
                                   delta: String(format: "%+.1f", delta),
                                   // To the 0.1 LU the figures show: the raw difference changed on
                                   // every tick, so a reading whose text had not moved was still
                                   // published four times a second.
                                   deviation: (delta * 10).rounded() / 10,
                                   band: band,
                                   provisional: provisional)
        }

        let peak = outputPeakMax
        readouts.update(outputMax: peak > 0.0002
                            ? String(format: "%.1f", 20 * log10(Double(peak))) : "−∞",
                        shortTerm: reading(loudnessShortTerm, targetShortTerm),
                        window: reading(loudnessWindowed, targetWindow),
                        integrated: reading(loudnessIntegrated, targetIntegrated,
                                            provisional: loudnessBlocks < 30))
    }
}

extension AppState {
    /// The monitor level in decibels against unity.
    ///
    /// It was a percentage of the slider's travel, which read as loudness and was not: 50 % is
    /// −6 dB. The slider stays linear in amplitude; the figure beside it now says what it does.
    var masterVolumeLabel: String {
        masterVolume > 0.0001
            ? String(format: "%.1f dB", 20 * log10(masterVolume))
            : "−∞ dB"
    }

    var masterVolumePercent: String { "\(Int((masterVolume * 100).rounded())) %" }

    var masterVolumeHelp: String {
        let db = masterVolume > 0.0001
            ? String(format: "%+.1f dB", 20 * log10(masterVolume))
            : "−∞"
        var text = "Monitor level: \(db), \(masterVolumePercent) of the slider's travel. "
            + "The slider is linear in amplitude, so 50 % is −6 dB."
        if dimmed { text += " DIM is engaged, taking a further −20 dB." }
        return text
    }
}

/// One loudness line, driven by `Readouts` rather than by a poll.
struct LoudnessReadingRow: View {
    let label: String
    let reading: LoudnessReading
    /// What this particular reading measures. The three differ only in their window, which is
    /// the one thing the label cannot say and the most common thing to be unsure about.
    var detail: String = ""

    private static let span = 6.0
    private static let barWidth = 70.0

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: label)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(width: 80, alignment: .leading)

            Text(verbatim: reading.value)
                .font(.system(size: 14, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(reading.provisional || reading.delta == nil
                                 ? Color.secondary : Color.primary)
                .frame(width: 46, alignment: .trailing)

            Spacer(minLength: 4)

            deviationBar

            Text(verbatim: reading.delta ?? "—")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(reading.colour)
                .frame(width: 36, alignment: .trailing)
        }
        .help(rowHelp)
    }

    private var rowHelp: String {
        var now = "\(reading.value) LUFS"
        if let delta = reading.delta?.trimmingCharacters(in: .whitespaces), !delta.isEmpty,
           delta != "—" {
            now += ", \(delta) LU against the target"
        }
        if reading.provisional {
            now += " — provisional, still gathering gated blocks"
        }
        return tooltip(detail, now: now)
    }

    private var deviationBar: some View {
        let travel = Self.barWidth / 2 - 3.5
        let clamped = max(-Self.span, min(Self.span, reading.deviation ?? 0))
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.primary.opacity(0.10))
                .frame(width: Self.barWidth, height: 3)
            Rectangle()
                .fill(Color.primary.opacity(0.4))
                .frame(width: 1, height: 7)
                .offset(x: Self.barWidth / 2 - 0.5)
            if reading.deviation != nil {
                Circle()
                    .fill(reading.colour)
                    .frame(width: 7, height: 7)
                    .offset(x: Self.barWidth / 2 - 3.5 + clamped / Self.span * travel)
            }
        }
        .frame(width: Self.barWidth, height: 7)
    }
}

/// The three loudness lines plus the header, shared by both windows.
struct LoudnessBlock: View {
    @Environment(AppState.self) var state
    var readouts: Readouts

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LoudnessReadingRow(label: "Short-term", reading: readouts.shortTerm,
                               detail: "Short-term loudness — a fixed 3-second window, as "
                                     + "BS.1770 defines it. This is the one that moves with "
                                     + "the material: what the level is doing now.")
            LoudnessReadingRow(label: "Window \(state.lufsWindowSeconds) s", reading: readouts.window,
                               detail: "Windowed loudness — the last stretch of programme, "
                                     + "gated the same way as integrated, with the length set "
                                     + "in Settings → Loudness. A middle view between the "
                                     + "3-second figure and the whole session.")
            LoudnessReadingRow(label: "Integrated", reading: readouts.integrated,
                               detail: "Integrated loudness — everything since the last reset "
                                     + "(⇧⌘L, or double-click here). Gated, and the figure a "
                                     + "delivery specification means when it names a number.")
        }
        // Double-click anywhere on the block to start the measurement again. The ⟲ button and
        // ⇧⌘L do the same; this is just the gesture you reach for when your eye is already on
        // the figures.
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { state.resetLoudness() }
        .help("ITU-R BS.1770-4 against the targets in Settings. "
            + "Double-click to reset the integrated and window readings (⇧⌘L).")
    }
}
