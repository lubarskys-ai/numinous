import SwiftUI
import UIKit

/// The little companion that follows you page to page — drawn entirely in code so
/// its *evolution* is ours to shape. At low growth it's barely a glowing seed with
/// eyes; as `progress` (fidelity 0→1) rises it grows a body, gains its dominant
/// axis color, and sprouts arms then legs. Idle breathing + blinking keep it alive.
struct CompanionView: View {
    /// Overall growth, 0→1 (drives how formed it is).
    var progress: Double
    /// Dominant-axis color it matures toward.
    var tint: Color

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let p = max(0, min(1, progress))
            let breath = sin(t * 1.7)
            let bob = CGFloat(breath) * 2.2
            let squash = 1 + CGFloat(breath) * 0.045
            let blink = t.truncatingRemainder(dividingBy: 3.6) < 0.13 ? 0.12 : 1.0

            let bodyW = 26 + 30 * p
            let bodyH = 30 + 34 * p
            let grey = Color(white: 0.66)
            let bodyColor = mix(grey, tint, 0.15 + 0.85 * p)
            let armOp = smooth(p, 0.32, 0.52)
            let legOp = smooth(p, 0.5, 0.72)

            ZStack {
                // aura
                Circle()
                    .fill(tint.opacity(0.10 + 0.16 * p))
                    .frame(width: bodyW * 2.4, height: bodyW * 2.4)
                    .blur(radius: 12)
                    .scaleEffect(1 + CGFloat(breath) * 0.05)

                // legs
                Group {
                    limb(bodyColor, w: 7, h: 20).offset(x: -bodyW * 0.20, y: bodyH * 0.52)
                    limb(bodyColor, w: 7, h: 20).offset(x:  bodyW * 0.20, y: bodyH * 0.52)
                }
                .opacity(legOp)

                // arms
                Group {
                    limb(bodyColor, w: 6, h: 18).rotationEffect(.degrees(24)).offset(x: -bodyW * 0.52, y: bodyH * 0.06)
                    limb(bodyColor, w: 6, h: 18).rotationEffect(.degrees(-24)).offset(x: bodyW * 0.52, y: bodyH * 0.06)
                }
                .opacity(armOp)

                // body
                Capsule()
                    .fill(bodyColor)
                    .frame(width: bodyW, height: bodyH * squash)
                    .overlay(alignment: .topTrailing) {
                        Circle().fill(.white.opacity(0.4)).frame(width: bodyW * 0.22, height: bodyW * 0.22)
                            .offset(x: -bodyW * 0.14, y: bodyH * 0.16)
                    }

                // eyes
                HStack(spacing: bodyW * 0.24) {
                    eye(bodyW); eye(bodyW)
                }
                .offset(y: -bodyH * 0.10)
                .scaleEffect(x: 1, y: blink, anchor: .center)
            }
            .frame(width: 100, height: 116)
            .offset(y: bob)
        }
    }

    private func limb(_ color: Color, w: CGFloat, h: CGFloat) -> some View {
        Capsule().fill(color).frame(width: w, height: h)
    }

    private func eye(_ bodyW: CGFloat) -> some View {
        Capsule()
            .fill(Color.black.opacity(0.78))
            .frame(width: max(3.5, bodyW * 0.11), height: max(5, bodyW * 0.16))
    }

    private func smooth(_ x: Double, _ a: Double, _ b: Double) -> Double {
        max(0, min(1, (x - a) / (b - a)))
    }

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
