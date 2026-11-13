import SwiftUI
import AppKit

/// The About window, in place of macOS's standard panel: the
/// icon, name and version, then the credits (`Credits`) scrolling slowly by themselves, with
/// Licences… and the Quick Start Guide. The standard panel can show credits, but only standing
/// still. The scrolling is polite: it pauses under the pointer, can be scrolled by hand, and
/// stays still when *Reduce motion* is on. Same window in both apps; plain AppKit windows, so
/// neither app's SwiftUI scenes change.
@MainActor
public enum AboutWindow {
    private static var window: NSWindow?
    /// The look of the window that asked, for the Licences window opened from here or Settings.
    static var tint: Color = .accentColor

    /// `tint`: the app's active colour, for the section titles.
    public static func show(tint: Color) {
        Self.tint = tint
        if let window {
            window.appearance = currentAppearance()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = AboutView(tint: tint)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 500),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.contentView = NSHostingView(rootView: view)
        w.appearance = currentAppearance()
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { AboutWindow.window = nil }
        }
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    /// The app window's look — the apps set light or dark per window, not for the whole app.
    static func currentAppearance() -> NSAppearance? {
        let source = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
        return source.map { NSAppearance(named: $0.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) ?? .darkAqua) } ?? nil
    }
}

public struct AboutView: View {
    let tint: Color
    public init(tint: Color) { self.tint = tint }
    @Environment(\.colorScheme) private var scheme

    private var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName
    }
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Version \(short) (\(build))"
    }
    private var panel: Color { scheme == .dark ? Color(white: 0.105) : Color(white: 0.97) }

    public var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 88, height: 88)
                .padding(.top, 30)
            Text(name).font(.system(size: 17, weight: .bold)).padding(.top, 6)
            Text(version).font(.system(size: 12)).foregroundStyle(Color.mutedLabel).padding(.top, 2)
            Text(Credits.copyright).font(.system(size: 11.5)).foregroundStyle(Color.mutedLabel).padding(.top, 2)

            CreditsScroller(tint: tint, panel: panel)
                .frame(height: 220)
                .overlay(alignment: .top) {
                    LinearGradient(colors: [panel, panel.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 30).allowsHitTesting(false)
                }
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [panel.opacity(0), panel], startPoint: .top, endPoint: .bottom)
                        .frame(height: 30).allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12), lineWidth: 1))
                .padding(.top, 14)

            HStack(spacing: 8) {
                Button("Licences\u{2026}") { LicencesWindow.show() }
                Button(QuickStart.menuTitle) { QuickStart.open() }
            }
            .controlSize(.regular)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 22)
        .frame(width: 340)
    }
}

/// The credits as one centred column, for the scroller.
struct CreditsColumn: View {
    let tint: Color
    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 18)
            ForEach(Credits.sections) { section in
                Text(section.title.uppercased())
                    .font(.system(size: 10.5, weight: .bold)).kerning(0.8)
                    .foregroundStyle(tint)
                    .padding(.top, 14).padding(.bottom, 5)
                ForEach(section.items) { item in
                    VStack(spacing: 1) {
                        if !item.title.isEmpty { Text(item.title).font(.system(size: 11.5, weight: .semibold)) }
                        Text(item.detail).font(.system(size: 10.5)).foregroundStyle(Color.mutedLabel)
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
                }
            }
            Color.clear.frame(height: 24)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
    }
}

/// An `NSScrollView` that moves itself: about 20 points a second, a pause at each end, then back
/// to the top. Pauses while the pointer is over it (so it can be read or scrolled by hand) and
/// does not move at all with Reduce motion on. Its timer runs only while the window is on screen.
struct CreditsScroller: NSViewRepresentable {
    let tint: Color
    let panel: Color

    func makeNSView(context: Context) -> AutoScrollView {
        let v = AutoScrollView()
        v.setContent(NSHostingController(rootView: CreditsColumn(tint: tint)), background: NSColor(panel))
        return v
    }

    func updateNSView(_ v: AutoScrollView, context: Context) {
        v.backgroundColor = NSColor(panel)
    }
}

final class AutoScrollView: NSScrollView {
    static let pointsPerSecond: CGFloat = 20
    static let holdAtEnds: TimeInterval = 2.5

    private let document = FlippedView()
    private var host: NSHostingController<CreditsColumn>?
    private var timer: Timer?
    private var pointerInside = false
    private var lastTick: CFTimeInterval = 0
    private var holdUntil: CFTimeInterval = 0
    private var position: CGFloat = 0

    func setContent(_ content: NSHostingController<CreditsColumn>, background: NSColor) {
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        drawsBackground = true
        backgroundColor = background
        documentView = document
        document.addSubview(content.view)
        host = content
        holdUntil = CACurrentMediaTime() + Self.holdAtEnds
    }

    override func layout() {
        super.layout()
        guard let host else { return }
        // Measured at the width it will have: measured unconstrained, the text wraps less, comes
        // out shorter than it draws, and is centred so that its top is cut off.
        let width = contentSize.width
        let needed = host.sizeThatFits(in: NSSize(width: width, height: 100_000)).height
        let height = max(needed, contentSize.height)
        host.view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        document.frame = NSRect(x: 0, y: 0, width: width, height: height)
        // A new layout must not move the text: keep it where the scrolling has it (the top, to
        // start with), unless the pointer is in it and someone is scrolling by hand.
        if !pointerInside, contentView.bounds.origin.y != position { scroll(to: position) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { pointerInside = true }
    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        position = contentView.bounds.origin.y          // carry on from wherever it was left
        lastTick = CACurrentMediaTime()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        defer { lastTick = now }
        guard !pointerInside, window?.occlusionState.contains(.visible) == true || CreditsScrolling.testIgnoresVisibility,
              now >= holdUntil else { return }
        let end = max(0, document.frame.height - contentSize.height)
        guard end > 0 else { return }
        if position >= end {                            // held at the bottom: back to the top, and hold
            position = 0
            scroll(to: 0)
            holdUntil = now + Self.holdAtEnds
            return
        }
        position = min(end, position + CGFloat(now - lastTick) * Self.pointsPerSecond)
        scroll(to: position)
        if position >= end { holdUntil = now + Self.holdAtEnds }
    }

    private func scroll(to y: CGFloat) {
        contentView.scroll(to: NSPoint(x: 0, y: y))
        reflectScrolledClipView(contentView)
    }

    deinit { timer?.invalidate() }
}

final class FlippedView: NSView, FlippedViewMarker {
    override var isFlipped: Bool { true }
}

/// For the Grabber's `--render-about` check only, which may run with the screen locked.
public enum CreditsScrolling { public static var testIgnoresVisibility = false }

/// Lets the Grabber's `--render-about` check find the credits scroller.
public protocol FlippedViewMarker {}

/// Licences…: every licence this app carries, in full, selectable. Nothing is fetched.
@MainActor
public enum LicencesWindow {
    private static var window: NSWindow?

    public static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Licences"
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: 600, height: 320)
        w.contentView = NSHostingView(rootView: LicencesView(entries: LicenceFiles.entries(), tint: AboutWindow.tint))
        w.appearance = AboutWindow.currentAppearance()
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { LicencesWindow.window = nil }
        }
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}

public struct LicencesView: View {
    let entries: [LicenceFiles.Entry]
    let tint: Color
    @State private var selected: String?
    public init(entries: [LicenceFiles.Entry], tint: Color) { self.entries = entries; self.tint = tint }

    public var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(entries) { e in
                    let on = (selected ?? entries.first?.id) == e.id
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).font(.system(size: 12, weight: on ? .semibold : .regular))
                        Text(e.subtitle).font(.system(size: 10.5)).foregroundStyle(on ? Color.primary.opacity(0.75) : Color.mutedLabel)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(on ? tint.opacity(0.28) : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { selected = e.id }
                }
                Spacer()
            }
            .padding(8)
            .frame(width: 210)
            Divider()
            // The files keep their own line breaks (about 80 columns), so they are shown unwrapped,
            // scrolling sideways in a narrow window rather than wrapping twice.
            ScrollView([.vertical, .horizontal]) {
                Text(entries.first { $0.id == (selected ?? entries.first?.id) }?.text ?? "No licence files in this build.")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.topLeading)
        }
        .frame(minWidth: 600, minHeight: 320)
    }
}
