// windows.h's min and max macros would break std::min; GDI+'s headers then want plain min and
// max, which <algorithm> gives them.
#define NOMINMAX
#include <algorithm>
using std::min;
using std::max;
#include <windows.h>
#include "NAGDraw.h"
#include <objidl.h>
#include <gdiplus.h>
#include <shlwapi.h>

// GDI+'s C++ wrapper, inside this file only.
using namespace Gdiplus;

struct NAGDraw { Graphics *g; };

static ULONG_PTR token = 0;

extern "C" int nag_draw_startup(void) {
    if (token) return 0;
    GdiplusStartupInput input;
    return GdiplusStartup(&token, &input, nullptr) == Ok ? 0 : -1;
}

extern "C" NAGDrawRef nag_draw_begin(void *dc) {
    if (!token && nag_draw_startup() != 0) return nullptr;
    auto *d = new NAGDraw;
    d->g = new Graphics((HDC)dc);
    d->g->SetSmoothingMode(SmoothingModeAntiAlias);
    d->g->SetPixelOffsetMode(PixelOffsetModeHalf);
    return d;
}

extern "C" void nag_draw_end(NAGDrawRef d) {
    if (!d) return;
    delete d->g;
    delete d;
}

static void roundedPath(GraphicsPath &path, float x, float y, float w, float h, float r) {
    r = std::max(0.0f, std::min(r, std::min(w, h) / 2));
    if (r <= 0.01f) { path.AddRectangle(RectF(x, y, w, h)); return; }
    float d = r * 2;
    path.AddArc(x, y, d, d, 180, 90);
    path.AddArc(x + w - d, y, d, d, 270, 90);
    path.AddArc(x + w - d, y + h - d, d, d, 0, 90);
    path.AddArc(x, y + h - d, d, d, 90, 90);
    path.CloseFigure();
}

extern "C" void nag_draw_round_rect(NAGDrawRef d, float x, float y, float w, float h, float radius,
                                    unsigned int fill, unsigned int stroke, float strokeWidth) {
    if (!d || w <= 0 || h <= 0) return;
    GraphicsPath path;
    roundedPath(path, x, y, w, h, radius);
    if (fill >> 24) { SolidBrush b{Color(fill)}; d->g->FillPath(&b, &path); }
    if ((stroke >> 24) && strokeWidth > 0) { Pen p(Color(stroke), strokeWidth); d->g->DrawPath(&p, &path); }
}

extern "C" void nag_draw_gradient_round_rect(NAGDrawRef d, float x, float y, float w, float h, float radius,
                                             unsigned int top, unsigned int bottom, unsigned int stroke, float strokeWidth) {
    if (!d || w <= 0 || h <= 0) return;
    GraphicsPath path;
    roundedPath(path, x, y, w, h, radius);
    LinearGradientBrush b(PointF(x, y - 0.5f), PointF(x, y + h + 0.5f), Color(top), Color(bottom));
    d->g->FillPath(&b, &path);
    if ((stroke >> 24) && strokeWidth > 0) { Pen p(Color(stroke), strokeWidth); d->g->DrawPath(&p, &path); }
}

extern "C" void nag_draw_ellipse(NAGDrawRef d, float x, float y, float w, float h,
                                 unsigned int fill, unsigned int stroke, float strokeWidth) {
    if (!d) return;
    if (fill >> 24) { SolidBrush b{Color(fill)}; d->g->FillEllipse(&b, x, y, w, h); }
    if ((stroke >> 24) && strokeWidth > 0) { Pen p(Color(stroke), strokeWidth); d->g->DrawEllipse(&p, x, y, w, h); }
}

extern "C" void nag_draw_polygon(NAGDrawRef d, const float *xy, int points, unsigned int fill) {
    if (!d || points < 3) return;
    PointF pts[16];
    int n = std::min(points, 16);
    for (int i = 0; i < n; i++) pts[i] = PointF(xy[i * 2], xy[i * 2 + 1]);
    SolidBrush b{Color(fill)};
    d->g->FillPolygon(&b, pts, n);
}

extern "C" void nag_draw_line(NAGDrawRef d, float x0, float y0, float x1, float y1, unsigned int colour, float width) {
    if (!d) return;
    Pen p(Color(colour), width);
    d->g->DrawLine(&p, x0, y0, x1, y1);
}

extern "C" void nag_draw_arc(NAGDrawRef d, float x, float y, float w, float h, float start, float sweep,
                             unsigned int colour, float width) {
    if (!d) return;
    Pen p(Color(colour), width);
    p.SetStartCap(LineCapRound);
    p.SetEndCap(LineCapRound);
    d->g->DrawArc(&p, x, y, w, h, start, sweep);
}

extern "C" void nag_draw_clip(NAGDrawRef d, float x, float y, float w, float h) {
    if (!d) return;
    if (w <= 0 || h <= 0) d->g->ResetClip();
    else d->g->SetClip(RectF(x, y, w, h));
}

extern "C" void *nag_draw_icon_from_png(const void *png, int length, int size) {
    if (!token && nag_draw_startup() != 0) return nullptr;
    IStream *stream = SHCreateMemStream((const BYTE *)png, (UINT)length);
    if (!stream) return nullptr;
    Bitmap *source = Bitmap::FromStream(stream);
    stream->Release();
    if (!source || source->GetLastStatus() != Ok) { delete source; return nullptr; }
    Bitmap scaled(size, size, PixelFormat32bppARGB);
    {
        Graphics g(&scaled);
        g.SetInterpolationMode(InterpolationModeHighQualityBicubic);
        g.SetPixelOffsetMode(PixelOffsetModeHighQuality);
        g.DrawImage(source, 0, 0, size, size);
    }
    delete source;
    HICON icon = nullptr;
    if (scaled.GetHICON(&icon) != Ok) return nullptr;
    return icon;
}

extern "C" void nag_draw_polyline(NAGDrawRef d, const float *xy, int points, unsigned int colour, float width) {
    if (!d || points < 2) return;
    PointF pts[128];
    int n = std::min(points, 128);
    for (int i = 0; i < n; i++) pts[i] = PointF(xy[i * 2], xy[i * 2 + 1]);
    Pen p(Color(colour), width);
    p.SetLineJoin(LineJoinRound);
    p.SetStartCap(LineCapFlat);
    p.SetEndCap(LineCapFlat);
    d->g->DrawLines(&p, pts, n);
}
