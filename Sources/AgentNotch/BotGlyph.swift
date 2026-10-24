import SwiftUI

/// The AgentNotch mark: a little bot head with an antenna spark. Drawn with shapes so it stays
/// crisp at menu bar size and tints with `foregroundStyle`. Waiting sessions raise its eyebrows.
struct BotGlyph: View {
    var waiting = false

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 16
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: x * s, y: y * s, width: w * s, height: h * s)
            }
            let ink = GraphicsContext.Shading.foreground

            // Head.
            context.stroke(Path(roundedRect: r(1.75, 5.5, 12.5, 9), cornerRadius: 3.2 * s), with: ink, lineWidth: 1.5 * s)
            // Eyes: dots, or wide ovals when a session is waiting on you.
            let eyeH: CGFloat = waiting ? 3.2 : 2.4
            context.fill(Path(ellipseIn: r(4.6, 10 - eyeH / 2, 2.2, eyeH)), with: ink)
            context.fill(Path(ellipseIn: r(9.2, 10 - eyeH / 2, 2.2, eyeH)), with: ink)
            // Antenna.
            var stem = Path()
            stem.move(to: CGPoint(x: 8 * s, y: 5.5 * s))
            stem.addLine(to: CGPoint(x: 8 * s, y: 3.6 * s))
            context.stroke(stem, with: ink, lineWidth: 1.3 * s)
            // Four-point spark on top: the "AI" bit.
            context.fill(Self.spark(center: CGPoint(x: 8 * s, y: 2.2 * s), radius: 2.2 * s), with: ink)
        }
        .accessibilityLabel(waiting ? "AgentNotch, a session is waiting" : "AgentNotch")
    }

    static func spark(center c: CGPoint, radius r: CGFloat) -> Path {
        var p = Path()
        let k = r * 0.28
        p.move(to: CGPoint(x: c.x, y: c.y - r))
        p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + k, y: c.y - k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + k, y: c.y + k))
        p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - k, y: c.y + k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - k, y: c.y - k))
        p.closeSubpath()
        return p
    }
}
