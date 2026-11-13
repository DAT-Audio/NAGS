// A plug-in's editor in its own top-level Win32 window (NAGVST3.h).

#include "NAGVST3PluginImpl.h"

#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/gui/iplugviewcontentscalesupport.h"

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace nagvst3 {

/// The window and the `IPlugFrame` the view resizes itself through. Owned by the plug-in
/// instance while open; the view may hold a reference of its own, hence the count.
class Editor final : public IPlugFrame {
public:
    NAGVST3Plugin* owner = nullptr;
    HWND window = nullptr;
    IPtr<IPlugView> view;
    nag_vst3_editor_closed onClosed = nullptr;
    void* context = nullptr;
    DWORD style = 0, exStyle = 0;
    bool canResize = false;
    /// Set while we resize the window for the view, so the WM_SIZE that causes is not passed
    /// back to it as a resize of its own.
    bool resizingForView = false;
    bool closing = false;

    tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override {
        if (FUnknownPrivate::iidEqual(iid, IPlugFrame::iid) || FUnknownPrivate::iidEqual(iid, FUnknown::iid)) {
            addRef();
            *obj = static_cast<IPlugFrame*>(this);
            return kResultOk;
        }
        *obj = nullptr;
        return kNoInterface;
    }
    NAG_VST3_REFCOUNT

    /// The window's outer size for a client area of `w` × `h`.
    SIZE outerSize(int w, int h) const {
        RECT r {0, 0, w, h};
        AdjustWindowRectEx(&r, style, FALSE, exStyle);
        return {r.right - r.left, r.bottom - r.top};
    }

    /// The view asks for a new size: the window follows, then the view is told (VST3's order).
    tresult PLUGIN_API resizeView(IPlugView* v, ViewRect* size) override {
        if (!size || !window || v != view.get()) return kInvalidArgument;
        RECT client {};
        GetClientRect(window, &client);
        if (client.right != size->getWidth() || client.bottom != size->getHeight()) {
            SIZE outer = outerSize(size->getWidth(), size->getHeight());
            resizingForView = true;
            SetWindowPos(window, nullptr, 0, 0, outer.cx, outer.cy, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
            resizingForView = false;
        }
        view->onSize(size);
        return kResultTrue;
    }

    /// Forwards the processor's output parameters (meters, gain reduction) to the controller.
    void drainOutputs() {
        if (!owner || owner->failed.load() || !owner->controller) return;
        owner->outputs.drain([this](const ParamRing::Item& item) {
            owner->controller->setParamNormalized(item.id, item.value);
        });
    }

    void close() {
        if (closing) return;
        closing = true;
        if (window) KillTimer(window, 1);
        if (view) {
            if (!owner || !owner->failed.load()) {
                view->setFrame(nullptr);
                view->removed();
                view = nullptr;
            } else {
                view.take();    // a failed plug-in is not called again
            }
        }
        HWND w = window;
        window = nullptr;
        if (w) {
            SetWindowLongPtrW(w, GWLP_USERDATA, 0);
            DestroyWindow(w);
        }
        if (owner) owner->editor = nullptr;
        if (onClosed) onClosed(context);
        release();
    }

    static LRESULT CALLBACK windowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
        auto editor = reinterpret_cast<Editor*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
        if (!editor) return DefWindowProcW(hwnd, message, wParam, lParam);
        switch (message) {
        case WM_CLOSE:
            editor->close();
            return 0;
        case WM_TIMER:
            editor->drainOutputs();
            return 0;
        case WM_SIZING:
            // The user drags the frame: the plug-in may only take some sizes.
            if (editor->canResize && editor->view) {
                auto r = reinterpret_cast<RECT*>(lParam);
                SIZE border = editor->outerSize(0, 0);
                ViewRect proposed(0, 0, (r->right - r->left) - border.cx, (r->bottom - r->top) - border.cy);
                if (editor->view->checkSizeConstraint(&proposed) == kResultTrue) {
                    SIZE outer = editor->outerSize(proposed.getWidth(), proposed.getHeight());
                    if (wParam == WMSZ_LEFT || wParam == WMSZ_TOPLEFT || wParam == WMSZ_BOTTOMLEFT)
                        r->left = r->right - outer.cx;
                    else
                        r->right = r->left + outer.cx;
                    if (wParam == WMSZ_TOP || wParam == WMSZ_TOPLEFT || wParam == WMSZ_TOPRIGHT)
                        r->top = r->bottom - outer.cy;
                    else
                        r->bottom = r->top + outer.cy;
                }
                return TRUE;
            }
            break;
        case WM_SIZE:
            if (editor->canResize && editor->view && !editor->resizingForView && wParam != SIZE_MINIMIZED) {
                ViewRect size(0, 0, LOWORD(lParam), HIWORD(lParam));
                editor->view->onSize(&size);
            }
            return 0;
        case WM_DPICHANGED:
            if (editor->view) {
                if (auto scale = U::cast<IPlugViewContentScaleSupport>(editor->view.get()))
                    scale->setContentScaleFactor(HIWORD(wParam) / 96.f);
            }
            break;
        default:
            break;
        }
        return DefWindowProcW(hwnd, message, wParam, lParam);
    }
};

const wchar_t* windowClass() {
    static const wchar_t* name = L"NAGVST3Editor";
    static bool registered = false;
    if (!registered) {
        WNDCLASSEXW wc {sizeof(wc)};
        wc.lpfnWndProc = Editor::windowProc;
        wc.hInstance = GetModuleHandleW(nullptr);
        wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
        wc.lpszClassName = name;
        registered = RegisterClassExW(&wc) != 0 || GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
    }
    return name;
}

void closeEditor(NAGVST3Plugin* plugin) {
    if (plugin && plugin->editor) plugin->editor->close();
}

} // namespace nagvst3

using namespace nagvst3;

extern "C" int nag_vst3_has_editor(NAGVST3Plugin* p) {
    if (!p || p->failed.load() || !p->controller) return 0;
    IPtr<IPlugView> view = owned(p->controller->createView(ViewType::kEditor));
    return view && view->isPlatformTypeSupported(kPlatformTypeHWND) == kResultTrue ? 1 : 0;
}

extern "C" int nag_vst3_open_editor(NAGVST3Plugin* p, void* parentHWND, const char* titleUtf8,
                                    nag_vst3_editor_closed onClosed, void* context) {
    if (!p || p->failed.load() || !p->controller) return -1;
    if (p->editor) {
        ShowWindow(p->editor->window, SW_SHOWNORMAL);
        SetForegroundWindow(p->editor->window);
        return 0;
    }
    IPtr<IPlugView> view = owned(p->controller->createView(ViewType::kEditor));
    if (!view) return -2;
    if (view->isPlatformTypeSupported(kPlatformTypeHWND) != kResultTrue) return -3;

    auto editor = new Editor();
    editor->owner = p;
    editor->view = view;
    editor->onClosed = onClosed;
    editor->context = context;
    editor->canResize = view->canResize() == kResultTrue;
    editor->style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_CLIPCHILDREN;
    if (editor->canResize) editor->style |= WS_THICKFRAME | WS_MAXIMIZEBOX;

    // Windows sizes are physical pixels; a plug-in told the scale draws to match.
    HWND parent = (HWND)parentHWND;
    UINT dpi = parent ? GetDpiForWindow(parent) : GetDpiForSystem();
    if (auto scale = U::cast<IPlugViewContentScaleSupport>(view.get()))
        scale->setContentScaleFactor(dpi / 96.f);
    ViewRect size {};
    if (view->getSize(&size) != kResultTrue || size.getWidth() <= 0 || size.getHeight() <= 0)
        size = ViewRect(0, 0, 640, 400);
    SIZE outer = editor->outerSize(size.getWidth(), size.getHeight());

    std::wstring title = wide(titleUtf8 ? titleUtf8 : p->name);
    HWND window = CreateWindowExW(editor->exStyle, windowClass(), title.c_str(), editor->style,
                                  CW_USEDEFAULT, CW_USEDEFAULT, outer.cx, outer.cy, parent, nullptr,
                                  GetModuleHandleW(nullptr), nullptr);
    if (!window) {
        editor->view = nullptr;
        editor->release();
        return -4;
    }
    editor->window = window;
    SetWindowLongPtrW(window, GWLP_USERDATA, (LONG_PTR)editor);
    p->editor = editor;

    view->setFrame(editor);
    if (view->attached(window, kPlatformTypeHWND) != kResultOk) {
        editor->onClosed = nullptr;     // never opened, so nothing to report closing
        view->setFrame(nullptr);
        editor->view = nullptr;
        editor->close();
        return -5;
    }
    // Some editors settle their size only once attached.
    ViewRect settled {};
    if (view->getSize(&settled) == kResultTrue && (settled.getWidth() != size.getWidth() || settled.getHeight() != size.getHeight())) {
        SIZE o = editor->outerSize(settled.getWidth(), settled.getHeight());
        editor->resizingForView = true;
        SetWindowPos(window, nullptr, 0, 0, o.cx, o.cy, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
        editor->resizingForView = false;
    }
    ShowWindow(window, SW_SHOWNORMAL);
    UpdateWindow(window);
    SetTimer(window, 1, 33, nullptr);
    return 0;
}

extern "C" void nag_vst3_close_editor(NAGVST3Plugin* p) { closeEditor(p); }

extern "C" void* nag_vst3_editor_window(NAGVST3Plugin* p) { return p && p->editor ? p->editor->window : nullptr; }
