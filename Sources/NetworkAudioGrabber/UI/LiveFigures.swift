import SwiftUI
import AppKit

/// The Detailed figures — each row's jitter and the open stream's grid of ten — drawn by AppKit
/// text fields that update themselves on the tick's beat.
///
/// They were SwiftUI `Text` inside `FiguresBeat`, which re-evaluated and re-laid-out each block
/// four times a second: the ~9 ms of layout per tick the Detailed profile showed. Here the beat is
/// a notification, not observed state, so SwiftUI does no work for it at all; a field is only
/// touched when its string or colour actually changes, and a hidden window skips the beat.
enum FigureBeat {
    static let name = Notification.Name("app.networkaudiograbber.figure-beat")
    /// Called by the tick while Detailed has a stream playing.
    static func post() { NotificationCenter.default.post(name: name, object: nil) }
}

/// Label-over-value cells in equal columns, as `StreamDetailBlock` lays them out.
struct LiveFigureGrid: NSViewRepresentable {
    let columns: Int
    let cells: () -> [(String, String, Bool)]

    func makeNSView(context: Context) -> LiveFigureGridView {
        let v = LiveFigureGridView(); v.columns = columns; v.cells = cells; return v
    }
    func updateNSView(_ view: LiveFigureGridView, context: Context) {
        view.columns = columns
        view.cells = cells
        view.refresh()
    }
}

/// One right-aligned figure, for the row's jitter column.
struct LiveFigureText: NSViewRepresentable {
    let text: () -> (String, Bool)

    func makeNSView(context: Context) -> LiveFigureTextView {
        let v = LiveFigureTextView(); v.text = text; return v
    }
    func updateNSView(_ view: LiveFigureTextView, context: Context) {
        view.text = text
        view.refresh()
    }
}

/// What both views share: joining the beat while in a window, and skipping it while hidden.
class LiveFigureBase: NSView {
    private var observer: NSObjectProtocol?

    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard window != nil else { return }
        observer = NotificationCenter.default.addObserver(forName: FigureBeat.name, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let w = self.window, w.occlusionState.contains(.visible) else { return }
                self.refresh()
            }
        }
        refresh()
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func refresh() {}

    /// A warning figure's colour: orange, or the skin's own where orange cannot be read on its
    /// ground (Abletron's grey).
    static var warning: NSColor { Skin.current.style.warning.map { NSColor($0) } ?? .systemOrange }

    static func field(size: CGFloat, mono: Bool, colour: NSColor) -> NSTextField {
        let f = NSTextField(labelWithString: "")
        f.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
        f.textColor = colour
        f.lineBreakMode = .byTruncatingMiddle
        f.maximumNumberOfLines = 1
        f.cell?.truncatesLastVisibleLine = true
        return f
    }
}

final class LiveFigureGridView: LiveFigureBase {
    var columns = 4
    var cells: () -> [(String, String, Bool)] = { [] }
    private var labels: [NSTextField] = []
    private var values: [NSTextField] = []

    override func refresh() {
        let now = cells()
        if now.count != values.count { rebuild(now.count) }
        for (i, cell) in now.enumerated() {
            // Sentence case at a readable size.
            let label = cell.0.prefix(1).uppercased() + cell.0.dropFirst()
            if labels[i].stringValue != label { labels[i].stringValue = label }
            if values[i].stringValue != cell.1 {
                values[i].stringValue = cell.1
                // The whole value, for when the middle had to go.
                values[i].toolTip = cell.1
            }
            let colour: NSColor = cell.2 ? Self.warning : .secondaryLabelColor
            if values[i].textColor != colour { values[i].textColor = colour }
        }
    }

    private func rebuild(_ count: Int) {
        (labels + values).forEach { $0.removeFromSuperview() }
        labels = (0..<count).map { _ in Self.field(size: 10, mono: false, colour: .mutedLabel) }
        values = (0..<count).map { _ in Self.field(size: 12, mono: true, colour: .secondaryLabelColor) }
        (labels + values).forEach(addSubview)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let gap: CGFloat = 8
        let width = max(0, (bounds.width - gap * CGFloat(columns - 1)) / CGFloat(columns))
        for i in values.indices {
            let x = CGFloat(i % columns) * (width + gap)
            let y = CGFloat(i / columns) * (30 + 7)          // 10-point label over a 12-point value
            labels[i].frame = NSRect(x: x, y: y, width: width, height: 13)
            values[i].frame = NSRect(x: x, y: y + 14, width: width, height: 16)
        }
    }
}

final class LiveFigureTextView: LiveFigureBase {
    var text: () -> (String, Bool) = { ("", false) }
    private lazy var label: NSTextField = {
        let f = Self.field(size: 10, mono: true, colour: .secondaryLabelColor)
        f.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        f.alignment = .right
        addSubview(f)
        return f
    }()

    override func refresh() {
        let (string, warns) = text()
        if label.stringValue != string { label.stringValue = string }
        let colour: NSColor = warns ? Self.warning : .secondaryLabelColor
        if label.textColor != colour { label.textColor = colour }
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: (bounds.height - 14) / 2, width: bounds.width, height: 14)
    }
}
