import Foundation
import WinSDK

/// A place to type, over the drawn window.
///
/// A real Windows `EDIT` control rather than something drawn here: it brings the caret, selection,
/// the clipboard, undo, right-to-left text and the IME with it, none of which is worth rewriting
/// and all of which someone will expect. It is made when a field is needed and destroyed when it
/// is not, so the window has at most one at a time and nothing to keep in step.
public final class TextField {
    public private(set) var hwnd: HWND?
    private let parent: HWND
    private let font: HFONT?

    public init(parent: HWND, font: HFONT?) {
        self.parent = parent
        self.font = font
    }

    deinit { close() }

    public var isOpen: Bool { hwnd != nil }

    /// Opens a field at `frame` (client coordinates) holding `text`, with it all selected so
    /// typing replaces it — which is what someone renaming a stream almost always wants.
    public func open(frame: RECT, text: String, selectAll: Bool = true) {
        close()
        let style = DWORD(WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL | ES_LEFT)
        hwnd = "EDIT".withCString(encodedAs: UTF16.self) { className in
            text.withCString(encodedAs: UTF16.self) { initial in
                CreateWindowExW(0, className, initial, style,
                                frame.left, frame.top, frame.width, frame.height,
                                parent, nil, GetModuleHandleW(nil), nil)
            }
        }
        guard let hwnd else { return }
        if let font {
            SendMessageW(hwnd, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: Int(bitPattern: font))), 1)
        }
        SetFocus(hwnd)
        if selectAll { SendMessageW(hwnd, UINT(EM_SETSEL), 0, -1) }
    }

    /// Moves it, for when the window is resized while a field is open.
    public func move(to frame: RECT) {
        guard let hwnd else { return }
        SetWindowPos(hwnd, nil, frame.left, frame.top, frame.width, frame.height,
                     UINT(SWP_NOZORDER))
    }

    public var text: String {
        guard let hwnd else { return "" }
        let length = Int(GetWindowTextLengthW(hwnd))
        guard length > 0 else { return "" }
        var buffer = [WCHAR](repeating: 0, count: length + 1)
        GetWindowTextW(hwnd, &buffer, Int32(length + 1))
        return String(decodingCString: buffer, as: UTF16.self)
    }

    public func close() {
        if let hwnd { DestroyWindow(hwnd) }
        hwnd = nil
        SetFocus(parent)
    }

    /// Whether a message is this field's own key press. The window's message loop asks before
    /// dispatching, so Enter and Escape mean "done" and "never mind" rather than a system beep —
    /// an `EDIT` on its own does nothing with either.
    public enum Key { case enter, escape, other }

    public func key(for message: MSG) -> Key {
        guard let hwnd, message.hwnd == hwnd, message.message == UINT(WM_KEYDOWN) else { return .other }
        switch Int32(message.wParam) {
        case VK_RETURN: return .enter
        case VK_ESCAPE: return .escape
        default: return .other
        }
    }
}
