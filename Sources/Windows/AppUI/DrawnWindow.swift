import Foundation
import WinSDK
import NetworkAudioEngine
import Win32UI
import NAGDraw

/// One drawn window's own bookkeeping: what was drawn where, what the pointer is over, how far
/// each area is scrolled. The main window has one, and so does each dialog, so the same drawing
/// code serves all of them.
final class Surface {
    var hwnd: HWND?
    var hits: [DrawnWindow.Hit] = []
    var hoverKey: String?
    var hoverSince = Date()
    var mouse = POINT()
    var dragging: DrawnWindow.Hit?
    var tracking = false
    var scrolls: [String: DrawnWindow.ScrollArea] = [:]
    var scrollOrder: [String] = []
    var fieldFrames: [String: RECT] = [:]
    var tipVisible = false
    let paint: (Canvas, RECT) -> Void
    let minimum: () -> (Double, Double)

    init(paint: @escaping (Canvas, RECT) -> Void, minimum: @escaping () -> (Double, Double)) {
        self.paint = paint
        self.minimum = minimum
    }
}

/// A window drawn the immediate-mode way (the Grabber's first, then shared with the
/// Sender): each frame reads the app's state and draws, and records where each control was drawn
/// with what it does (`Hit`). Nothing is kept in step, because nothing is copied.
///
/// This is the part both apps share — surfaces, hits, scrolling, menus, typing, tooltips, the
/// look. Each app's window subclasses it and draws its own content.
class DrawnWindow {
    var hwnd: HWND? { main.hwnd }
    var dpi: Int = 96
    var palette: Palette

    private(set) var main: Surface!
    /// The surface being drawn or handled right now; every `hit` lands on it.
    var current: Surface!

    /// The app's own icon, for the title bar and the taskbar.
    let iconPNG: [UInt8]
    /// Which explainers are open, by title. Not remembered.
    var openExplainers: Set<String> = []

    init(palette: Palette, iconPNG: [UInt8]) {
        self.palette = palette
        self.iconPNG = iconPNG
        main = Surface(paint: { [unowned self] c, r in self.drawMain(c, r) }, minimum: { [unowned self] in self.minimumSize() })
        current = main
    }

    // MARK: - What each app's window supplies

    /// The main window's content.
    func drawMain(_ c: Canvas, _ client: RECT) {}
    /// The main window's floor, in points.
    func minimumSize() -> (Double, Double) { (400, 300) }
    /// The other surfaces this app has open: dialogs, the Connect window.
    var extraSurfaces: [Surface] { [] }
    /// The window's beat; by default the tooltips and a repaint.
    func timerTick() { tooltipsAndRepaint() }
    /// A key the window wants; true if it took it.
    func keyDown(_ key: Int32, ctrl: Bool, shift: Bool) -> Bool { false }
    /// The main window was resized (not minimised), in points.
    func mainResized(width: Double, height: Double) {}
    /// Windows changed light or dark, or the accent.
    func systemLookChanged() {}
    /// The main window is closing: stop the app's engines.
    func closingMain() {}
    /// Messages a dialog wants before they are dispatched.
    func preTranslate(_ message: inout MSG) -> Bool { false }
    /// Where the app's log goes.
    func log(_ text: String, _ kind: ActivityLog.Kind) {}

    // MARK: - What was drawn where

    struct Hit {
        var rect: RECT
        var key: String
        var click: ((POINT) -> Void)?
        var doubleClick: (() -> Void)?
        var rightClick: ((POINT) -> Void)?
        /// For a slider: called with 0…1 along `track` while dragging.
        var drag: ((Double) -> Void)?
        var track = RECT()
        var tip: String?
    }

    /// Records a control. Later ones win where they overlap, as later drawing is on top.
    /// `click` is last so a trailing closure is always the click: with it first, Swift 5's
    /// backward scan bound trailing closures to `right`, and left clicks did nothing.
    func hit(_ rect: RECT, _ key: String, tip: String? = nil, double: (() -> Void)? = nil,
             right: ((POINT) -> Void)? = nil, click: ((POINT) -> Void)? = nil) {
        current.hits.append(Hit(rect: rect, key: key, click: click, doubleClick: double, rightClick: right, tip: tip))
    }

    /// Records a slider: dragging anywhere in `rect` sets it along `track`; a double-click resets.
    func sliderHit(_ rect: RECT, track: RECT, _ key: String, tip: String? = nil,
                   set: @escaping (Double) -> Void, reset: (() -> Void)? = nil) {
        current.hits.append(Hit(rect: rect, key: key, doubleClick: reset, drag: set, track: track, tip: tip))
    }

    func isHover(_ key: String) -> Bool { current.hoverKey == key }

    var fieldFrames: [String: RECT] {
        get { current.fieldFrames }
        set { current.fieldFrames = newValue }
    }

    // MARK: - Scrolling areas

    struct ScrollArea { var offset: Int32 = 0; var viewport = RECT(); var content: Int32 = 0 }

    /// Starts a scrolling area: returns how far it is scrolled, and clips drawing to it until
    /// `endScroll` says how tall its content was.
    func beginScroll(_ key: String, _ viewport: RECT, _ c: Canvas) -> Int32 {
        var area = current.scrolls[key] ?? ScrollArea()
        area.viewport = viewport
        current.scrolls[key] = area
        current.scrollOrder.append(key)
        c.clip(viewport)
        return area.offset
    }

    func endScroll(_ key: String, content: Int32, _ c: Canvas) {
        c.unclip()
        guard var area = current.scrolls[key] else { return }
        area.content = content
        area.offset = max(0, min(area.offset, max(0, content - area.viewport.height)))
        current.scrolls[key] = area
        if content > area.viewport.height, area.viewport.height > 0 {
            let v = area.viewport
            let h = max(c.s(24), Int32(Double(v.height) * Double(v.height) / Double(content)))
            let y = v.top + Int32(Double(v.height - h) * Double(area.offset) / Double(max(1, content - v.height)))
            c.round(RECT(left: v.right - c.s(6), top: y + c.s(2), right: v.right - c.s(2), bottom: y + h - c.s(2)), 2,
                    c.p.label, alpha: 0.25)
        }
    }

    /// The current surface's scroll areas, for a log that follows its newest line.
    var scrolls: [String: ScrollArea] {
        get { current.scrolls }
        set { current.scrolls = newValue }
    }

    // MARK: - Making windows

    private static let className = "NetworkAudioDrawnWindow"
    private static var registered = false

    /// Registers the one window class every window uses; each finds its surface by its handle.
    static func registerClass() -> Bool {
        guard !registered else { return true }
        let instance = GetModuleHandleW(nil)
        var windowClass = WNDCLASSEXW()
        windowClass.cbSize = UInt32(MemoryLayout<WNDCLASSEXW>.size)
        windowClass.style = UInt32(CS_HREDRAW | CS_VREDRAW | CS_DBLCLKS)
        windowClass.lpfnWndProc = { hwnd, message, wParam, lParam in
            if let owner = DrawnWindow.shared, let surface = owner.surface(for: hwnd),
               let result = owner.handle(surface, hwnd, message, wParam, lParam) {
                return result
            }
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
        windowClass.hInstance = instance
        windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))   // IDC_ARROW
        registered = className.withCString(encodedAs: UTF16.self) { name -> Bool in
            windowClass.lpszClassName = name
            return RegisterClassExW(&windowClass) != 0
        }
        return registered
    }

    /// The app's one window object; the class's procedure reaches it through here.
    nonisolated(unsafe) static var shared: DrawnWindow?

    func surface(for hwnd: HWND?) -> Surface? {
        if hwnd == main.hwnd { return main }
        return extraSurfaces.first { $0.hwnd == hwnd }
    }

    /// Makes a top-level window for a surface.
    func makeWindow(_ surface: Surface, title: String, width: Double, height: Double, owner: HWND? = nil) -> Bool {
        guard Self.registerClass() else { return false }
        if surface === main { Self.shared = self }
        let style = DWORD(WS_OVERLAPPEDWINDOW)
        surface.hwnd = title.withCString(encodedAs: UTF16.self) { t in
            Self.className.withCString(encodedAs: UTF16.self) { name in
                CreateWindowExW(0, name, t, style, Int32(CW_USEDEFAULT), Int32(CW_USEDEFAULT), 800, 600, owner, nil,
                                GetModuleHandleW(nil), nil)
            }
        }
        guard let hwnd = surface.hwnd else { return false }
        dpi = Int(GetDpiForWindow(hwnd))
        applyTitleBar(hwnd)
        applyIcon(hwnd)
        size(hwnd, width: width, height: height)
        return true
    }

    /// The app's own icon in the title bar and the taskbar, at the sizes this dpi wants.
    func applyIcon(_ hwnd: HWND) {
        let png = iconPNG
        guard !png.isEmpty else { return }
        for (which, metric) in [(ICON_BIG, SM_CXICON), (ICON_SMALL, SM_CXSMICON)] {
            let size = GetSystemMetricsForDpi(metric, UInt32(dpi))
            if let icon = png.withUnsafeBytes({ nag_draw_icon_from_png($0.baseAddress, Int32(png.count), size) }) {
                SendMessageW(hwnd, UINT(WM_SETICON), WPARAM(which), LPARAM(Int(bitPattern: icon)))
            }
        }
    }

    func size(_ hwnd: HWND, width: Double, height: Double) {
        var frame = RECT(x: 0, y: 0, width: Int32(MulDiv(Int32(width), Int32(dpi), 96)), height: Int32(MulDiv(Int32(height), Int32(dpi), 96)))
        AdjustWindowRectExForDpi(&frame, DWORD(WS_OVERLAPPEDWINDOW), false, 0, UInt32(dpi))
        SetWindowPos(hwnd, nil, 0, 0, frame.width, frame.height, UINT(SWP_NOMOVE | SWP_NOZORDER))
    }

    func applyTitleBar(_ hwnd: HWND) {
        var dark: Int32 = palette.dark ? 1 : 0
        for attribute in [UInt32(20), UInt32(19)] {          // DWMWA_USE_IMMERSIVE_DARK_MODE
            if DwmSetWindowAttribute(hwnd, attribute, &dark, DWORD(MemoryLayout<Int32>.size)) == S_OK { break }
        }
        // The caption in the window's own ground, on Windows 11 (DWMWA_CAPTION_COLOR).
        var caption = palette.window.ref
        _ = DwmSetWindowAttribute(hwnd, 35, &caption, DWORD(MemoryLayout<COLORREF>.size))
    }

    /// Every open window's title bar, after the look changed.
    func applyTitleBars() {
        for s in [main] + extraSurfaces { if let h = s?.hwnd { applyTitleBar(h) } }
    }

    // MARK: - The beat

    /// Repaints at `hz` from now on.
    func startTimer(hz: Int) {
        guard let hwnd else { return }
        KillTimer(hwnd, 1)
        SetTimer(hwnd, 1, UINT(1000 / max(15, min(60, hz))), nil)
    }

    /// Shows a tooltip once the pointer has rested on a control, and repaints everything.
    func tooltipsAndRepaint() {
        let now = Date()
        for surface in [main!] + extraSurfaces {
            if let key = surface.hoverKey, now.timeIntervalSince(surface.hoverSince) > 0.6,
               surface.hits.contains(where: { $0.key == key && $0.tip != nil }), !surface.tipVisible {
                surface.tipVisible = true
            }
        }
        invalidateAll()
    }

    func invalidate() { if let hwnd { InvalidateRect(hwnd, nil, false) } }
    func invalidateAll() {
        invalidate()
        for s in extraSurfaces { if let h = s.hwnd, IsWindowVisible(h) { InvalidateRect(h, nil, false) } }
    }

    // MARK: - Messages

    func handle(_ s: Surface, _ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        let isMain = s === main
        switch Int32(message) {
        case WM_PAINT:
            paint(s, hwnd!)
            return 0
        case WM_ERASEBKGND:
            return 1
        case WM_TIMER:
            if isMain { timerTick() }
            return 0
        case WM_COMMAND:
            if (wParam >> 16) & 0xFFFF == 0 {
                let id = Int(wParam & 0xFFFF)
                if let action = menuActions[id] { menuActions.removeAll(); current = s; action() }
            }
            invalidateAll()
            return 0
        case WM_CTLCOLOREDIT:
            let dc = HDC(bitPattern: UInt(wParam))
            SetTextColor(dc, palette.text.ref)
            let ground = palette.dark ? palette.window.over(.black, 0.25) : Colour.white
            SetBkColor(dc, ground.ref)
            if editBrush == nil || editBrushColour != ground {
                if let editBrush { DeleteObject(editBrush) }
                editBrush = CreateSolidBrush(ground.ref)
                editBrushColour = ground
            }
            return LRESULT(Int(bitPattern: UInt(bitPattern: Int(bitPattern: editBrush))))
        case WM_MOUSEMOVE:
            let pt = point(lParam)
            s.mouse = pt
            if !s.tracking {
                var track = TRACKMOUSEEVENT(cbSize: DWORD(MemoryLayout<TRACKMOUSEEVENT>.size), dwFlags: DWORD(TME_LEAVE),
                                            hwndTrack: hwnd, dwHoverTime: 0)
                TrackMouseEvent(&track)
                s.tracking = true
            }
            if let dragging = s.dragging { current = s; drag(dragging, pt); InvalidateRect(hwnd, nil, false); return 0 }
            let under = s.hits.last { $0.rect.contains(pt) }?.key
            if under != s.hoverKey {
                s.hoverKey = under
                s.hoverSince = Date()
                s.tipVisible = false
                InvalidateRect(hwnd, nil, false)
            }
            return 0
        case WM_MOUSELEAVE:
            s.tracking = false
            if s.dragging == nil, s.hoverKey != nil { s.hoverKey = nil; s.tipVisible = false; InvalidateRect(hwnd, nil, false) }
            return 0
        case WM_SETCURSOR:
            if Int32(lParam & 0xFFFF) == HTCLIENT, let key = s.dragging?.key ?? s.hoverKey, key.hasPrefix("split-") {
                SetCursor(LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32644)))     // IDC_SIZEWE
                return 1
            }
            if Int32(lParam & 0xFFFF) == HTCLIENT, let key = s.hoverKey,
               let h = s.hits.last(where: { $0.key == key }), h.click != nil || h.drag != nil || h.doubleClick != nil {
                SetCursor(LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32649)))     // IDC_HAND
                return 1
            }
            return nil
        case WM_MOUSEWHEEL:
            let delta = Int32(Int16(truncatingIfNeeded: Int(wParam >> 16)))
            var screen = POINT(x: Int32(Int16(truncatingIfNeeded: lParam & 0xFFFF)), y: Int32(Int16(truncatingIfNeeded: (lParam >> 16) & 0xFFFF)))
            ScreenToClient(hwnd, &screen)
            scroll(s, at: screen, by: -(delta / 120) * Int32(MulDiv(60, Int32(dpi), 96)))
            InvalidateRect(hwnd, nil, false)
            return 0
        case WM_LBUTTONDOWN:
            let pt = point(lParam)
            s.tipVisible = false
            current = s
            if field != nil, !(fieldSurface === s && (fieldFrame?.contains(pt) ?? false)) { commitField() }
            if let h = s.hits.last(where: { $0.rect.contains(pt) }) {
                if h.drag != nil {
                    s.dragging = h
                    SetCapture(hwnd)
                    drag(h, pt)
                } else {
                    h.click?(pt)
                }
            }
            invalidateAll()
            return 0
        case WM_LBUTTONDBLCLK:
            let pt = point(lParam)
            current = s
            if let h = s.hits.last(where: { $0.rect.contains(pt) }) {
                if let double = h.doubleClick { double() } else if h.drag == nil { h.click?(pt) }
            }
            invalidateAll()
            return 0
        case WM_LBUTTONUP:
            if s.dragging != nil { s.dragging = nil; ReleaseCapture() }
            return 0
        case WM_RBUTTONUP:
            let pt = point(lParam)
            current = s
            if let h = s.hits.last(where: { $0.rect.contains(pt) && $0.rightClick != nil }) { h.rightClick?(pt) }
            invalidateAll()
            return 0
        case WM_KEYDOWN:
            current = s
            if keyDown(Int32(wParam), ctrl: GetKeyState(VK_CONTROL) < 0, shift: GetKeyState(VK_SHIFT) < 0) { invalidateAll(); return 0 }
            return nil
        case WM_DPICHANGED:
            dpi = Int(wParam & 0xFFFF)
            if let suggested = UnsafePointer<RECT>(bitPattern: Int(lParam))?.pointee {
                SetWindowPos(hwnd, nil, suggested.left, suggested.top, suggested.width, suggested.height, UINT(SWP_NOZORDER))
            }
            if let hwnd { applyIcon(hwnd) }
            invalidateAll()
            return 0
        case WM_SIZE:
            if isMain, wParam != WPARAM(SIZE_MINIMIZED), let hwnd {
                var client = RECT()
                GetClientRect(hwnd, &client)
                mainResized(width: Double(client.width) * 96 / Double(dpi), height: Double(client.height) * 96 / Double(dpi))
            }
            InvalidateRect(hwnd, nil, false)
            return 0
        case WM_GETMINMAXINFO:
            if let info = UnsafeMutablePointer<MINMAXINFO>(bitPattern: Int(lParam)) {
                let (w, h) = s.minimum()
                var frame = RECT(x: 0, y: 0, width: Int32(MulDiv(Int32(w), Int32(dpi), 96)), height: Int32(MulDiv(Int32(h), Int32(dpi), 96)))
                AdjustWindowRectExForDpi(&frame, DWORD(WS_OVERLAPPEDWINDOW), false, 0, UInt32(dpi))
                info.pointee.ptMinTrackSize.x = frame.width
                info.pointee.ptMinTrackSize.y = frame.height
            }
            return 0
        case WM_SETTINGCHANGE:
            if isMain { systemLookChanged() }
            return nil
        case WM_CLOSE:
            if isMain {
                commitField()
                closingMain()
                DestroyWindow(hwnd)
            } else {
                if fieldSurface === s { commitField() }
                ShowWindow(hwnd, SW_HIDE)
            }
            return 0
        case WM_DESTROY:
            if isMain { PostQuitMessage(0) }
            return 0
        default:
            return nil
        }
    }

    private var editBrush: HBRUSH?
    private var editBrushColour: Colour?

    private func point(_ lParam: LPARAM) -> POINT {
        POINT(x: Int32(Int16(truncatingIfNeeded: lParam & 0xFFFF)), y: Int32(Int16(truncatingIfNeeded: (lParam >> 16) & 0xFFFF)))
    }

    private func drag(_ h: Hit, _ pt: POINT) {
        guard h.track.width > 0 else { return }
        h.drag?(max(0, min(1, Double(pt.x - h.track.left) / Double(h.track.width))))
    }

    private func scroll(_ s: Surface, at pt: POINT, by amount: Int32) {
        // The innermost area under the pointer: the last one drawn that holds it.
        guard let key = s.scrollOrder.last(where: { s.scrolls[$0]?.viewport.contains(pt) == true }),
              var area = s.scrolls[key] else { return }
        area.offset = max(0, min(area.offset + amount, max(0, area.content - area.viewport.height)))
        s.scrolls[key] = area
        if field != nil, fieldSurface === s { commitField() }
    }

    // MARK: - Menus (Windows' own, with submenus)

    var menuActions: [Int: () -> Void] = [:]

    indirect enum MenuEntry {
        case item(String, checked: Bool = false, enabled: Bool = true, action: () -> Void)
        case separator
        case submenu(String, [MenuEntry])
        case heading(String)
    }

    /// Shows a menu at a point in the current surface's client area. Windows posts the choice as
    /// `WM_COMMAND`, which runs the entry's action.
    func popup(_ entries: [MenuEntry], at pt: POINT) {
        guard let owner = current.hwnd else { return }
        menuActions.removeAll()
        var next = 1000
        func build(_ entries: [MenuEntry]) -> HMENU? {
            guard let menu = CreatePopupMenu() else { return nil }
            for entry in entries {
                switch entry {
                case .separator:
                    AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
                case .heading(let title):
                    _ = title.withCString(encodedAs: UTF16.self) { AppendMenuW(menu, UINT(MF_STRING | MF_GRAYED), 0, $0) }
                case .item(let title, let checked, let enabled, let action):
                    let id = next
                    next += 1
                    menuActions[id] = action
                    var flags = UINT(MF_STRING)
                    if checked { flags |= UINT(MF_CHECKED) }
                    if !enabled { flags |= UINT(MF_GRAYED) }
                    _ = title.replacingOccurrences(of: "&", with: "&&").withCString(encodedAs: UTF16.self) {
                        AppendMenuW(menu, flags, UINT_PTR(id), $0)
                    }
                case .submenu(let title, let children):
                    if let sub = build(children) {
                        _ = title.replacingOccurrences(of: "&", with: "&&").withCString(encodedAs: UTF16.self) {
                            AppendMenuW(menu, UINT(MF_STRING | MF_POPUP), UINT_PTR(UInt(bitPattern: Int(bitPattern: sub))), $0)
                        }
                    }
                }
            }
            return menu
        }
        guard let menu = build(entries) else { return }
        defer { DestroyMenu(menu) }
        var screen = pt
        ClientToScreen(owner, &screen)
        SetForegroundWindow(owner)
        TrackPopupMenu(menu, UINT(TPM_LEFTALIGN | TPM_RIGHTBUTTON), screen.x, screen.y, 0, owner, nil)
    }

    // MARK: - Typing

    var field: TextField?
    var fieldKey: String?
    var fieldFrame: RECT?
    private var fieldSurface: Surface?
    private var fieldCommit: ((String) -> Void)?

    /// Opens Windows' own edit control over a drawn field, on the current surface.
    func beginField(_ key: String, frame: RECT, text: String, commit: @escaping (String) -> Void) {
        guard let parent = current.hwnd else { return }
        commitField()
        let f = TextField(parent: parent, font: Canvas.fieldFont(dpi: dpi))
        f.open(frame: frame.inset(by: Int32(MulDiv(3, Int32(dpi), 96))), text: text)
        field = f
        fieldKey = key
        fieldFrame = frame
        fieldSurface = current
        fieldCommit = commit
    }

    func commitField() {
        guard let field else { return }
        let text = field.text
        let commit = fieldCommit
        let surface = fieldSurface
        self.field = nil
        fieldKey = nil
        fieldFrame = nil
        fieldCommit = nil
        fieldSurface = nil
        field.close()
        let saved = current
        current = surface ?? main
        commit?(text)
        current = saved
        invalidateAll()
    }

    func cancelField() {
        field?.close()
        field = nil
        fieldKey = nil
        fieldFrame = nil
        fieldCommit = nil
        fieldSurface = nil
        invalidateAll()
    }

    func run() {
        var message = MSG()
        while GetMessageW(&message, nil, 0, 0) {
            if let field {
                switch field.key(for: message) {
                case .enter: commitField(); continue
                case .escape: cancelField(); continue
                case .other: break
                }
            }
            if preTranslate(&message) { continue }
            TranslateMessage(&message)
            DispatchMessageW(&message)
        }
    }

    // MARK: - Things Windows does for us

    func copyToClipboard(_ text: String) {
        guard let owner = current.hwnd ?? hwnd, OpenClipboard(owner) else { return }
        defer { CloseClipboard() }
        EmptyClipboard()
        let utf16 = Array(text.utf16) + [0]
        guard let memory = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(utf16.count * 2)),
              let locked = GlobalLock(memory) else { return }
        utf16.withUnsafeBytes { locked.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        GlobalUnlock(memory)
        SetClipboardData(UINT(CF_UNICODETEXT), memory)
    }

    /// Opens a file or folder that sits beside the app, as Explorer would.
    func open(besideApp name: String) {
        var module = [WCHAR](repeating: 0, count: 1024)
        let length = Int(GetModuleFileNameW(nil, &module, DWORD(module.count)))
        let exe = length > 0 ? String(decoding: module.prefix(length), as: UTF16.self) : CommandLine.arguments[0]
        let path = URL(fileURLWithPath: exe).deletingLastPathComponent().appendingPathComponent(name).path
        guard FileManager.default.fileExists(atPath: path) else {
            log("\(name) is not beside the app, so it could not be opened.", .warning)
            return
        }
        shellOpen(path)
    }

    func shellOpen(_ target: String) {
        _ = "open".withCString(encodedAs: UTF16.self) { verb in
            target.withCString(encodedAs: UTF16.self) { file in ShellExecuteW(hwnd, verb, file, nil, nil, SW_SHOWNORMAL) }
        }
    }

    /// Windows' colour chooser, for the scheme's two colours.
    func chooseColour(_ start: Colour) -> Colour? {
        var custom = [COLORREF](repeating: 0x00FFFFFF, count: 16)
        return custom.withUnsafeMutableBufferPointer { buffer -> Colour? in
            var choose = CHOOSECOLORW()
            choose.lStructSize = DWORD(MemoryLayout<CHOOSECOLORW>.size)
            choose.hwndOwner = current.hwnd ?? hwnd
            choose.rgbResult = start.ref
            choose.lpCustColors = buffer.baseAddress
            choose.Flags = DWORD(CC_RGBINIT | CC_FULLOPEN)
            guard ChooseColorW(&choose) else { return nil }
            let c = choose.rgbResult
            return Colour(Double(c & 0xFF) / 255, Double((c >> 8) & 0xFF) / 255, Double((c >> 16) & 0xFF) / 255)
        }
    }

    // MARK: - Drawing

    private func paint(_ s: Surface, _ hwnd: HWND) {
        var info = PAINTSTRUCT()
        guard let screen = BeginPaint(hwnd, &info) else { return }
        defer { EndPaint(hwnd, &info) }
        var client = RECT()
        GetClientRect(hwnd, &client)
        guard client.width > 0, client.height > 0,
              let memory = CreateCompatibleDC(screen),
              let bitmap = CreateCompatibleBitmap(screen, client.width, client.height) else { return }
        let previous = SelectObject(memory, bitmap)
        defer {
            BitBlt(screen, 0, 0, client.width, client.height, memory, 0, 0, DWORD(SRCCOPY))
            SelectObject(memory, previous)
            DeleteObject(bitmap)
            DeleteDC(memory)
        }
        let saved = current
        current = s
        defer { current = saved }
        let c = Canvas(dc: memory, dpi: dpi, palette: palette)
        s.hits.removeAll(keepingCapacity: true)
        s.scrollOrder.removeAll(keepingCapacity: true)
        s.fieldFrames.removeAll(keepingCapacity: true)
        c.fill(client, palette.window)
        s.paint(c, client)
        if fieldSurface === s, let key = fieldKey, let frame = s.fieldFrames[key], let field {
            fieldFrame = frame
            field.move(to: frame.inset(by: c.s(3)))
        }
        if s.tipVisible { drawTip(c, client, s) }
        c.finish()
    }

    /// The hovered control's tooltip, drawn over everything: what it does, then what it is
    /// doing now, as the Mac's tooltips say it.
    private func drawTip(_ c: Canvas, _ client: RECT, _ s: Surface) {
        guard let key = s.hoverKey, let tip = s.hits.last(where: { $0.key == key })?.tip, !tip.isEmpty else { return }
        let width = min(c.s(320), client.width - c.s(16))
        let fnt = c.font(11)
        let h = c.wrappedHeight(tip, width: width - c.s(16), fnt) + c.s(12)
        var x = s.mouse.x + c.s(12)
        var y = s.mouse.y + c.s(20)
        if x + width > client.right - c.s(4) { x = client.right - c.s(4) - width }
        if y + h > client.bottom - c.s(4) { y = s.mouse.y - h - c.s(8) }
        let box = RECT(x: max(c.s(4), x), y: max(c.s(4), y), width: width, height: h)
        let ground = palette.dark ? Colour(0.17, 0.17, 0.18) : Colour(0.98, 0.98, 0.98)
        c.round(RECT(x: box.left, y: box.top + c.s(1), width: box.width, height: box.height), 6, .black, alpha: 0.25)
        c.round(box, 6, ground, border: palette.label, borderAlpha: 0.15)
        c.wrapped(tip, RECT(left: box.left + c.s(8), top: box.top + c.s(6), right: box.right - c.s(8), bottom: box.bottom),
                  fnt, palette.text)
    }

    // MARK: - Shared pieces of drawing

    /// A section heading that folds its section: only the chevron and the title are the button.
    func drawFoldHeading(_ c: Canvas, _ r: RECT, _ title: String, open: Bool, key: String, toggle: @escaping () -> Void) {
        c.chevron(RECT(x: r.left, y: r.top, width: c.s(8), height: r.height), down: open, colour: c.p.muted, size: 8)
        let f = c.font(12, .semibold)
        let w = c.width(title, f)
        c.text(title, RECT(left: r.left + c.s(14), top: r.top, right: r.left + c.s(14) + w + 2, bottom: r.bottom), f,
               isHover(key) ? c.p.text : c.p.muted)
        hit(RECT(left: r.left - c.s(2), top: r.top, right: r.left + c.s(16) + w, bottom: r.bottom), key,
            tip: tooltip("Folds this section away, or opens it. Only the name folds it — anything beside it belongs to the section.",
                         now: open ? "Open." : "Folded.")) { _ in toggle() }
    }

    /// The app icon's mark (the Mac's `AppEmblem`): the U and its packet, in the header's muted
    /// grey at 60 % — an identifier, not a control.
    func drawEmblem(_ c: Canvas, _ r: RECT, sender: Bool = false) {
        let colour = c.p.window.over(c.p.muted, 0.6)
        let mark = Emblem.fitted(size: Double(r.width), detail: c.pt(r.width) < 20 ? 0 : 1, sender: sender)
        let ox = Double(r.left), oy = Double(r.top)
        c.polyline(mark.u.map { ($0.0 + ox, $0.1 + oy) }, colour, width: mark.width)
        for p in mark.packets {
            let rect = RECT(left: Int32((p.x + ox).rounded()), top: Int32((p.y + oy).rounded()),
                            right: Int32((p.x + p.side + ox).rounded()), bottom: Int32((p.y + p.side + oy).rounded()))
            c.round(rect, c.pt(Int32(p.side * 0.2)), colour)
        }
    }
}

/// "What it does.\n\nNow: what it is doing", the Mac's `tooltip(_:now:)`.
func tooltip(_ what: String, now: String) -> String { "\(what)\n\nNow: \(now)" }

extension Canvas {
    private static var fieldFonts: [Int: HFONT] = [:]
    /// The edit control's font, kept apart from the drawing fonts so it outlives a frame.
    static func fieldFont(dpi: Int) -> HFONT? {
        if let f = fieldFonts[dpi] { return f }
        let f = Theme.font(8, dpi: dpi)
        fieldFonts[dpi] = f
        return f
    }
}
