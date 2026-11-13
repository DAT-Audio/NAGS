// Draws the quick-start guide's red marks: a numbered box or ring around each
// thing to look at or click, on a rendered screenshot, optionally cropped first.
//
//   swift Tools/annotate-guide.swift <spec.json> <raw dir> <out dir>
//
// spec.json: [{"in": "g1-list.png", "out": "1-1-pick-network.png",
//              "crop": [x, y, w, h],                      // optional, image pixels, from top-left
//              "marks": [{"rect": [x, y, w, h], "n": 1, "ring": false}]}]
// Mark rectangles are in the uncropped image's pixels. The pictures come from
// `NetworkAudioGrabber --guide-shots <dir>` and `NetworkAudioSender --render <dir>` — made-up
// names and documentation addresses only, never a real screen.
import AppKit

struct Mark: Decodable { let rect: [Double]; let n: Int?; let ring: Bool? }
struct Shot: Decodable { let `in`: String; let out: String; let crop: [Double]?; let marks: [Mark] }

let args = CommandLine.arguments
guard args.count == 4, let data = FileManager.default.contents(atPath: args[1]),
      let shots = try? JSONDecoder().decode([Shot].self, from: data) else {
    print("usage: annotate-guide.swift <spec.json> <raw dir> <out dir>"); exit(2)
}
let red = CGColor(red: 0.95, green: 0.12, blue: 0.12, alpha: 1)

for shot in shots {
    guard let image = NSImage(contentsOfFile: "\(args[2])/\(shot.in)"),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        print("missing \(shot.in)"); continue
    }
    let full = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
    let crop = shot.crop.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) } ?? full
    let w = Int(crop.width), h = Int(crop.height)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
    // Top-left coordinates, as the marks are written.
    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
    ctx.saveGState()
    ctx.translateBy(x: -crop.minX, y: -crop.minY)
    ctx.translateBy(x: 0, y: full.height); ctx.scaleBy(x: 1, y: -1)
    ctx.draw(cg, in: full)
    ctx.restoreGState()

    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    for m in shot.marks {
        let r = CGRect(x: m.rect[0] - crop.minX, y: m.rect[1] - crop.minY,
                       width: m.rect[2], height: m.rect[3]).insetBy(dx: -4, dy: -4)
        ctx.setStrokeColor(red); ctx.setLineWidth(3)
        if m.ring == true { ctx.strokeEllipse(in: r.insetBy(dx: -3, dy: -3)) }
        else { ctx.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil)); ctx.strokePath() }
        guard let n = m.n else { continue }
        // The number in a red disc at the box's top-left corner, kept inside the picture.
        let d: CGFloat = 22
        let cx = min(max(r.minX - 6, d / 2 + 2), CGFloat(w) - d / 2 - 2)
        let cy = min(max(r.minY - 6, d / 2 + 2), CGFloat(h) - d / 2 - 2)
        let disc = CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)
        ctx.setFillColor(red); ctx.fillEllipse(in: disc)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1)); ctx.setLineWidth(1.5); ctx.strokeEllipse(in: disc)
        let text = NSAttributedString(string: "\(n)", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.white])
        let size = text.size()
        text.draw(at: CGPoint(x: disc.midX - size.width / 2, y: disc.midY - size.height / 2))
    }
    NSGraphicsContext.current = nil
    guard let out = ctx.makeImage(),
          let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(args[3])/\(shot.out)"))
    print("wrote \(shot.out)")
}
