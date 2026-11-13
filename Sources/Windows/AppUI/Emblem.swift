import Foundation

/// The emblems' geometry, from the Mac's `EmblemGeometry` (`Sources/NetworkAudioShared/AppEmblem.swift`,
/// itself `Tools/make_icon.swift`'s): a U stroked as a centre line, and its file of packets,
/// arranged one way for the Grabber and another for the Sender. Change one and change the others.
enum Emblem {
    struct Mark {
        var u: [(Double, Double)]          // the U's centre line, in pixels
        var width: Double                  // its stroke, in pixels
        var packets: [(x: Double, y: Double, side: Double)]
    }

    typealias P = (Double, Double)

    /// The U and the packets in the icon's local frame, mouth up (y up).
    private static func local(_ d: Int) -> (u: [P], lw: Double, centres: [P], sides: [Double]) {
        let lw = 0.085 * 1.3 * [1.35, 1.15, 1.0][d]
        var u: [P] = [(-0.26, 0.02), (-0.26, -0.06)]
        let steps = 24
        for i in 1...steps {                       // π to 2π: down round the bottom
            let a = Double.pi + Double.pi * Double(i) / Double(steps)
            u.append((0.26 * cos(a), -0.06 + 0.26 * sin(a)))
        }
        u.append((0.26, 0.02))
        let top = 0.02 + lw / 2 + 0.02
        let file: [(Double, Double)] = [[(0.10, 0.15)], [(0.085, 0.085), (0.27, 0.115)],
                                        [(0.075, 0.055), (0.165, 0.072), (0.28, 0.09)]][d]
        return (u, lw, file.map { (0, top + $0.0) }, file.map(\.1))
    }

    private static func rotate(_ p: P, deg: Double, about c: P = (0, 0)) -> P {
        let a = deg * .pi / 180
        let x = p.0 - c.0, y = p.1 - c.1
        return (c.0 + x * cos(a) - y * sin(a), c.1 + x * sin(a) + y * cos(a))
    }

    /// Arranged as each icon has it: the Grabber turned 45° clockwise and mirrored; the Sender
    /// turned 90° anticlockwise, its U flipped about its centre, the whole turned 135° clockwise.
    private static func arranged(sender: Bool, detail d: Int) -> (u: [P], lw: Double, centres: [P], sides: [Double]) {
        let (u, lw, centres, sides) = local(d)
        if sender {
            let q = u.map { rotate($0, deg: 90) }
            let xs = q.map(\.0), ys = q.map(\.1)
            let mid = ((xs.min()! + xs.max()!) / 2, (ys.min()! + ys.max()!) / 2)
            let au = q.map { rotate(rotate($0, deg: 180, about: mid), deg: -135) }
            let ac = centres.map { rotate(rotate($0, deg: 90), deg: -135) }
            return (au, lw, ac, sides)
        }
        let flip: (P) -> P = { p in let r = rotate(p, deg: -45); return (-r.0, r.1) }
        return (u.map(flip), lw, centres.map(flip), sides)
    }

    private static func bounds(_ m: (u: [P], lw: Double, centres: [P], sides: [Double])) -> (Double, Double, Double, Double) {
        var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
        func take(_ x: Double, _ y: Double) { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
        for p in m.u { take(p.0 - m.lw / 2, p.1 - m.lw / 2); take(p.0 + m.lw / 2, p.1 + m.lw / 2) }
        for (c, s) in zip(m.centres, m.sides) { take(c.0 - s / 2, c.1 - s / 2); take(c.0 + s / 2, c.1 + s / 2) }
        return (minX, maxX, minY, maxY)
    }

    /// Fitted to a square of `size` pixels, y flipped for the screen, and scaled by one factor for
    /// both apps so the two emblems are the same size, as the icons are.
    static func fitted(size: Double, detail d: Int, sender: Bool = false) -> Mark {
        let g = arranged(sender: false, detail: d), s = arranged(sender: true, detail: d)
        let bg = bounds(g), bs = bounds(s)
        let extent = max(bg.1 - bg.0, bg.3 - bg.2, bs.1 - bs.0, bs.3 - bs.2)
        let scale = size * 0.96 / extent
        let m = sender ? s : g
        let b = sender ? bs : bg
        let mx = (b.0 + b.1) / 2, my = (b.2 + b.3) / 2
        func screen(_ p: P) -> P { (size / 2 + (p.0 - mx) * scale, size / 2 - (p.1 - my) * scale) }
        return Mark(u: m.u.map(screen), width: m.lw * scale,
                    packets: zip(m.centres, m.sides).map { c, side in
                        let q = screen(c)
                        return (q.0 - side * scale / 2, q.1 - side * scale / 2, side * scale)
                    })
    }
}
