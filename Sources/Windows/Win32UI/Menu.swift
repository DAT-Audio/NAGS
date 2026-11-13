import Foundation
import WinSDK

/// A pop-up menu: the row's **⋯** and the header's network chooser.
///
/// Windows' own menu, not one drawn here. It arrives where Windows puts menus, closes how people
/// expect, works from the keyboard, and follows whatever the user has set for menu animation and
/// contrast. A menu is the one place where looking exactly like the rest of the system is the
/// point.
public struct Menu {
    public struct Item {
        public let title: String
        public let id: Int
        public var checked = false
        public var enabled = true
        public static let separator = Item(title: "", id: -1)
        public init(title: String, id: Int, checked: Bool = false, enabled: Bool = true) {
            self.title = title; self.id = id; self.checked = checked; self.enabled = enabled
        }
    }

    /// Shows the menu at a point in `window`'s client area. It blocks until the menu closes, and
    /// the choice arrives as a `WM_COMMAND` carrying the item's id — not as a return value.
    ///
    /// `TPM_RETURNCMD` would be the tidier way round, but `TrackPopupMenu` is declared as
    /// returning `BOOL`, so Swift hands back a `Bool` and the id with it. The caller remembers
    /// which menu it opened and reads the id in `WM_COMMAND`, which is how Win32 menus worked
    /// before `TPM_RETURNCMD` existed anyway.
    public static func show(_ items: [Item], in window: HWND, at point: POINT) {
        guard let menu = CreatePopupMenu() else { return }
        defer { DestroyMenu(menu) }
        for item in items {
            if item.id == -1 {
                AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
                continue
            }
            var flags = UINT(MF_STRING)
            if item.checked { flags |= UINT(MF_CHECKED) }
            if !item.enabled { flags |= UINT(MF_GRAYED) }
            _ = item.title.withCString(encodedAs: UTF16.self) {
                AppendMenuW(menu, flags, UINT_PTR(item.id), $0)
            }
        }
        var screen = point
        ClientToScreen(window, &screen)
        // The window must be foremost or the menu will not close when clicked away from.
        SetForegroundWindow(window)
        TrackPopupMenu(menu, UINT(TPM_RIGHTBUTTON | TPM_LEFTALIGN),
                       screen.x, screen.y, 0, window, nil)
    }
}
