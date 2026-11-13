import SwiftUI
import AppKit

/// The last 30 seconds of the output peak, for "did it drop out a moment ago?" (after Audio
/// Hijack's transport strip). On by default — it costs nothing measurable — and
/// Settings → View turns it off.
///
/// **Cheap by construction.** A quarter-second sample of what the bars already measure, kept in a
/// fixed ring of 120 by the app's tick; drawn by one AppKit view on its own 4 Hz timer, skipped
/// while the window is hidden — nothing in SwiftUI re-evaluates for it. The colours are muted on
/// purpose: grey, a little darker when loud, and a subdued red only where
/// audio did not arrive or the buffer ran out.
final class LevelHistoryStore {
    static let capacity = 120            // 30 s at 4 a second
    private(set) var peaks = [Float](repeating: 0, count: capacity)
    private(set) var faults = [Bool](repeating: false, count: capacity)
    /// Where the next sample goes; the oldest is here too.
    private(set) var head = 0
    private(set) var filled = 0
    /// Bumped whenever what the strip shows changes; the view redraws only then.
    private(set) var generation = 0
    /// Silent samples in a row. Once the whole strip is silence, more silence changes nothing
    /// that can be seen, so it is not pushed — and the strip is not redrawn — until audio returns.
    private var quietRun = 0

    func push(_ peak: Float, fault: Bool) {
        let quiet = peak <= 0.0002 && !fault
        quietRun = quiet ? quietRun + 1 : 0
        if quiet, quietRun > Self.capacity, filled == Self.capacity { return }
        peaks[head] = peak
        faults[head] = fault
        head = (head + 1) % Self.capacity
        filled = min(Self.capacity, filled + 1)
        generation &+= 1
        NotificationCenter.default.post(name: Self.pushed, object: self)
    }

    /// Posted on each new sample (main thread), which is what the strip redraws on: its own
    /// timer, out of step with the sampling, drew two new samples one time and none the next,
    /// so the strip moved in jerks.
    static let pushed = Notification.Name("app.networkaudiograbber.level-history-pushed")

    func clear() {
        peaks = [Float](repeating: 0, count: Self.capacity)
        faults = [Bool](repeating: false, count: Self.capacity)
        head = 0; filled = 0; quietRun = 0
        generation &+= 1
    }
}

struct LevelHistoryStrip: View {
    @Environment(AppState.self) var state
    var height: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LevelHistoryGraph(store: state.levelHistory)
                .frame(height: height)
                .frame(maxWidth: .infinity)
            HStack {
                Text("30 s ago")
                Spacer()
                Text("now")
            }
            .font(.system(size: 9))
            .foregroundStyle(Color.mutedLabel)
        }
        .help("The output peak over the last 30 seconds. A red mark is a moment when audio "
            + "stopped arriving or the buffer ran out. Turn it off in Settings → View.")
        .accessibilityElement()
        .accessibilityLabel("Output level history, last 30 seconds")
    }
}

private struct LevelHistoryGraph: NSViewRepresentable {
    let store: LevelHistoryStore
    func makeNSView(context: Context) -> LevelHistoryView {
        let v = LevelHistoryView(); v.store = store; return v
    }
    func updateNSView(_ view: LevelHistoryView, context: Context) { view.store = store }
    static func dismantleNSView(_ view: LevelHistoryView, coordinator: ()) { view.stop() }
}

final class LevelHistoryView: NSView {
    var store: LevelHistoryStore?
    private var observer: NSObjectProtocol?
    /// The store's generation last drawn, so an unchanged strip is not redrawn.
    private var drawn = -1

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        observer = NotificationCenter.default.addObserver(forName: LevelHistoryStore.pushed, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let w = self.window, w.occlusionState.contains(.visible),
                      let store = self.store, store.generation != self.drawn else { return }
                self.needsDisplay = true
            }
        }
        needsDisplay = true
    }

    func stop() { if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private static func fraction(_ peak: Float) -> CGFloat {
        guard peak > 0.0002 else { return 0 }
        return CGFloat(min(1, max(0, (20 * log10(Double(peak)) + 60) / 60)))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let store, let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawn = store.generation
        let n = LevelHistoryStore.capacity
        let step = bounds.width / CGFloat(n)
        let bar = max(1, step * 0.6)
        let quiet = NSColor.labelColor.withAlphaComponent(0.30).cgColor
        let loud = NSColor.labelColor.withAlphaComponent(0.55).cgColor
        let fault = NSColor.systemRed.withAlphaComponent(0.55).cgColor
        let floor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        let mid = bounds.midY
        // Oldest on the left: sample i of the last n, counting from the ring's head.
        for i in 0..<n {
            let k = (store.head + i) % n
            let x = CGFloat(i) * step
            guard i >= n - store.filled else {
                ctx.setFillColor(floor)
                ctx.fill(CGRect(x: x, y: mid - 0.5, width: bar, height: 1))
                continue
            }
            if store.faults[k] {
                ctx.setFillColor(fault)
                ctx.fill(CGRect(x: x, y: 0, width: bar, height: bounds.height))
                continue
            }
            let f = Self.fraction(store.peaks[k])
            let h = max(1, bounds.height * f)
            ctx.setFillColor(f > 0.8 ? loud : quiet)        // above about −12 dBFS
            ctx.fill(CGRect(x: x, y: mid - h / 2, width: bar, height: h))
        }
    }
}
