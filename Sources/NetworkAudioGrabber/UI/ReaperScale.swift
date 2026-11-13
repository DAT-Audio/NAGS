import SwiftUI

/// REAPER's meter scale, for the Rea-Theme Default skin: ticks
/// along the edges and the figures across the middle, drawn over the bars or between them.
/// A `Canvas` with no live inputs: drawn once per size, never on the meters' clock.
struct ReaperScale: View {
    let vertical: Bool
    /// Figures as REAPER writes them beside a vertical meter: "-18-".
    var dashed = false
    var marks: [Int] = [-6, -12, -18, -24, -30, -36, -42, -48, -54]

    var body: some View {
        Canvas { ctx, size in
            let label = Color(white: 0.55)
            let tick = Color(white: 0.55).opacity(0.8)
            for db in marks {
                let f = CGFloat(db + 60) / 60                  // the meters' −60 dBFS mapping
                let text = Text(verbatim: dashed ? "\(db)-" : "\(db)")
                    .font(.system(size: 7, weight: .medium)).monospacedDigit()
                    .foregroundStyle(label)
                if vertical {
                    let y = size.height * (1 - f)
                    ctx.draw(text, at: CGPoint(x: size.width / 2, y: y), anchor: .center)
                } else {
                    let x = size.width * f
                    ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: 3)), with: .color(tick))
                    ctx.fill(Path(CGRect(x: x - 0.5, y: size.height - 3, width: 1, height: 3)), with: .color(tick))
                    ctx.draw(text, at: CGPoint(x: x, y: size.height / 2), anchor: .center)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
