import AppKit

/// A window captured at its size in points, for the render harnesses and the Quick
/// Start pictures. `CGWindowListCreateImage` returns the display's own pixels, and with some
/// display arrangements that is not 1:1 — the same window came out 1234 rather than 1260 wide, and
/// every red mark in the guide drifted. Redrawn at the window's point size, a shot is the same size
/// whatever screens are attached.
public enum WindowShot {
    public static func png(of window: NSWindow) -> Data? {
        let id = CGWindowID(window.windowNumber)
        guard let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, id,
                                               [.boundsIgnoreFraming, .bestResolution]),
              cg.width > 10 else { return nil }
        let w = Int(window.frame.width.rounded()), h = Int(window.frame.height.rounded())
        guard cg.width != w || cg.height != h else {
            return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSGraphicsContext.current?.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
