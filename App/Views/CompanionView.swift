import SwiftUI
import UIKit

/// What the companion is doing right now. Transient actions (walk/celebrate) play
/// for a fixed duration from `actionStart`, then it falls back to idle on its own.
enum CompanionAction: Equatable { case idle, walk, celebrate, cheer }

/// The little companion that follows you page to page — drawn entirely in a Canvas
/// so its limbs can be rigged (rotated around their joints) and its *evolution* is
/// ours to shape. Low `progress` (fidelity 0→1) = a barely-formed seed with eyes;
/// as it rises it grows a body, gains its dominant-axis color, then arms and legs.
/// Idle breathing + blinking keep it alive; it walks on page changes and does
/// jumping jacks when you make a connection.
struct CompanionView: View {
    var progress: Double
    var tint: Color
    var action: CompanionAction
    var actionStart: Date

    private let walkDuration = 1.5
    private let celebrateDuration = 2.0
    private let cheerDuration = 1.8

    var body: some View {
        // Cap the redraw rate. `.animation` runs at full display refresh (60/120fps) on
        // EVERY screen, competing with the main thread and making map panning / scrolling
        // sticky. 30fps is plenty for breathing and a walk cycle, and roughly halves the cost.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            companionBody(now: ctx.date)
        }
    }

    private func companionBody(now: Date) -> some View {
        let t = now.timeIntervalSinceReferenceDate
            let elapsed = now.timeIntervalSince(actionStart)
            let p = max(0, min(1, progress))

            var act = action
            if act == .walk, elapsed > walkDuration { act = .idle }
            if act == .celebrate, elapsed > celebrateDuration { act = .idle }
            if act == .cheer, elapsed > cheerDuration { act = .idle }

            let breath = sin(t * 1.7)
            var hop = CGFloat(breath) * 2.0
            var scoot: CGFloat = 0
            var squash = 1 + CGFloat(breath) * 0.045
            var armAngle = 16.0     // degrees from straight-down
            var legAngle = 7.0
            var armSwing = 0.0
            var legSwing = 0.0
            var cheer: Double? = nil    // elapsed time while cheering (drives hearts + happy eyes)

            switch act {
            case .idle:
                break
            case .walk:
                let w = elapsed * 9
                armSwing = sin(w) * 16
                legSwing = -sin(w) * 16
                hop = CGFloat(abs(sin(w))) * -2.5
                scoot = CGFloat(sin(elapsed * 5.5)) * 4
            case .celebrate:
                let up = (1 - cos(elapsed * 2 * .pi / 0.5)) / 2   // 0→1→0 every 0.5s
                armAngle = 16 + up * 148        // arms swing overhead
                legAngle = 7 + up * 20          // legs spread
                hop = CGFloat(-up * 13)         // and hop
                squash = 1 + CGFloat(up * 0.05)
            case .cheer:
                // two decaying joyful bounces, arms lifting, hearts floating up
                let amp = max(0, 1 - elapsed / cheerDuration)
                let bounce = abs(sin(elapsed * .pi / 0.42))
                hop = CGFloat(-bounce * 15 * amp)
                squash = 1 + CGFloat((1 - bounce) * 0.09 * amp)
                armAngle = 16 + bounce * 55 * amp
                cheer = elapsed
            }

            let blink = t.truncatingRemainder(dividingBy: 3.6) < 0.13 ? 0.12 : 1.0
            let bodyColor = mix(Color(white: 0.66), tint, 0.15 + 0.85 * p)

            return ZStack {
                Circle()
                    .fill(tint.opacity(0.10 + 0.16 * p))
                    .frame(width: 120, height: 120)
                    .blur(radius: 13)
                    .scaleEffect(0.6 + 0.4 * p + CGFloat(breath) * 0.04)

                Canvas { gc, size in
                    draw(gc, size: size, p: p, color: bodyColor,
                         armAngle: armAngle, legAngle: legAngle,
                         armSwing: armSwing, legSwing: legSwing,
                         squash: squash, blink: blink, cheer: cheer)
                }
            }
            .frame(width: 100, height: 116)
            .offset(x: scoot, y: hop)
    }

    private func draw(_ gc: GraphicsContext, size: CGSize, p: Double, color: Color,
                      armAngle: Double, legAngle: Double, armSwing: Double, legSwing: Double,
                      squash: CGFloat, blink: Double, cheer: Double?) {
        let cx = size.width / 2
        let cy = size.height * 0.52
        let bodyW = 26 + 30 * p
        let bodyH = (30 + 34 * p) * Double(squash)
        let limbColor = GraphicsContext.Shading.color(color)

        func limb(from: CGPoint, angle: Double, side: Double, length: Double, width: Double, opacity: Double) {
            guard opacity > 0.01 else { return }
            let a = angle * .pi / 180
            let end = CGPoint(x: from.x + side * sin(a) * length, y: from.y + cos(a) * length)
            var path = Path()
            path.move(to: from)
            path.addLine(to: end)
            gc.stroke(path, with: limbColor, style: StrokeStyle(lineWidth: width, lineCap: .round))
        }

        // legs (appear ~p>0.5)
        let legOp = smooth(p, 0.5, 0.72)
        let hipY = cy + bodyH * 0.42
        limb(from: CGPoint(x: cx - bodyW * 0.18, y: hipY), angle: legAngle - legSwing, side: -1, length: bodyH * 0.55, width: 7, opacity: legOp)
        limb(from: CGPoint(x: cx + bodyW * 0.18, y: hipY), angle: legAngle + legSwing, side: 1, length: bodyH * 0.55, width: 7, opacity: legOp)

        // arms (appear ~p>0.35)
        let armOp = smooth(p, 0.32, 0.52)
        let shoulderY = cy - bodyH * 0.22
        limb(from: CGPoint(x: cx - bodyW * 0.40, y: shoulderY), angle: armAngle + armSwing, side: -1, length: bodyH * 0.5, width: 6, opacity: armOp)
        limb(from: CGPoint(x: cx + bodyW * 0.40, y: shoulderY), angle: armAngle - armSwing, side: 1, length: bodyH * 0.5, width: 6, opacity: armOp)

        // body
        let bodyRect = CGRect(x: cx - bodyW / 2, y: cy - bodyH / 2, width: bodyW, height: bodyH)
        gc.fill(Capsule().path(in: bodyRect), with: limbColor)
        // subtle highlight
        let hl = CGRect(x: cx + bodyW * 0.06, y: cy - bodyH * 0.30, width: bodyW * 0.22, height: bodyW * 0.22)
        gc.fill(Path(ellipseIn: hl), with: .color(.white.opacity(0.35)))

        // eyes — happy upward arcs while cheering, otherwise blinking dots
        let eyeW = max(3.5, bodyW * 0.11)
        let eyeMidY = cy - bodyH * 0.12
        if cheer != nil {
            for dx in [-bodyW * 0.20, bodyW * 0.20] {
                let ex = cx + dx
                var e = Path()
                e.move(to: CGPoint(x: ex - eyeW, y: eyeMidY + eyeW * 0.2))
                e.addQuadCurve(to: CGPoint(x: ex + eyeW, y: eyeMidY + eyeW * 0.2),
                               control: CGPoint(x: ex, y: eyeMidY - eyeW * 1.2))
                gc.stroke(e, with: .color(.black.opacity(0.78)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            }
        } else {
            let eyeH = max(5, bodyW * 0.16) * blink
            for dx in [-bodyW * 0.20, bodyW * 0.20] {
                let r = CGRect(x: cx + dx - eyeW / 2, y: eyeMidY - eyeH / 2, width: eyeW, height: eyeH)
                gc.fill(Capsule().path(in: r), with: .color(.black.opacity(0.78)))
            }
        }

        // floating hearts rising as it cheers
        if let ce = cheer {
            let pink = Color(red: 0.96, green: 0.36, blue: 0.52)
            for (i, fx) in [-0.5, 0.18, 0.55].enumerated() {
                let lt = ce - Double(i) * 0.22
                guard lt > 0 else { continue }
                let life = min(1, lt / 1.25)
                let op = min(1, life / 0.12) * (1 - life)
                guard op > 0.02 else { continue }
                let hx = cx + fx * bodyW
                let hy = (cy - bodyH * 0.55) - CGFloat(life) * 44
                let hs = 6.5 * (0.8 + 0.3 * sin(life * .pi))
                gc.fill(heartPath(CGPoint(x: hx, y: hy), hs), with: .color(pink.opacity(op)))
            }
        }
    }

    /// A small heart, tip at the bottom, built from cubic curves (no arc-direction
    /// ambiguity), for the "positive link" reaction.
    private func heartPath(_ c: CGPoint, _ s: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: c.y + s))
        p.addCurve(to: CGPoint(x: c.x - s, y: c.y - s * 0.4),
                   control1: CGPoint(x: c.x - s * 0.6, y: c.y + s * 0.3),
                   control2: CGPoint(x: c.x - s, y: c.y - s * 0.1))
        p.addCurve(to: CGPoint(x: c.x, y: c.y - s * 0.25),
                   control1: CGPoint(x: c.x - s, y: c.y - s * 0.78),
                   control2: CGPoint(x: c.x - s * 0.35, y: c.y - s * 0.78))
        p.addCurve(to: CGPoint(x: c.x + s, y: c.y - s * 0.4),
                   control1: CGPoint(x: c.x + s * 0.35, y: c.y - s * 0.78),
                   control2: CGPoint(x: c.x + s, y: c.y - s * 0.78))
        p.addCurve(to: CGPoint(x: c.x, y: c.y + s),
                   control1: CGPoint(x: c.x + s, y: c.y - s * 0.1),
                   control2: CGPoint(x: c.x + s * 0.6, y: c.y + s * 0.3))
        p.closeSubpath()
        return p
    }

    private func smooth(_ x: Double, _ a: Double, _ b: Double) -> Double { max(0, min(1, (x - a) / (b - a))) }

    private func mix(_ a: Color, _ b: Color, _ f: Double) -> Color {
        let ua = UIColor(a), ub = UIColor(b)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        ua.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        ub.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let f2 = CGFloat(max(0, min(1, f)))
        return Color(red: Double(r1 + (r2 - r1) * f2), green: Double(g1 + (g2 - g1) * f2), blue: Double(b1 + (b2 - b1) * f2))
    }
}
