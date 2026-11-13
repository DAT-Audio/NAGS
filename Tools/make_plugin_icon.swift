// The DAT Audio plug-ins' icon: the Grabber's icon with a plug badge, used by the
// Grabber's Help → Install DAW Plug-ins dialogs. (Finder shows any plug-in bundle as a blank page
// whatever icon it names, and giving it a custom one would mean adding a file inside the signed
// bundle, which breaks its signature, so Finder keeps the blank page.) Drawn here, not from a
// symbol font: SF Symbols may not be used in icons.
//
//   swift Tools/make_plugin_icon.swift      → Resources/DATAudioPlugins.icns
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")
guard let base = NSImage(contentsOf: root.appendingPathComponent("NetworkAudioGrabber.icns")) else {
    fatalError("Resources/NetworkAudioGrabber.icns not found")
}
let amber = NSColor(srgbRed: 0.94, green: 0.65, blue: 0.25, alpha: 1)
let ink = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)

func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let s = CGFloat(px)
    base.draw(in: NSRect(x: 0, y: 0, width: s, height: s))

    // Badge: an amber disc, bottom right, with a dark ring so it separates from the icon.
    let d = s * 0.44
    let disc = NSRect(x: s - d - s * 0.03, y: s * 0.03, width: d, height: d)
    ink.setFill(); NSBezierPath(ovalIn: disc.insetBy(dx: -s * 0.012, dy: -s * 0.012)).fill()
    amber.setFill(); NSBezierPath(ovalIn: disc).fill()

    // The plug: two prongs up, a rounded body, a cable down.
    let cx = disc.midX, u = d / 10
    ink.setFill()
    for dx in [-1.4 * u, 1.4 * u] {
        NSBezierPath(roundedRect: NSRect(x: cx + dx - 0.45 * u, y: disc.minY + 5.9 * u, width: 0.9 * u, height: 2.0 * u),
                     xRadius: 0.3 * u, yRadius: 0.3 * u).fill()
    }
    NSBezierPath(roundedRect: NSRect(x: cx - 2.6 * u, y: disc.minY + 3.6 * u, width: 5.2 * u, height: 2.6 * u),
                 xRadius: 0.8 * u, yRadius: 0.8 * u).fill()
    let neck = NSBezierPath()
    neck.move(to: NSPoint(x: cx - 1.3 * u, y: disc.minY + 3.7 * u))
    neck.line(to: NSPoint(x: cx + 1.3 * u, y: disc.minY + 3.7 * u))
    neck.line(to: NSPoint(x: cx + 0.6 * u, y: disc.minY + 2.6 * u))
    neck.line(to: NSPoint(x: cx - 0.6 * u, y: disc.minY + 2.6 * u))
    neck.close(); neck.fill()
    NSBezierPath(rect: NSRect(x: cx - 0.35 * u, y: disc.minY + 1.0 * u, width: 0.7 * u, height: 1.7 * u)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let set = FileManager.default.temporaryDirectory.appendingPathComponent("DATAudioPlugins.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        try! draw(pt * scale).representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
let out = root.appendingPathComponent("DATAudioPlugins.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.path]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
