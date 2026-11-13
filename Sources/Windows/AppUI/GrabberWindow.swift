import Foundation
import WinSDK
import NetworkAudioEngine
import GrabberCore

/// The Grabber's window: **the Mac's full and compact windows**, drawn in plain
/// Win32 — the toolbar, the source sidebar, the stream list with its columns and open rows, the
/// signal panel with the inserts, the output meters and every loudness reading, the compact
/// strip, Settings with the Mac's panes, and the Connect window. The wording, the order and the
/// measurements are the Mac's (`Sources/NetworkAudioGrabber/UI`), so one quick-start covers both.
final class GrabberWindow: DrawnWindow {
    let grabber: WindowsGrabber
    let view: ViewState
    private(set) var inserts: InsertsModel!
    let send: SendState?

    // Small pieces of state the panes keep between frames.
    var senderDraft = ""
    var senderAddError: String?
    var copiedValue: String?
    /// The Send views' own state — the same views the Sender app's window shows.
    private(set) var sendUI: SendUI?

    init(grabber: WindowsGrabber, view: ViewState, testing: Bool) {
        self.grabber = grabber
        self.view = view
        let send = SendState(grabber: grabber, testing: testing)
        self.send = send
        super.init(palette: Self.palette(for: view), iconPNG: AppIcon.png128)
        inserts = InsertsModel(grabber: grabber, showMix: { [unowned view] in view.showInsertMix })
        sendUI = SendUI(sender: send.sender, window: self, appName: "Grabber", excludesOwnPlayback: true)
    }

    static func palette(for view: ViewState) -> Palette {
        Palette.make(appearance: view.appearance, themeEnabled: view.themeEnabled,
                     primaryHex: view.themePrimaryHex, secondaryHex: view.themeSecondaryHex,
                     systemDark: SystemLook.prefersDark, systemAccent: SystemLook.accent)
    }

    /// Works the palette out again after the scheme or the appearance changes.
    func restyle() {
        palette = Self.palette(for: view)
        applyTitleBars()
        invalidateAll()
    }

    override var extraSurfaces: [Surface] {
        [connect?.surface, addStreamDialog?.surface].compactMap { $0 }
    }

    func create() -> Bool {
        let (w, h) = view.windowSize(for: view.viewMode)
        applyingMode = true
        guard makeWindow(main, title: "Network Audio Grabber", width: w, height: h) else { return false }
        applyingMode = false
        ShowWindow(hwnd, SW_SHOW)
        UpdateWindow(hwnd)
        startTimer(hz: view.meterHz)
        inserts.start()
        return true
    }

    /// Sizes the window for the full or compact layout, at what it was last left at.
    private var applyingMode = false
    func applyMode() {
        guard let hwnd else { return }
        applyingMode = true
        defer { applyingMode = false }
        let (w, h) = view.windowSize(for: view.viewMode)
        size(hwnd, width: w, height: h)
        invalidate()
    }

    func switchMode(_ mode: ViewMode) {
        guard mode != view.viewMode else { return }
        commitField()
        view.viewMode = mode
        applyMode()
    }

    func meterRateChanged() { startTimer(hz: view.meterHz) }

    private var lastReadout = Date.distantPast

    override func timerTick() {
        // The engine runs on Foundation's timers and the main queue: one turn of the run loop.
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        let now = Date()
        if now.timeIntervalSince(lastReadout) >= 0.25 {
            lastReadout = now
            view.refresh(from: grabber)
            inserts.tick()
        }
        send?.leaveOwnSendOut(of: grabber)
        // The filter follows what is typed, as the Mac's does.
        if fieldKey == "filter", let field { let t = field.text; if t != grabber.searchText { grabber.searchText = t } }
        tooltipsAndRepaint()
    }

    override func keyDown(_ key: Int32, ctrl: Bool, shift: Bool) -> Bool {
        if key == VK_ESCAPE, view.showSettings { view.showSettings = false; return true }
        if ctrl, key == 0xBC { view.showSettings.toggle(); return true }                // Ctrl+,
        if ctrl, shift, key == 0x4C { grabber.resetLoudness(); return true }            // Ctrl+Shift+L
        return false
    }

    override func mainResized(width: Double, height: Double) {
        if !applyingMode { view.rememberWindowSize(view.viewMode, width, height) }
    }

    override func systemLookChanged() { restyle() }

    override func closingMain() {
        inserts.shutdown()
        send?.sender.shutdown()
        grabber.shutdown()
    }

    override func preTranslate(_ message: inout MSG) -> Bool {
        addStreamDialog?.preTranslate(&message) ?? false
    }

    override func log(_ text: String, _ kind: ActivityLog.Kind) { grabber.append(log: text, kind) }

    /// The floor for the layout in use: the Mac's, a little narrower where Windows' type is.
    override func minimumSize() -> (Double, Double) {
        switch view.viewMode {
        case .full:
            let w = 760.0 + (view.showPanel ? ViewState.panelRange.lowerBound + 1 : 0)
                + (view.showSourceBar && !view.showSettings && !view.sourceFilterRow ? ViewState.sidebarRange.lowerBound + 1 : 0)
            return (w, 560)
        case .compact:
            return (330, 360)
        }
    }

    override func drawMain(_ c: Canvas, _ client: RECT) {
        switch view.viewMode {
        case .full: drawFull(c, client)
        case .compact: drawCompact(c, client)
        }
    }

    // MARK: - The other windows

    var connect: ConnectWindow?
    var addStreamDialog: AddStreamDialog?

    func openConnect(tab: Int) {
        if connect == nil { connect = ConnectWindow(owner: self) }
        connect?.show(tab: tab)
    }

    func openAddStream() {
        if addStreamDialog == nil { addStreamDialog = AddStreamDialog(owner: self) }
        addStreamDialog?.show()
    }
}
