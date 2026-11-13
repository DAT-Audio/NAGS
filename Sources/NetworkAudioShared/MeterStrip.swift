import SwiftUI
import AppKit

/// Level meters drawn by AppKit rather than SwiftUI.
///
/// **Why this is not a `Canvas` in a `TimelineView`.** Profiling the app while one stream played
/// showed a third of its CPU in `-[NSWindow layoutIfNeeded]` → `-[NSView layoutSubtreeIfNeeded]`,
/// reached from `CA::Transaction::commit` on every display cycle — the whole window's view tree
/// being laid out again and again because a `TimelineView` had invalidated. Pinning fixed frames
/// around the timelines did not help: the invalidation is what schedules the layout, not the
/// uncertainty about size.
///
/// A meter has a fixed size and changes nothing but its own pixels, so it has no business taking
/// part in layout at all. This view redraws on its own timer and calls `setNeedsDisplay` on
/// itself, which AppKit satisfies without asking SwiftUI anything. SwiftUI lays it out once.
///
/// The levels arrive through a closure rather than a value, for the same reason the SwiftUI
/// meters polled: pushing them through `@Published` would re-render the window.
public struct MeterStrip: NSViewRepresentable {
    public enum Orientation { case vertical, horizontal }

    /// Number of bars.
    var count: Int
    var orientation: Orientation = .vertical
    /// Bar width for a vertical meter, bar height for a horizontal one.
    var thickness: CGFloat
    /// Space each bar occupies across the meter, including its gap.
    var slot: CGFloat
    /// How long the bars are, along the direction they fill.
    var length: CGFloat
    var fps: Double = 30
    var paused = false
    /// 0…1 per bar. Called on the main thread, `count` times per redraw.
    var level: (Int) -> Float
    /// Shared peak-hold tick, if the meter has one.
    var hold: () -> Float? = { nil }
    /// Bars that are not reaching the output — muted, silenced by another stream's solo, or
    /// outside a channel solo. Drawn in flat grey rather than the level gradient, so the colour
    /// itself says whether a channel is in circuit.
    var isDimmed: (Int) -> Bool = { _ in false }
    /// Nothing to measure — a stream joined but with no packets arriving, a Sender not
    /// capturing. Drawn as a row of dots rather than an empty track, so "not arriving" never
    /// reads as "silent" (after Audio Hijack's idle meters).
    var noData: () -> Bool = { false }
    /// No unlit track behind the bars: the row meters, a glance at signal rather than a meter
    /// to read, looked like dark patches with one.
    var trackless = false

    public init(count: Int, orientation: Orientation = .vertical, thickness: CGFloat,
                slot: CGFloat, length: CGFloat, fps: Double = 30, paused: Bool = false,
                level: @escaping (Int) -> Float, hold: @escaping () -> Float? = { nil },
                isDimmed: @escaping (Int) -> Bool = { _ in false },
                noData: @escaping () -> Bool = { false }, trackless: Bool = false) {
        self.trackless = trackless
        self.count = count
        self.orientation = orientation
        self.thickness = thickness
        self.slot = slot
        self.length = length
        self.fps = fps
        self.paused = paused
        self.level = level
        self.hold = hold
        self.isDimmed = isDimmed
        self.noData = noData
    }

    public func makeNSView(context: Context) -> MeterLayer {
        let view = MeterLayer()
        apply(to: view)
        return view
    }

    /// **The container decides how long the bars are, not the view's intrinsic size**.
    ///
    /// Without this, SwiftUI sizes an `NSViewRepresentable` from its `intrinsicContentSize`,
    /// which here is built from `length` — and `length` is whatever the caller last measured.
    /// Where that measurement comes from the layout itself, the view is sized from the
    /// *previous* pass: lay the compact window out at 560 points, shrink it to 330, and the
    /// strip is still 560 long inside a 330-point slot, hanging off the right edge of the
    /// window. It looks like a meter that will not scale and is really a meter that was
    /// measured twice.
    ///
    /// Returning the proposal makes the meter fill what it is given, which is what a level
    /// meter wants along its length in every case. `length` stays as the fallback for a
    /// proposal that says nothing.
    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: MeterLayer,
                      context: Context) -> CGSize? {
        let across = slot * CGFloat(count)
        func along(_ offered: CGFloat?) -> CGFloat {
            guard let offered, offered.isFinite else { return length }
            return offered
        }
        return orientation == .vertical
            ? CGSize(width: across, height: along(proposal.height))
            : CGSize(width: along(proposal.width), height: across)
    }

    public func updateNSView(_ view: MeterLayer, context: Context) {
        apply(to: view)
    }

    private func apply(to view: MeterLayer) {
        // Geometry, as opposed to levels: if any of it changed the view must repaint even when
        // it is paused. The bars are redrawn by this view's own timer, and the timer is stopped
        // while nothing is playing — so changing the bus width with the meters idle left the
        // old width's pixels on screen, which read as a misdrawn meter rather than a stale one.
        let moved = view.count != count
            || view.thickness != thickness
            || view.slot != slot
            || view.length != length
            || view.vertical != (orientation == .vertical)
            || view.trackless != trackless

        view.count = count
        view.vertical = orientation == .vertical
        view.thickness = thickness
        view.slot = slot
        view.length = length
        view.level = level
        view.hold = hold
        view.isDimmed = isDimmed
        view.noData = noData
        view.trackless = trackless
        view.setRate(paused ? 0 : fps)
        if moved || paused { view.setNeedsDisplay(view.bounds) }
    }

    public static func dismantleNSView(_ view: MeterLayer, coordinator: ()) {
        view.setRate(0)
    }
}

/// Channel names under a `MeterStrip`, drawn by AppKit with the **same slot arithmetic** as the
/// bars.
///
/// They were a SwiftUI `HStack` of fixed-width `Text`s, which is the obvious way to do it and
/// does not hold: short names do not fill their slot, so the row packs by natural width and
/// stops matching the meter above it — "L R Ls Rs" bunched to the left under four evenly spaced
/// bars. Mirroring an arithmetic in a different layout system is the bug; sharing the
/// arithmetic is the fix.
///
/// No timer: a label changes only when the bus does, so this draws on geometry changes and then
/// sits still, as the bars do.
public struct MeterLabels: NSViewRepresentable {
    var labels: [String]
    var slot: CGFloat
    var size: CGFloat = 7
    /// Channels not reaching the output, drawn faint to match their bars.
    var isDimmed: (Int) -> Bool = { _ in false }
    /// Soloed channels, blocked in the solo colour the way the row chips are.
    var isHighlighted: (Int) -> Bool = { _ in false }
    var highlight: NSColor = .systemYellow
    var highlightForeground: NSColor = .black

    public init(labels: [String], slot: CGFloat, size: CGFloat = 7,
                isDimmed: @escaping (Int) -> Bool = { _ in false },
                isHighlighted: @escaping (Int) -> Bool = { _ in false },
                highlight: NSColor = .systemYellow, highlightForeground: NSColor = .black) {
        self.labels = labels
        self.slot = slot
        self.size = size
        self.isDimmed = isDimmed
        self.isHighlighted = isHighlighted
        self.highlight = highlight
        self.highlightForeground = highlightForeground
    }

    public func makeNSView(context: Context) -> MeterLabelView {
        let view = MeterLabelView()
        apply(to: view)
        return view
    }

    public func updateNSView(_ view: MeterLabelView, context: Context) { apply(to: view) }

    private func apply(to view: MeterLabelView) {
        // Closures cannot be compared, so a repaint is asked for on every update. This view has
        // no timer and updates only when something in the panel actually changes, which is not
        // the hot path — the bars are.
        view.labels = labels
        view.slot = slot
        view.size = size
        view.isDimmed = isDimmed
        view.isHighlighted = isHighlighted
        view.highlight = highlight
        view.highlightForeground = highlightForeground
        view.setNeedsDisplay(view.bounds)
    }
}

public final class MeterLabelView: NSView {
    /// As `MeterLayer`: draw during the resize rather than stretching the old bitmap.
    public override init(frame: NSRect) {
        super.init(frame: frame)
        layerContentsRedrawPolicy = .duringViewResize
        // Decorative to VoiceOver: a bar redrawn 30 times a second has no value worth
        // announcing, and the figure it stands for is real text in the same block. Left in
        // the tree it is a row of unnamed elements to tab past.
        setAccessibilityElement(false)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        layerContentsRedrawPolicy = .duringViewResize
        setAccessibilityElement(false)
    }

    /// A resize is a reason to repaint. A layer-backed `NSView` given a new frame keeps the
    /// bitmap it already has, so the compact window's horizontal meter stayed the width it was
    /// first laid out at however wide the window got.
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setNeedsDisplay(bounds)
    }

    var labels: [String] = []
    var slot: CGFloat = 11
    var size: CGFloat = 7
    var isDimmed: (Int) -> Bool = { _ in false }
    var isHighlighted: (Int) -> Bool = { _ in false }
    var highlight: NSColor = .systemYellow
    var highlightForeground: NSColor = .black

    public override var isOpaque: Bool { false }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)

        // **Each label is drawn into its own slot-sized rect, centred.** Positioning a string
        // with `draw(at:)` and a computed x does not work here: successive calls lay out from
        // where the last one finished, so the row advances by the glyph widths rather than by
        // the slot, and the names bunch to the left of their bars. Measured before and after —
        // bar centres step by 11 points, and the labels were stepping by about 4.3, which is
        // the width of a digit.
        let style = NSMutableParagraphStyle()
        style.alignment = .center

        for (index, name) in labels.enumerated() where !name.isEmpty {
            let lit = isHighlighted(index)
            // `secondaryLabelColor`, not tertiary: these are channel names, which is the
            // information the strip exists to carry, and the tertiary label colour measured
            // 2.47:1 against the panel in dark and 1.63:1 in light. The same rule as the
            // SwiftUI side of the app (see Theme.swift) — hierarchy by size, not by opacity.
            var colour = lit ? highlightForeground : NSColor.mutedLabel
            // A channel that is out of circuit still has to be readable; it is greyed to say
            // "not reaching the output", which the bar beside it already says in full.
            if !lit, isDimmed(index) { colour = colour.withAlphaComponent(0.7) }

            // A label with empty slots either side (the every-fourth marking past eight
            // channels) may spill into them, still centred on its bar: a 7-point slot cannot
            // hold "13", and clipping it to "1" read as channel one.
            let spare = !lit && (index == 0 || labels[index - 1].isEmpty)
                && (index + 1 >= labels.count || labels[index + 1].isEmpty)
            let box = spare
                ? NSRect(x: slot * CGFloat(index) - slot, y: 0, width: slot * 3, height: bounds.height)
                : NSRect(x: slot * CGFloat(index), y: 0, width: slot, height: bounds.height)
            if lit {
                ctx.addPath(CGPath(roundedRect: box, cornerWidth: 3, cornerHeight: 3,
                                   transform: nil))
                ctx.setFillColor(highlight.cgColor)
                ctx.fillPath()
            }
            (name as NSString).draw(in: box, withAttributes: [
                .font: font,
                .foregroundColor: colour,
                .paragraphStyle: style,
            ])
        }
    }
}

/// The AppKit side of `MeterStrip`.
/// The bars, as Core Animation layers rather than drawing.
///
/// **Nothing is drawn per frame.** It used to be `draw(_:)`: every bar's track, rounded clip and
/// gradient rasterised on the CPU, every frame, by every strip on its own timer. Now each bar is
/// four layers made once — a track, a gradient spanning the whole track, a mask sized to the
/// level, and a peak-hold tick — and a frame changes nothing but the mask's and the tick's
/// frames. The gradient is set once and composited by the window server; moving a mask costs
/// next to nothing, and a bar whose level has not moved by half a point is not touched at all.
///
/// **One clock for every meter** (`MeterClock`), so all the bars in the window move in a single
/// Core Animation transaction per frame, with implicit animations off, instead of each strip
/// waking the run loop on its own timer. Nothing refreshes while the window is hidden.
public final class MeterLayer: NSView {
    public override init(frame: NSRect) {
        super.init(frame: frame)
        setUp()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        wantsLayer = true
        // Never redrawn: the layers carry it. `setNeedsDisplay` still works, and lands in
        // `updateLayer`, which is how a paused meter shows a change of geometry or state.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // Decorative to VoiceOver: a bar that moves 30 times a second has no value worth
        // announcing, and the figure it stands for is real text in the same block.
        setAccessibilityElement(false)
    }

    public override var wantsUpdateLayer: Bool { true }
    public override var isOpaque: Bool { false }

    var count = 1
    var vertical = true
    var thickness: CGFloat = 8
    var slot: CGFloat = 11
    var length: CGFloat = 46
    var level: (Int) -> Float = { _ in 0 }
    var hold: () -> Float? = { nil }
    var trackless = false
    var isDimmed: (Int) -> Bool = { _ in false }
    var noData: () -> Bool = { false }

    public override var intrinsicContentSize: NSSize {
        vertical ? NSSize(width: slot * CGFloat(count), height: length)
                 : NSSize(width: length, height: slot * CGFloat(count))
    }

    private var rate: Double = 0

    /// 0 leaves the shared clock: nothing to move while nothing is playing.
    func setRate(_ fps: Double) {
        guard fps != rate else { return }
        rate = fps
        MeterClock.shared.leave(self)
        if fps > 0, window != nil { MeterClock.shared.join(self, fps: fps) }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        MeterClock.shared.leave(self)
        if rate > 0, window != nil { MeterClock.shared.join(self, fps: rate) }
        needsDisplay = true
    }

    deinit { MeterClock.shared.leave(self) }

    // MARK: - Layers

    private final class Bar {
        /// A gradient, so a skin can zone the unlit bar (FMOD); one colour otherwise.
        let track = CAGradientLayer()
        let fill = CAGradientLayer()
        let mask = CALayer()
        let tick = CALayer()
        var shownFill: CGFloat = -1
        var shownTick: CGFloat = -1
        var dimmed: Bool?
        var tickRed: Bool?
    }
    private var bars: [Bar] = []
    /// The geometry the layers were built for, as numbers: a string key built every frame
    /// allocated on every meter at the display rate. nil forces a rebuild.
    private var builtFor: Geometry?
    private struct Geometry: Equatable {
        var count: Int, vertical: Bool, thickness: CGFloat, slot: CGFloat, size: CGSize
        var trackless: Bool
        /// The skin, so a change of look rebuilds the layers once, on the next frame.
        var skin: Skin
    }
    private var skin: Skin { builtFor?.skin ?? Skin.current }
    /// The appearance's colours, resolved once per build rather than every frame:
    /// `performAsCurrentDrawingAppearance` four times a frame per meter showed in the profile.
    private var palette: (track: CGColor, dimTrack: CGColor, grey: CGColor, hold: CGColor, red: CGColor)?
    /// The no-data dots: one dotted line along each bar's centre, drawn once per geometry and
    /// shown or hidden — nothing is redrawn per frame for them.
    private let dots = CAShapeLayer()
    /// A segmented skin's gaps across the bars (Logic, Pro Tools): drawn once per build, above
    /// the fills, never touched by the clock.
    private let segments = CAShapeLayer()
    private var shownEmpty: Bool?

    /// Level → position on a −60 dBFS scale, matching `meterFraction` in `Components.swift`.
    private static func fraction(_ peak: Float) -> CGFloat {
        guard peak > 0.0002 else { return 0 }
        let db = 20 * log10(Double(peak))
        return CGFloat(min(1, max(0, (db + 60) / 60)))
    }

    /// The same stops as before: green to −18 dBFS, amber to −6, red above. Keyed to level
    /// rather than bar position, and spanning the whole track, so the colour at a given
    /// height always means the same level.
    private static let rampColours: [CGColor] = [
        CGColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1), CGColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1),
        CGColor(red: 1.00, green: 0.80, blue: 0.00, alpha: 1), CGColor(red: 1.00, green: 0.58, blue: 0.00, alpha: 1),
        CGColor(red: 1.00, green: 0.23, blue: 0.19, alpha: 1), CGColor(red: 1.00, green: 0.23, blue: 0.19, alpha: 1),
    ]
    private static let rampStops: [NSNumber] = [0.00, 0.70, 0.80, 0.90, 0.983, 1.00]

    /// A system colour as this view's appearance resolves it: `labelColor` differs in dark mode.
    private func resolved(_ colour: NSColor) -> CGColor {
        var out = colour.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { out = colour.cgColor }
        return out
    }

    private var run: CGFloat { vertical ? bounds.height : bounds.width }
    /// Rounded normally; square-cut in REAPER's look.
    private var radius: CGFloat { skin.squareMeters ? 0 : min(thickness, run) / 2.5 }

    /// Where bar `i` sits across the meter. **Horizontal rows count from the top**: an `NSView`
    /// has its origin at the bottom-left, and the labels beside the rows run top-down.
    private func trackFrame(_ i: Int) -> CGRect {
        let gap = max(0, slot - thickness)
        return vertical
            ? CGRect(x: slot * CGFloat(i) + gap / 2, y: 0, width: thickness, height: run)
            : CGRect(x: 0, y: bounds.height - slot * CGFloat(i) - gap / 2 - thickness, width: run, height: thickness)
    }

    /// Makes the layers for the current geometry, if it changed.
    private func buildIfNeeded() {
        guard let root = layer else { return }
        let key = Geometry(count: count, vertical: vertical, thickness: thickness, slot: slot, size: bounds.size,
                           trackless: trackless, skin: Skin.current)
        guard key != builtFor else { return }
        builtFor = key
        palette = nil
        bars.forEach { $0.track.removeFromSuperlayer(); $0.fill.removeFromSuperlayer(); $0.tick.removeFromSuperlayer() }
        bars = (0..<count).map { _ in Bar() }
        let scale = window?.backingScaleFactor ?? 2
        for (i, bar) in bars.enumerated() {
            let frame = trackFrame(i)
            for l in [bar.track, bar.fill, bar.mask, bar.tick] as [CALayer] {
                l.contentsScale = scale
                l.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "hidden": NSNull(),
                             "backgroundColor": NSNull(), "colors": NSNull(), "cornerRadius": NSNull()]
            }
            bar.track.frame = frame
            bar.track.cornerRadius = radius
            bar.fill.frame = frame
            bar.fill.locations = Self.rampStops
            bar.fill.startPoint = CGPoint(x: 0, y: 0)
            bar.fill.endPoint = vertical ? CGPoint(x: 0, y: 1) : CGPoint(x: 1, y: 0)
            bar.mask.backgroundColor = CGColor(gray: 0, alpha: 1)
            bar.mask.isHidden = true
            bar.fill.mask = bar.mask
            bar.tick.isHidden = true
            root.addSublayer(bar.track)
            root.addSublayer(bar.fill)
            root.addSublayer(bar.tick)
        }
        let path = CGMutablePath()
        for i in 0..<count {
            let f = trackFrame(i)
            let inset = min(thickness, 3) / 2 + 0.5
            if vertical {
                path.move(to: CGPoint(x: f.midX, y: f.minY + inset)); path.addLine(to: CGPoint(x: f.midX, y: f.maxY - inset))
            } else {
                path.move(to: CGPoint(x: f.minX + inset, y: f.midY)); path.addLine(to: CGPoint(x: f.maxX - inset, y: f.midY))
            }
        }
        dots.path = path
        dots.frame = bounds
        dots.contentsScale = scale
        dots.fillColor = nil
        dots.lineWidth = min(thickness, 3)
        dots.lineCap = .round
        dots.lineDashPattern = [0.01, NSNumber(value: Double(max(4, min(thickness, 3) * 2 + 1.5)))]
        dots.actions = ["hidden": NSNull(), "path": NSNull(), "strokeColor": NSNull(), "frame": NSNull()]
        dots.isHidden = true
        if dots.superlayer == nil { root.addSublayer(dots) }
        segments.removeFromSuperlayer()
        if let pitch = skin.style.segmentPitch, pitch >= 2 {
            let gaps = CGMutablePath()
            for i in 0..<count {
                let f = trackFrame(i)
                var at = pitch
                while at < run {
                    gaps.addRect(vertical ? CGRect(x: f.minX, y: at, width: f.width, height: 1)
                                          : CGRect(x: at, y: f.minY, width: 1, height: f.height))
                    at += pitch
                }
            }
            segments.path = gaps
            segments.frame = bounds
            segments.contentsScale = scale
            segments.fillColor = (skin.style.meterWell ?? NSColor.windowBackgroundColor).cgColor
            segments.actions = ["path": NSNull(), "frame": NSNull(), "fillColor": NSNull()]
            root.addSublayer(segments)
        }
        shownEmpty = nil
        applyColours(force: true)
    }

    /// Track, fill and tick colours, for the appearance and for each bar's in-circuit state:
    /// grey, not a faded gradient, for a bar that is not reaching the output.
    private func applyColours(force: Bool) {
        let p = colours()
        let ramp = skin.style.meterRamp.map { $0.map(\.cgColor) } ?? Self.rampColours
        if force { dots.strokeColor = resolved(NSColor.labelColor.withAlphaComponent(0.35)) }
        for (i, bar) in bars.enumerated() {
            let faded = isDimmed(i)
            guard force || bar.dimmed != faded else { continue }
            bar.dimmed = faded
            if trackless {
                bar.track.colors = nil
                bar.track.backgroundColor = nil
            } else if let zones = skin.style.wellRamp, !faded {
                bar.track.backgroundColor = nil
                bar.track.colors = zones.map(\.cgColor)
                bar.track.locations = Self.rampStops
                bar.track.startPoint = .zero
                bar.track.endPoint = vertical ? CGPoint(x: 0, y: 1) : CGPoint(x: 1, y: 0)
            } else {
                bar.track.colors = nil
                bar.track.backgroundColor = faded ? p.dimTrack : p.track
            }
            bar.fill.colors = faded ? [p.grey, p.grey] : ramp
            bar.tickRed = nil
        }
    }

    /// The resolved colours, from the cache when the build and appearance have not changed.
    private func colours() -> (track: CGColor, dimTrack: CGColor, grey: CGColor, hold: CGColor, red: CGColor) {
        if let palette { return palette }
        // A skin may set its own well and hold colours — REAPER's near-black well, say — the
        // same in either appearance.
        let style = skin.style
        let p = (track: style.meterWell?.cgColor ?? resolved(NSColor.labelColor.withAlphaComponent(0.10)),
                 dimTrack: style.meterWell?.withAlphaComponent(0.6).cgColor
                     ?? resolved(NSColor.labelColor.withAlphaComponent(0.05)),
                 grey: resolved(NSColor.labelColor.withAlphaComponent(0.30)),
                 hold: style.meterHold?.cgColor ?? resolved(NSColor.labelColor.withAlphaComponent(0.6)),
                 red: resolved(.systemRed))
        palette = p
        return p
    }

    /// One frame: the masks and ticks follow the levels. Called by the shared clock inside its
    /// transaction, and by `updateLayer` when AppKit asks.
    func refresh() {
        buildIfNeeded()
        let empty = noData()
        if empty != shownEmpty {
            shownEmpty = empty
            dots.isHidden = !empty
            for bar in bars {
                bar.track.isHidden = empty
                bar.fill.isHidden = empty
                bar.tick.isHidden = true
                bar.shownFill = -1          // redrawn from scratch when data returns
                bar.shownTick = -2
            }
        }
        if empty { return }
        applyColours(force: false)
        let run = self.run, radius = self.radius
        let peakHold = hold()
        let palette = colours()
        for (i, bar) in bars.enumerated() {
            let filled = (run * Self.fraction(level(i)) * 2).rounded() / 2      // half a point
            if filled != bar.shownFill {
                bar.shownFill = filled
                bar.mask.isHidden = filled <= 0.5
                if filled > 0.5 {
                    bar.mask.frame = vertical ? CGRect(x: 0, y: 0, width: thickness, height: filled)
                                              : CGRect(x: 0, y: 0, width: filled, height: thickness)
                    bar.mask.cornerRadius = min(radius, filled / 2)
                }
            }
            let at: CGFloat = (bar.dimmed == true) ? -1
                : (peakHold.map { $0 > 0.0002 ? (run * Self.fraction($0) * 2).rounded() / 2 : -1 } ?? -1)
            if at != bar.shownTick {
                bar.shownTick = at
                bar.tick.isHidden = at < 0
                if at >= 0 {
                    let f = bar.track.frame
                    bar.tick.frame = vertical ? CGRect(x: f.minX, y: max(0, at - 0.75), width: thickness, height: 1.5)
                                              : CGRect(x: max(0, at - 0.75), y: f.minY, width: 1.5, height: thickness)
                }
            }
            let red = (peakHold ?? 0) >= 0.999
            if at >= 0, bar.tickRed != red {
                bar.tickRed = red
                bar.tick.backgroundColor = red ? palette.red : palette.hold
            }
        }
    }

    public override func updateLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        refresh()
        CATransaction.commit()
    }

    public override func layout() {
        super.layout()
        needsDisplay = true
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        builtFor = nil                  // rebuild, so every colour is resolved for the new look
        needsDisplay = true
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        builtFor = nil
        needsDisplay = true
    }
}

/// The one clock every meter runs on, per rate. Each tick moves every bar in the window inside a
/// single Core Animation transaction, with implicit animations off.
///
/// **A display link, not a timer.** A
/// `Timer` at 30 Hz beats against a 60 or 120 Hz display, so a bar's steps land on uneven frames
/// and read as judder; a screen's `CADisplayLink` asked for 30 Hz fires on the display's own
/// frames, and stops while the display sleeps. It belongs to a screen, so it is rebuilt when the
/// screens change. With no screen at all — the render harnesses — it falls back to the timer.
final class MeterClock: NSObject {
    static let shared = MeterClock()
    private var members: [Double: NSHashTable<MeterLayer>] = [:]
    private var timers: [Double: Timer] = [:]
    private var links: [Double: CADisplayLink] = [:]
    private var watchingScreens = false

    func join(_ meter: MeterLayer, fps: Double) {
        let table = members[fps] ?? NSHashTable<MeterLayer>.weakObjects()
        table.add(meter)
        members[fps] = table
        guard timers[fps] == nil, links[fps] == nil else { return }
        start(fps)
    }

    private func start(_ fps: Double) {
        if !watchingScreens {
            watchingScreens = true
            NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                                   name: NSApplication.didChangeScreenParametersNotification,
                                                   object: nil)
        }
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let link = screen.displayLink(target: self, selector: #selector(step(_:)))
            let rate = Float(fps)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
            // `.common` so the meters keep moving while a menu is open or the window is being
            // resized, which is exactly when someone is looking at them.
            link.add(to: .main, forMode: .common)
            links[fps] = link
        } else {
            let t = Timer(timeInterval: 1 / fps, repeats: true) { [weak self] _ in self?.tick(fps) }
            RunLoop.main.add(t, forMode: .common)
            timers[fps] = t
        }
    }

    private func stop(_ fps: Double) {
        timers[fps]?.invalidate(); timers[fps] = nil
        links[fps]?.invalidate(); links[fps] = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let fps = links.first(where: { $0.value === link })?.key else { return }
        tick(fps)
    }

    /// A display added, removed or rearranged: the link's screen may be gone, so start again on
    /// whichever screen is main now.
    @objc private func screensChanged() {
        for fps in Array(members.keys) { stop(fps); start(fps) }
    }

    func leave(_ meter: MeterLayer) {
        for (fps, table) in members where table.contains(meter) {
            table.remove(meter)
            if table.allObjects.isEmpty {
                stop(fps)
                members[fps] = nil
            }
        }
    }

    private func tick(_ fps: Double) {
        guard let table = members[fps] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for meter in table.allObjects {
            // A window that is hidden, minimised or fully covered shows nothing: skip it.
            guard let window = meter.window, window.occlusionState.contains(.visible) else { continue }
            meter.refresh()
        }
        CATransaction.commit()
    }
}
