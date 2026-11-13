// Antialiased shapes for the Windows windows: GDI+, which
// ships with Windows, behind plain C so Swift can call it. GDI keeps the text (ClearType); this
// draws what GDI draws jagged — circles, rounded rectangles, the play triangle, fader caps.
#pragma once
// No windows.h here: Swift imports this header as a module, and the device context is passed as
// a plain pointer.

#ifdef __cplusplus
extern "C" {
#endif

typedef struct NAGDraw *NAGDrawRef;

/// Once per process, before anything else here.
int nag_draw_startup(void);

/// A drawing session over a device context, ended before the context is copied to the screen.
NAGDrawRef nag_draw_begin(void *dc);
void nag_draw_end(NAGDrawRef d);

/// Colours are 0xAARRGGBB. Coordinates are pixels, as floats, so half-pixel edges land right.
void nag_draw_round_rect(NAGDrawRef d, float x, float y, float w, float h, float radius,
                         unsigned int fill, unsigned int stroke, float strokeWidth);
void nag_draw_gradient_round_rect(NAGDrawRef d, float x, float y, float w, float h, float radius,
                                  unsigned int top, unsigned int bottom, unsigned int stroke, float strokeWidth);
void nag_draw_ellipse(NAGDrawRef d, float x, float y, float w, float h,
                      unsigned int fill, unsigned int stroke, float strokeWidth);
void nag_draw_polygon(NAGDrawRef d, const float *xy, int points, unsigned int fill);
void nag_draw_line(NAGDrawRef d, float x0, float y0, float x1, float y1, unsigned int colour, float width);
void nag_draw_arc(NAGDrawRef d, float x, float y, float w, float h, float start, float sweep,
                  unsigned int colour, float width);
/// An icon (an HICON, as a pointer) of `size` pixels from PNG bytes, scaled smoothly; NULL on
/// failure. The caller destroys it with DestroyIcon.
void *nag_draw_icon_from_png(const void *png, int length, int size);

/// A thick polyline with round joins and flat ends: the emblem's U.
void nag_draw_polyline(NAGDrawRef d, const float *xy, int points, unsigned int colour, float width);

/// Clips the session to a rectangle until the next call (a zero-size one clears it).
void nag_draw_clip(NAGDrawRef d, float x, float y, float w, float h);

#ifdef __cplusplus
}
#endif
