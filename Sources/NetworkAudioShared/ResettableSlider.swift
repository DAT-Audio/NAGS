import SwiftUI
import AppKit

/// A slider that returns to its default on a **double-click**.
///
/// SwiftUI's `Slider` cannot do this. Attaching a `TapGesture(count: 2)` to one — even as a
/// `simultaneousGesture` — does nothing reliable, because the `NSSlider` underneath takes the
/// mouse down for its own drag tracking and the gesture never completes. That was the first
/// attempt and it did not work, which is the kind of thing only clicking finds.
///
/// So the slider is AppKit, where the event is there to be read: `mouseDown` sees
/// `clickCount == 2` and resets instead of starting a drag. Single clicks and drags fall through
/// to `super`, so it behaves exactly like any other slider otherwise.
public struct ResettableSlider: NSViewRepresentable {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    /// Rounds each change, for the sliders that are whole-numbered (the buffer, in ms).
    var step: Double?
    /// Where a double-click puts it.
    var defaultValue: Double
    var tint: Color?
    var controlSize: NSControl.ControlSize = .small

    public init(value: Binding<Double>, range: ClosedRange<Double> = 0...1, step: Double? = nil,
                defaultValue: Double, tint: Color? = nil, controlSize: NSControl.ControlSize = .small) {
        self._value = value; self.range = range; self.step = step
        self.defaultValue = defaultValue; self.tint = tint; self.controlSize = controlSize
    }

    public final class Coordinator {
        var onChange: (Double) -> Void = { _ in }
        var onReset: () -> Void = {}

        @objc func changed(_ sender: NSSlider) { onChange(sender.doubleValue) }
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> DoubleClickSlider {
        let slider = DoubleClickSlider()
        slider.cell = FillSliderCell()
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.isContinuous = true
        slider.onDoubleClick = { [coordinator = context.coordinator] in coordinator.onReset() }
        apply(to: slider, context: context)
        return slider
    }

    public func updateNSView(_ slider: DoubleClickSlider, context: Context) {
        apply(to: slider, context: context)
    }

    private func apply(to slider: DoubleClickSlider, context: Context) {
        context.coordinator.onChange = { raw in
            let snapped = step.map { ($0 == 0 ? raw : (raw / $0).rounded() * $0) } ?? raw
            if abs(snapped - value) > 1e-9 { value = snapped }
        }
        context.coordinator.onReset = { value = defaultValue }

        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.controlSize = controlSize
        if abs(slider.doubleValue - value) > 1e-9 { slider.doubleValue = value }
        // Drawn by our own cell: macOS 26 ignores `trackFillColor`, so every slider's fill came
        // out in the system's grey rather than the scheme's colour.
        if let cell = slider.cell as? FillSliderCell {
            let fill = tint.map { NSColor($0) } ?? .controlAccentColor
            if cell.fill != fill || cell.skin != Skin.current {
                cell.fill = fill
                cell.skin = Skin.current
                slider.needsDisplay = true
            }
        }
    }
}

/// The AppKit half: a slider that treats a double-click as "put it back".
public final class DoubleClickSlider: NSSlider {
    var onDoubleClick: (() -> Void)?

    public override func mouseDown(with event: NSEvent) {
        guard event.clickCount < 2 else {
            onDoubleClick?()
            return
        }
        super.mouseDown(with: event)
    }
}

/// The bar in the scheme's colour up to the knob, and a faint track beyond it; the knob is the
/// system's own.
final class FillSliderCell: NSSliderCell {
    var fill: NSColor = .controlAccentColor
    var skin: Skin = .standard

    /// A skin's fader cap: its own size, so the hit area follows it.
    override func knobRect(flipped: Bool) -> NSRect {
        let r = super.knobRect(flipped: flipped)
        guard let f = skin.style.fader else { return r }
        let scale: CGFloat = controlSize == .mini ? 0.82 : 1
        let w = f.capSize.width * scale, h = min(r.height, f.capSize.height * scale)
        return NSRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }

    override func drawKnob(_ knobRect: NSRect) {
        guard let f = skin.style.fader else { super.drawKnob(knobRect); return }
        if f.triangle {
            // A pointer down onto the line, as Ableton's.
            let t = NSBezierPath()
            t.move(to: NSPoint(x: knobRect.minX, y: knobRect.minY + 1))
            t.line(to: NSPoint(x: knobRect.maxX, y: knobRect.minY + 1))
            t.line(to: NSPoint(x: knobRect.midX, y: knobRect.maxY - 1))
            t.close()
            f.capTop.setFill()
            t.fill()
            return
        }
        let cap = knobRect.insetBy(dx: 0.5, dy: 0.5)
        var path = NSBezierPath(roundedRect: cap, xRadius: f.capRadius, yRadius: f.capRadius)
        if f.pentagon {
            // A head with a point downward, onto the line.
            path = NSBezierPath()
            let shoulder = cap.minY + cap.height * 0.55
            path.move(to: NSPoint(x: cap.minX, y: cap.maxY))
            path.line(to: NSPoint(x: cap.maxX, y: cap.maxY))
            path.line(to: NSPoint(x: cap.maxX, y: shoulder))
            path.line(to: NSPoint(x: cap.midX, y: cap.minY))
            path.line(to: NSPoint(x: cap.minX, y: shoulder))
            path.close()
        }
        NSGradient(starting: f.capTop, ending: f.capBottom)?.draw(in: path, angle: -90)
        f.capStroke.setStroke()
        path.lineWidth = 1
        path.stroke()
        f.gripColour.setFill()
        switch f.grip {
        case .none: break
        case .centreLine:
            NSRect(x: cap.minX + 1.5, y: cap.midY - 0.75, width: cap.width - 3, height: 1.5).fill()
        case .lines(let n):
            // Grip lines across the cap, evenly spaced about its middle.
            let gap: CGFloat = 2.5
            let first = cap.midY - gap * CGFloat(n - 1) / 2
            for k in 0..<n {
                NSRect(x: cap.minX + 2, y: first + gap * CGFloat(k) - 0.5, width: cap.width - 4, height: 1).fill()
            }
        }
        NSColor(white: 1, alpha: 0.3).setFill()
        NSRect(x: cap.minX + 1.5, y: cap.minY + 1, width: cap.width - 3, height: 1).fill()
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        if let f = skin.style.fader {
            let h = f.grooveHeight
            let groove = NSRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h)
            f.groove.setFill()
            NSBezierPath(roundedRect: groove, xRadius: min(1, h / 2), yRadius: min(1, h / 2)).fill()
            if f.fillsGroove {
                var filled = groove
                filled.size.width = max(0, min(groove.width, knobRect(flipped: flipped).midX - groove.minX))
                let colour = f.grooveFill ?? fill
                (isEnabled ? colour : colour.withAlphaComponent(0.4)).setFill()
                NSBezierPath(roundedRect: filled, xRadius: min(1, h / 2), yRadius: min(1, h / 2)).fill()
            } else {
                NSColor(white: 1, alpha: 0.10).setFill()
                NSRect(x: groove.minX, y: groove.maxY, width: groove.width, height: 0.5).fill()
            }
            return
        }
        let thickness: CGFloat = controlSize == .mini ? 3 : 4
        let bar = NSRect(x: rect.minX, y: rect.midY - thickness / 2, width: rect.width, height: thickness)
        let radius = thickness / 2
        NSColor.labelColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()
        var filled = bar
        filled.size.width = max(0, min(bar.width, knobRect(flipped: flipped).midX - bar.minX))
        (isEnabled ? fill : fill.withAlphaComponent(0.4)).setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}
