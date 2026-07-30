import SwiftUI
import NuminousCore

/// A low-detail-to-defined orb standing in for the avatar. It blurs and fades
/// when growth is young, then sharpens and saturates as fidelity rises —
/// "increasing fidelity, not distinct organs." The color cast reflects which
/// axes you've grown.
struct AvatarOrb: View {
    let balance: AxisTotals
    let axes: [Axis]
    let fidelity: Double
    var size: CGFloat = 120

    var body: some View {
        let weighted = axes.map { $0.color.opacity(0.25 + 0.75 * (balance[$0.id] ?? 0)) }
        let gradientColors = weighted.isEmpty ? [Color.gray] : weighted + [weighted[0]]

        ZStack {
            Circle()
                .fill(AngularGradient(gradient: Gradient(colors: gradientColors), center: .center))
                .opacity(0.35 + 0.65 * fidelity)
            Circle()
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
        .frame(width: size, height: size)
        .blur(radius: (1 - fidelity) * 3)
        .accessibilityHidden(true)
    }
}

/// Four capsules, one per axis, brightening with that axis's share of growth.
struct AxisBalanceBar: View {
    let balance: AxisTotals
    let axes: [Axis]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(axes) { axis in
                VStack(spacing: 4) {
                    Capsule()
                        .fill(axis.color)
                        .opacity(0.25 + 0.75 * (balance[axis.id] ?? 0))
                        .frame(height: 6)
                    Text(axis.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The color of the axis with the largest share of growth (for accents).
func dominantAxisColor(_ balance: AxisTotals, axes: [Axis]) -> Color {
    let top = axes.max { (balance[$0.id] ?? 0) < (balance[$1.id] ?? 0) }
    return top?.color ?? .accentColor
}
