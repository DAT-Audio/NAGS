// The disk image's window background, at 1× and 2×. Finder draws the icons and their names on top of it, at the
// positions in Tools/dmg_settings.py, which must agree with the layout constants below.
//
// Finder draws file names in white in dark mode and black in light mode, and a disk image cannot
// choose: this one is drawn for light mode. With Finder in dark mode the names are pale on pale.
//
//   swift Tools/make_dmg_background.swift <version> <out-dir> [--dark]   → background.png, background@2x.png
import AppKit

let version = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "?"
let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ".")
/// Light by default (one look, made for Finder in light mode,
/// rather than one that tries to suit both); `--dark` for the graphite version.
let light = !CommandLine.arguments.contains("--dark")
let W: CGFloat = 720, H: CGFloat = 470

let amber = NSColor(srgbRed: 0.94, green: 0.65, blue: 0.25, alpha: 1)
let text = NSColor(white: light ? 0.12 : 0.95, alpha: 1)
let muted = NSColor(white: light ? 0.30 : 0.78, alpha: 1)
let faint = NSColor(white: light ? 0.42 : 0.62, alpha: 1)
let lane = NSColor(white: 0.55, alpha: 0.55)

func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont { .systemFont(ofSize: size, weight: weight) }

func say(_ s: String, _ f: NSFont, _ c: NSColor, at p: NSPoint, width: CGFloat? = nil, align: NSTextAlignment = .left) {
    let para = NSMutableParagraphStyle(); para.alignment = align; para.lineSpacing = 1.5
    let a = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c, .paragraphStyle: para])
    if let width {
        a.draw(with: NSRect(x: p.x, y: p.y, width: width, height: 200), options: [.usesLineFragmentOrigin])
    } else {
        a.draw(at: p)
    }
}

func rounded(_ r: NSRect, _ radius: CGFloat, fill: NSColor, stroke: NSColor? = nil) {
    let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    fill.setFill(); path.fill()
    if let stroke { stroke.setStroke(); path.lineWidth = 1; path.stroke() }
}

func arrow(at c: NSPoint) {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: c.x - 22, y: c.y)); p.line(to: NSPoint(x: c.x + 20, y: c.y))
    p.move(to: NSPoint(x: c.x + 8, y: c.y - 12)); p.line(to: NSPoint(x: c.x + 21, y: c.y)); p.line(to: NSPoint(x: c.x + 8, y: c.y + 12))
    p.lineWidth = 3; p.lineCapStyle = .round; p.lineJoinStyle = .round
    amber.setStroke(); p.stroke()
}

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    // Top-left origin, as Finder's icon positions are given.
    ctx.cgContext.translateBy(x: 0, y: H); ctx.cgContext.scaleBy(x: 1, y: -1)
    let flipped = NSGraphicsContext(cgContext: ctx.cgContext, flipped: true)
    NSGraphicsContext.current = flipped

    // Plain graphite, the way most disk images look, with the title, a touch lighter towards the top.
    let g = light
        ? NSGradient(colors: [NSColor(srgbRed: 0.96, green: 0.95, blue: 0.94, alpha: 1),
                              NSColor(srgbRed: 0.91, green: 0.90, blue: 0.89, alpha: 1)])!
        : NSGradient(colors: [NSColor(srgbRed: 0.15, green: 0.15, blue: 0.16, alpha: 1),
                              NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)])!
    g.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

    say("Network Audio Grabber & Sender", font(19, .bold), text, at: NSPoint(x: 30, y: 24))
    say("VERSION \(version)", font(11.5, .semibold), light ? NSColor(srgbRed: 0.72, green: 0.43, blue: 0.0, alpha: 1) : amber,
        at: NSPoint(x: 31, y: 52))

    // Two groups, close together: the apps with an arrow to Applications,
    // and underneath, the optional plug-ins with theirs. Positions match Tools/dmg_settings.py.
    let panelFill = NSColor(white: light ? 0 : 1, alpha: light ? 0.035 : 0.045)
    let panelLine = NSColor(white: light ? 0 : 1, alpha: light ? 0.08 : 0.08)
    rounded(NSRect(x: 40, y: 104, width: 640, height: 138), 14, fill: panelFill, stroke: panelLine)
    say("Drag both apps to Applications", font(11.5, .semibold), muted, at: NSPoint(x: 58, y: 112))
    arrow(at: NSPoint(x: 440, y: 168))

    rounded(NSRect(x: 40, y: 250, width: 640, height: 132), 14, fill: panelFill, stroke: panelLine)
    say("Optional \u{00B7} DAW plug-ins (beta)", font(11.5, .semibold), muted, at: NSPoint(x: 58, y: 257))
    arrow(at: NSPoint(x: 220, y: 304))
    say("Drag onto Components to install them for all users; macOS asks for your password.",
        font(11, .regular), faint, at: NSPoint(x: 410, y: 284), width: 255)
    say("Simpler: open the Grabber and choose Help \u{2192} Install DAW Plug-ins.",
        font(11, .regular), faint, at: NSPoint(x: 410, y: 326), width: 255)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (scale, name) in [(CGFloat(1), "background.png"), (CGFloat(2), "background@2x.png")] {
    try! render(scale: scale).representation(using: .png, properties: [:])!
        .write(to: outDir.appendingPathComponent(name))
}
print("Wrote background.png and background@2x.png to \(outDir.path)")
