import SwiftUI
import AppKit

/// Resizes the window when the view mode changes, and remembers the size each mode was left at.
///
/// `.windowResizability(.contentMinSize)` takes the window's *minimum* from the content, which
/// stops it being dragged too small but will not shrink a window that is already large —
/// switching to the compact view otherwise leaves a 1120-point window with a 380-point strip in
/// one corner of it. So the `NSWindow` is resized explicitly, which also lets each mode keep its
/// own shape instead of one clobbering the other.
/// Which mode the window has actually been shaped to, and the floor it was shaped against.
///
/// **Owned by `AppState`, not by the view.** This is the state that decides whether a layout
/// pass is a mode *change* or just another update, and a view that can be rebuilt cannot be
/// trusted to hold it: the shaper used to keep it in its `Coordinator`, the coordinator was
/// destroyed every time the window mode switched, and the mode-change branch consequently
/// never ran at all.
final class WindowShapeMemory {
    var applied: ViewMode?
    var lastMinimum: CGSize?
}

struct WindowShaper: NSViewRepresentable {
    let mode: ViewMode
    let minimumSize: CGSize
    let targetSize: CGSize
    /// Whether the window takes its height from `minimumSize` whenever that changes.
    ///
    /// True for the compact window, whose sections fold: folding one should shrink the window to
    /// fit rather than leave it padded out with nothing, and unfolding should grow it back.
    /// False for the full window, where the minimum moves when the signal panel is toggled and
    /// resizing the window under the user would be unwelcome.
    var snapToMinimumHeight = false
    /// Survives this view being rebuilt. See `WindowShapeMemory`.
    let memory: WindowShapeMemory
    /// Called with the size a mode is sitting at, both while it is being resized by hand and as
    /// it is left behind for the other mode.
    let onSizeChange: (ViewMode, CGSize) -> Void

    final class Coordinator {
        /// Watches for the user letting go of the window edge. Installed once per window.
        var resizeObserver: NSObjectProtocol?
        /// The mode and callback as of the last layout, for the observer to use when it fires.
        var mode: ViewMode = .full
        var report: ((ViewMode, CGSize) -> Void)?

        deinit {
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // There is no window yet at this point in the cycle.
        DispatchQueue.main.async { apply(around: view, coordinator: context.coordinator) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { apply(around: view, coordinator: context.coordinator) }
    }

    private func apply(around view: NSView, coordinator: Coordinator) {
        guard let window = view.window else { return }

        // **A size is recorded when the user finishes dragging, and when a mode is left —
        // never on a view update.**
        //
        // It used to be recorded on every `updateNSView`, of which there are a great many, and
        // the resize below is animated: the first update after switching to the compact window
        // read `window.frame` part-way through the animation and wrote *that* in as the size
        // the compact window was left at. Whatever the last update happened to catch became
        // the remembered size, which is why it came back at some arbitrary width. The window
        // server knows exactly when a drag ends; there is no reason to guess.
        coordinator.mode = mode
        coordinator.report = onSizeChange
        if coordinator.resizeObserver == nil {
            coordinator.resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didEndLiveResizeNotification,
                object: window, queue: .main) { [weak coordinator] note in
                    guard let coordinator,
                          let window = note.object as? NSWindow else { return }
                    coordinator.report?(coordinator.mode,
                                        window.contentRect(forFrameRect: window.frame).size)
                }
        }

        // **Read the size before touching anything.** On a mode change this call arrives with
        // the *incoming* mode's minimum, and the grow-to-floor below would push a 380-point
        // compact window out to the full window's 1080 before the outgoing size was recorded —
        // so switching to the full window wrote 1080 into the compact window's remembered
        // width, and the compact window came back the size of the full one. The size a mode is
        // left at is the size it had on the way out, measured on the way in.
        let entry = window.contentRect(forFrameRect: window.frame).size
        if ProcessInfo.processInfo.arguments.contains("--shapertrace") {
            let line = "shaper: mode=\(mode) applied=\(String(describing: memory.applied))"
                + " entry=\(Int(entry.width))x\(Int(entry.height))"
                + " min=\(Int(minimumSize.width))x\(Int(minimumSize.height))"
                + " target=\(Int(targetSize.width))x\(Int(targetSize.height))"
                + " contentMin=\(Int(window.contentMinSize.width))x\(Int(window.contentMinSize.height))\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        // **Nothing is recorded from a measurement of the window.**
        //
        // This used to record the outgoing mode's size here, on the way in, which reads as the
        // careful thing to do and is not: the hosting view propagates the *previous* mode's
        // content minimum to `contentMinSize` asynchronously, so a compact window set to 372
        // was 1080 wide again a moment later with the full window's floor still attached — and
        // this line faithfully stored 1080 as the size the compact window had been left at.
        // Three fixes went into the recording before it became clear the recording was right
        // and its input was wrong.
        //
        // The only authority on the size a mode was left at is the user resizing it, which
        // arrives as `didEndLiveResize` above. A width imposed by the layout system is not a
        // choice and is never remembered.

        // Lower the floor first, or `setFrame` below is clamped to the old mode's minimum.
        window.contentMinSize = minimumSize
        var current = entry

        // **Raising a minimum does not grow a window that is already smaller.** AppKit applies
        // `contentMinSize` to future resizes, not to the frame it is holding — so a window
        // restored at 340 points with a 372-point floor simply scrolled, and the scroll bar
        // looked like the floor being a few points mean when it was the window ignoring it.
        if current.height < minimumSize.height - 1 || current.width < minimumSize.width - 1 {
            resize(window, to: CGSize(width: max(current.width, minimumSize.width),
                                      height: max(current.height, minimumSize.height)))
            current = window.contentRect(forFrameRect: window.frame).size
        }

        guard memory.applied != mode else {
            // Same mode, but the content's floor moved — a section folded or unfolded. Take
            // the new height and leave the width alone, since the width is the user's.
            if snapToMinimumHeight, let last = memory.lastMinimum,
               abs(last.height - minimumSize.height) > 1 {
                memory.lastMinimum = minimumSize
                resize(window, to: CGSize(width: current.width, height: minimumSize.height))
                onSizeChange(mode, CGSize(width: current.width, height: minimumSize.height))
                return
            }
            memory.lastMinimum = minimumSize
            return
        }
        memory.lastMinimum = minimumSize
        let previous = memory.applied
        memory.applied = mode

        // First layout of a freshly opened window: AppKit has already restored the frame the
        // app was last quit at, and overriding that would move the window out from under the
        // user for no reason. Adopt what is there and note it as this mode's size.
        guard previous != nil else {
            onSizeChange(mode, current)
            return
        }
        // The outgoing mode's size was recorded at the top, before the floor moved.
        //
        // **Re-asserted, because something else is also sizing this window.** The hosting view
        // propagates the SwiftUI content's own minimum to `contentMinSize`, and it does so
        // asynchronously — so for a moment after the switch the window still carries the *old*
        // mode's floor and clamps our resize back up to it. Traced: a compact window set to
        // 372 was 1080 wide again a second later, with the full window's 1080-point minimum
        // still attached, and the next mode change recorded that 1080 as the size the compact
        // window had been left at. Hence three earlier fixes aimed at the recording, when the
        // recording was faithfully storing a width something else had imposed.
        //
        // So the target is applied now and again on the next two turns of the main queue, each
        // time re-lowering the floor first. Cheap, idempotent, and it stops as soon as the
        // window is where it was asked to be.
        let wanted = CGSize(width: max(minimumSize.width, targetSize.width),
                            height: max(minimumSize.height, targetSize.height))
        assert(window: window, to: wanted, attempt: 0)
    }

    /// Applies `wanted` and checks, twice, that it stuck.
    private func assert(window: NSWindow, to wanted: CGSize, attempt: Int) {
        window.contentMinSize = minimumSize
        resize(window, to: wanted, animate: false)
        guard attempt < 2 else { return }
        DispatchQueue.main.async {
            let now = window.contentRect(forFrameRect: window.frame).size
            guard abs(now.width - wanted.width) > 1 || abs(now.height - wanted.height) > 1
            else { return }
            self.assert(window: window, to: wanted, attempt: attempt + 1)
        }
    }

    /// Resizes the content to `wanted`, holding the top edge still so the window does not walk
    /// up the screen as it grows and shrinks.
    private func resize(_ window: NSWindow, to wanted: CGSize, animate: Bool = true) {
        let current = window.contentRect(forFrameRect: window.frame).size
        guard abs(wanted.width - current.width) > 1
                || abs(wanted.height - current.height) > 1 else { return }

        var frame = window.frame
        let chrome = frame.height - current.height          // title bar
        let height = wanted.height + chrome
        frame.origin.y += frame.height - height
        frame.size = CGSize(width: wanted.width, height: height)
        window.setFrame(frame, display: true, animate: animate)
    }
}
