#!/usr/bin/env swift
//
// Draws the app icon and packs it into an .icns.
//
//   swift Tools/make_icon.swift Resources            the Grabber's
//   swift Tools/make_icon.swift Resources sender     the Sender's
//   swift Tools/make_icon.swift <dir> layers         writes <dir>/layers.txt for Icon Composer
//
// **The pair.** Both icons are made of the same two
// elements: a thick **U** (a pot) and a straight **file of three packets**, small to large. Only
// their arrangement differs, and both read left to right:
//
//   * **Grabber:** the U opens up and to the left, and the packets come in from the top left,
//     shrinking as they drop into it.
//   * **Sender:** the same U turned so its back faces the top right, and the packets leave that
//     way, growing as they go.
//
// Where the design came from, because each step fixed a specific failure:
//
//   * **Bars and arcs dropped.** Soundly's icon is symmetric pill bars on black, which
//     sits too close to the old level-meter bars. Arcs are also on the volume, Wi-Fi and Spotify
//     marks. So: objects instead of audio clichés.
//   * **Funnel and horn** was the first pick: one shape, upright to catch and tipped
//     to send. An upright funnel is also the standard "filter" icon, and the round pot that
//     replaced it won on being an object nobody else uses.
//   * **Straight packet files.** A tumbling cluster over a U looked like a face with two
//     eyes; one file of packets does not, and the same file in both icons keeps them a pair.
//   * **Angled and mirrored.** Turning both groups onto the diagonal gives the pair
//     some movement; mirroring the Grabber makes both flow left to right.
//   * **Heavier, flat-cut.** At the first weight the marks were the lightest in a
//     mock Dock, so the U is 30 % thicker and the marks about 6 % larger. The U's ends are cut
//     square to the stroke, not rounded, which reads sharper at small sizes.
//
// Colour is a second cue, never the only one, and follows the apps' default Graphite & Amber
// scheme (option A): bone on graphite for the Grabber, graphite on warm cream for
// the Sender (7.1:1 apart in lightness, so the difference survives greyscale, colour blindness
// and macOS 26's tinted modes), and amber packets — the theme's amber on graphite (4.7:1),
// deepened to a burnt amber on cream (3.7:1), since the bright one all but disappears on a light
// plate. Earlier versions used indigo for the Grabber and coral for the packets.
//
// Small sizes: at 32 px there are two packets and at 16 px one, larger, with a heavier U. The
// packets are square to the canvas in every size, so at 32 and 16 px they are snapped to whole
// pixels and drawn with hard corners.

import AppKit
import Foundation

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
let sender = mode == "sender"
let product = sender ? "NetworkAudioSender" : "NetworkAudioGrabber"
let iconsetDir = "\(outDir)/\(product).iconset"

// MARK: - Palette

typealias RGB = (r: CGFloat, g: CGFloat, b: CGFloat)
func cg(_ c: RGB, _ a: CGFloat = 1) -> CGColor { CGColor(red: c.r, green: c.g, blue: c.b, alpha: a) }
func hex(_ c: RGB) -> String { String(format: "#%02X%02X%02X", Int(round(c.r * 255)), Int(round(c.g * 255)), Int(round(c.b * 255))) }

/// Plate gradients, top to bottom.
let grabberPlate: (RGB, RGB) = ((0.30, 0.30, 0.32), (0.20, 0.20, 0.22))   // graphite
let senderPlate: (RGB, RGB) = ((0.92, 0.88, 0.79), (0.85, 0.81, 0.71))    // warm cream
let grabberMark: RGB = (0.93, 0.92, 0.89)                                  // bone
let senderMark: RGB = (0.17, 0.17, 0.19)                                   // graphite, darkened
let grabberPackets: RGB = (0.94, 0.63, 0.16)                               // the theme's amber, #F0A028
let senderPackets: RGB = (0.62, 0.36, 0.02)                                // amber, deepened for cream

// MARK: - Geometry
//
// Drawn in a local frame with the U's mouth facing up and centred on x = 0, then turned into
// place, scaled by one factor shared by both icons (so the two U's are the same size), and
// centred on the unit canvas.

/// 2 = 48 px and up, 1 = the 32 px master, 0 = the 16 px master.
func detail(_ s: CGFloat) -> Int { s <= 20 ? 0 : (s <= 40 ? 1 : 2) }

struct Packet { var centre: CGPoint; var side: CGFloat }
struct Mark { var u: CGPath; var packets: [Packet] }

func about(_ c: CGPoint, deg: CGFloat) -> CGAffineTransform {
    CGAffineTransform(translationX: c.x, y: c.y).rotated(by: deg * .pi / 180).translatedBy(x: -c.x, y: -c.y)
}
func apply(_ m: Mark, _ t: CGAffineTransform, u ut: CGAffineTransform? = nil) -> Mark {
    var tu = ut ?? t
    return Mark(u: m.u.copy(using: &tu)!,
                packets: m.packets.map { Packet(centre: $0.centre.applying(t), side: $0.side * sqrt(abs(t.a * t.d - t.b * t.c))) })
}

/// The U and its packet file, mouth up.
func localMark(_ d: Int) -> Mark {
    let lw = 0.085 * 1.3 * [1.35, 1.15, 1.0][d]
    let u = CGMutablePath()
    u.move(to: CGPoint(x: -0.26, y: 0.02))
    u.addLine(to: CGPoint(x: -0.26, y: -0.06))
    u.addArc(center: CGPoint(x: 0, y: -0.06), radius: 0.26, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
    u.addLine(to: CGPoint(x: 0.26, y: 0.02))
    let stroke = u.copy(strokingWithWidth: lw, lineCap: .butt, lineJoin: .round, miterLimit: 10)
    let top = 0.02 + lw / 2 + 0.02
    // (distance past the mouth, side), nearest first.
    let file: [(CGFloat, CGFloat)] = [
        [(0.10, 0.15)],                  // 16 px: one, kept clear of the plate's corner
        [(0.085, 0.085), (0.27, 0.115)], // 32 px: two, with a full pixel between them
        [(0.075, 0.055), (0.165, 0.072), (0.28, 0.09)],
    ][d]
    return Mark(u: stroke, packets: file.map { Packet(centre: CGPoint(x: 0, y: top + $0.0), side: $0.1) })
}

func arranged(_ d: Int, sender: Bool) -> Mark {
    let m = localMark(d)
    if !sender {
        // Turned 45° clockwise, then mirrored left-right.
        return apply(m, about(.zero, deg: -45).concatenating(CGAffineTransform(scaleX: -1, y: 1)))
    }
    // The Grabber's own arrangement turned 90° anticlockwise, the U alone flipped 180° about its
    // centre, then the whole group turned 135° clockwise: the U's back faces the packets.
    let q = about(.zero, deg: 90)
    let uq = m.u.boundingBoxOfPath.applying(q)
    let flip = q.concatenating(about(CGPoint(x: uq.midX, y: uq.midY), deg: 180))
    let turn = about(.zero, deg: -135)
    return apply(m, q.concatenating(turn), u: flip.concatenating(turn))
}

func bounds(_ m: Mark) -> CGRect {
    m.packets.reduce(m.u.boundingBoxOfPath) {
        $0.union(CGRect(x: $1.centre.x - $1.side / 2, y: $1.centre.y - $1.side / 2, width: $1.side, height: $1.side))
    }
}

/// The mark for this app at a pixel size, in pixels.
func mark(size s: CGFloat, sender snd: Bool) -> Mark {
    let d = detail(s)
    let g = arranged(d, sender: false), t = arranged(d, sender: true)
    let target: CGFloat = [0.74, 0.70, 0.66][d]
    let bg = bounds(g), bt = bounds(t)
    let scale = target / max(bg.width, bg.height, bt.width, bt.height)
    let m = snd ? t : g
    let b = bounds(m)
    let tx = round((0.5 - b.midX * scale) * s) / s, ty = round((0.5 - b.midY * scale) * s) / s
    return apply(m, CGAffineTransform(scaleX: s, y: s).translatedBy(x: tx, y: ty).scaledBy(x: scale, y: scale))
}

/// Packet squares in pixels. Hard corners snapped to whole pixels at 32 and 16 px.
func packetPath(_ p: Packet, size s: CGFloat) -> CGPath {
    if detail(s) < 2 {
        let side = max(2, round(p.side))
        let r = CGRect(x: round(p.centre.x - side / 2), y: round(p.centre.y - side / 2), width: side, height: side)
        return CGPath(rect: r, transform: nil)
    }
    let r = CGRect(x: p.centre.x - p.side / 2, y: p.centre.y - p.side / 2, width: p.side, height: p.side)
    return CGPath(roundedRect: r, cornerWidth: p.side * 0.24, cornerHeight: p.side * 0.24, transform: nil)
}

// MARK: - Drawing

func platePath(_ s: CGFloat) -> CGPath {
    // Radius and inset unchanged from every earlier version, so the icon sits at the same size
    // as its neighbours on the Dock.
    CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s).insetBy(dx: s * 0.02, dy: s * 0.02),
           cornerWidth: s * 0.223, cornerHeight: s * 0.223, transform: nil)
}

func drawIcon(size s: CGFloat) -> NSBitmapImageRep? {
    let px = Int(s)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let c = ctx.cgContext

    let (top, bottom) = sender ? senderPlate : grabberPlate
    c.saveGState()
    c.addPath(platePath(s))
    c.clip()
    let ground = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: [cg(top), cg(bottom)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(ground, start: CGPoint(x: 0, y: s), end: .zero, options: [])

    let m = mark(size: s, sender: sender)
    c.setFillColor(cg(sender ? senderMark : grabberMark))
    c.addPath(m.u)
    c.fillPath()
    c.setFillColor(cg(sender ? senderPackets : grabberPackets))
    for p in m.packets { c.addPath(packetPath(p, size: s)) }
    c.fillPath()

    if s >= 128 {
        c.addPath(platePath(s))
        c.setStrokeColor(sender ? CGColor(gray: 0, alpha: 0.10) : CGColor(gray: 1, alpha: 0.10))
        c.setLineWidth(max(1, s * 0.005))
        c.strokePath()
    }
    c.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - Layer notes for Icon Composer

if mode == "layers" {
    var note = "Network Audio Grabber / Sender icons: layers for Icon Composer\n"
    note += "Measured on the 1024 canvas, origin bottom-left. Generated by Tools/make_icon.swift.\n\n"
    for snd in [false, true] {
        let m = mark(size: 1024, sender: snd)
        let (pt, pb) = snd ? senderPlate : grabberPlate
        let b = m.u.boundingBoxOfPath
        note += snd ? "SENDER\n" : "GRABBER\n"
        note += "  Group 0  plate (background): vertical gradient \(hex(pt)) top to \(hex(pb)) bottom; no stroke (the system adds the edge).\n"
        note += "  Group 1  U: fill \(hex(snd ? senderMark : grabberMark)), opaque, ends cut flat. Export the path from the 1024 px PNG or\n"
        note += String(format: "           redraw: bounding box x %.0f  y %.0f  w %.0f  h %.0f.\n", b.minX, b.minY, b.width, b.height)
        note += "  Group 2  packets: fill \(hex(snd ? senderPackets : grabberPackets)), corner radius 24 % of the side.\n"
        for p in m.packets { note += String(format: "           centre (%.0f, %.0f)  side %.0f\n", p.centre.x, p.centre.y, p.side) }
        note += "  Mono (Clear / Tinted): Group 1 white (the most prominent element), Group 2 white at about 60 %, plate to glass.\n"
        note += "  16 and 32 px: use the masters in the .icns (fewer, larger packets, snapped to whole pixels), not a downscale.\n\n"
    }
    try note.write(toFile: "\(outDir)/layers.txt", atomically: true, encoding: .utf8)
    print("Wrote \(outDir)/layers.txt")
    exit(0)
}

// The set of sizes iconutil expects. `@2x` of 16 is 32 px and takes the 32 px master.
let variants: [(name: String, size: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

try? FileManager.default.removeItem(atPath: iconsetDir)
try FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

for v in variants {
    guard let rep = drawIcon(size: v.size),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("failed at \(v.name)")
        exit(1)
    }
    try png.write(to: URL(fileURLWithPath: "\(iconsetDir)/\(v.name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetDir, "-o", "\(outDir)/\(product).icns"]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(atPath: iconsetDir)
print(iconutil.terminationStatus == 0 ? "Wrote \(outDir)/\(product).icns" : "iconutil failed")
exit(iconutil.terminationStatus)
