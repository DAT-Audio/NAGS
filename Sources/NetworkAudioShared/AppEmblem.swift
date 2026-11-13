import SwiftUI

/// The app icon's mark, small and in one colour, for the window header: the U and its file of
/// packets, without the plate. Drawn in the header's own muted grey, so it follows light and
/// dark and the colour scheme like the controls beside it, and says which app this is without
/// a title.
///
/// **An identifier, not a control:** no plate or button shape, a fainter grey than the controls
/// beside it, and the app's name in small type beneath, so it is not mistaken for a button, a
/// spinner, or anything about the audio device.
///
/// **The geometry is `Tools/make_icon.swift`'s**, at its 16 px detail (one packet, the heaviest
/// U), which is the design drawn for this size. Change one and change the other.
public struct AppEmblem: View {
    public enum App { case grabber, sender }
    /// Where the name goes: beside the mark (the headers, chosen over a caption
    /// squeezed beneath it), small beneath it, or none.
    public enum Caption { case beside, below, none }
    let app: App
    let size: CGFloat
    let caption: Caption

    public init(_ app: App, size: CGFloat = 14, caption: Caption = .below) {
        self.app = app; self.size = size; self.caption = caption
    }

    public var body: some View {
        Group {
            if caption == .beside {
                HStack(spacing: size * 0.32) {
                    mark
                    Text(name)
                        .font(.system(size: (size * 0.6).rounded(), weight: .semibold))
                        .foregroundStyle(Color.mutedLabel)
                        .fixedSize()
                }
            } else {
                VStack(spacing: 1) {
                    mark
                    if caption == .below {
                        Text(name)
                            .font(.system(size: max(7.5, size * 0.4), weight: .medium))
                            .foregroundStyle(Color.mutedLabel)
                            .fixedSize()
                    }
                }
            }
        }
        .opacity(0.6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app == .grabber ? "Network Audio Grabber" : "Network Audio Sender")
    }

    private var name: String { app == .grabber ? "Grabber" : "Sender" }

    private var mark: some View {
            Canvas { context, box in
                let mark = EmblemGeometry.fitted(sender: app == .sender, in: box,
                                                 detail: EmblemGeometry.detail(for: size))
                context.fill(Path(mark.u), with: .color(Color.mutedLabel))
                var packets = Path()
                for r in mark.packets { packets.addRoundedRect(in: r, cornerSize: CGSize(width: r.width * 0.2, height: r.width * 0.2)) }
                context.fill(packets, with: .color(Color.mutedLabel))
            }
            .frame(width: size, height: size)
    }
}

enum EmblemGeometry {
    struct Mark { var u: CGPath; var packets: [CGRect] }

    private static func about(_ c: CGPoint, deg: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: c.x, y: c.y).rotated(by: deg * .pi / 180).translatedBy(x: -c.x, y: -c.y)
    }

    /// The icon's detail level for a mark drawn this many points across: one packet and the
    /// heaviest U below 20, two packets below 40, three above — the icon tool's 16 / 32 / 48 px.
    static func detail(for points: CGFloat) -> Int { points < 20 ? 0 : (points < 40 ? 1 : 2) }

    /// The U and packet centres in the icon's local frame, mouth up — `localMark(d)` in the
    /// icon tool.
    private static func local(_ d: Int) -> (u: CGPath, centres: [CGPoint], sides: [CGFloat]) {
        let lw = 0.085 * 1.3 * [1.35, 1.15, 1.0][d]
        let u = CGMutablePath()
        u.move(to: CGPoint(x: -0.26, y: 0.02))
        u.addLine(to: CGPoint(x: -0.26, y: -0.06))
        u.addArc(center: CGPoint(x: 0, y: -0.06), radius: 0.26, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
        u.addLine(to: CGPoint(x: 0.26, y: 0.02))
        let stroke = u.copy(strokingWithWidth: lw, lineCap: .butt, lineJoin: .round, miterLimit: 10)
        let top = 0.02 + lw / 2 + 0.02
        let file: [(CGFloat, CGFloat)] = [[(0.10, 0.15)],
                                          [(0.085, 0.085), (0.27, 0.115)],
                                          [(0.075, 0.055), (0.165, 0.072), (0.28, 0.09)]][d]
        return (stroke, file.map { CGPoint(x: 0, y: top + $0.0) }, file.map(\.1))
    }

    /// Arranged as each icon has it: the Grabber turned 45° clockwise and mirrored; the Sender
    /// turned 90° anticlockwise, its U flipped about its centre, the whole turned 135° clockwise.
    private static func arranged(sender: Bool, detail d: Int) -> Mark {
        let (u, centres, sides) = local(d)
        let groupT: CGAffineTransform, uT: CGAffineTransform
        if sender {
            let q = about(.zero, deg: 90)
            let b = u.boundingBoxOfPath.applying(q)
            let turn = about(.zero, deg: -135)
            groupT = q.concatenating(turn)
            uT = q.concatenating(about(CGPoint(x: b.midX, y: b.midY), deg: 180)).concatenating(turn)
        } else {
            groupT = about(.zero, deg: -45).concatenating(CGAffineTransform(scaleX: -1, y: 1))
            uT = groupT
        }
        var t = uT
        let packets = zip(centres, sides).map { c, s -> CGRect in
            let p = c.applying(groupT)
            return CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
        }
        return Mark(u: u.copy(using: &t)!, packets: packets)
    }

    private static func bounds(_ m: Mark) -> CGRect {
        m.packets.reduce(m.u.boundingBoxOfPath) { $0.union($1) }
    }

    /// Fitted to `size`, y flipped for SwiftUI, and scaled by one factor for both apps so the two
    /// emblems are the same size, as the icons are.
    static func fitted(sender: Bool, in size: CGSize, detail d: Int = 0) -> Mark {
        let g = arranged(sender: false, detail: d), s = arranged(sender: true, detail: d)
        let bg = bounds(g), bs = bounds(s)
        let side = min(size.width, size.height)
        let scale = side * 0.96 / max(bg.width, bg.height, bs.width, bs.height)
        let m = sender ? s : g
        let b = bounds(m)
        let t = CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
            .scaledBy(x: scale, y: -scale)
            .translatedBy(x: -b.midX, y: -b.midY)
        var tu = t
        return Mark(u: m.u.copy(using: &tu)!, packets: m.packets.map { $0.applying(t) })
    }
}
