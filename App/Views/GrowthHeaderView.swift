import SwiftUI
import NuminousCore

/// The growth summary at the top of the list: an abstract avatar "orb" whose
/// fidelity and color cast reflect your growth and axis balance, the current
/// public stage, and a gentle note when new growth is waiting to be revealed.
struct GrowthHeaderView: View {
    @EnvironmentObject var store: NoteStore

    var body: some View {
        let score = store.score
        let stage = score.stage()
        let fidelity = score.fidelity()
        let balance = score.axisBalance(over: store.axes)

        VStack(spacing: 14) {
            AvatarOrb(balance: balance, axes: store.axes, fidelity: fidelity)

            VStack(spacing: 2) {
                Text(stage.name)
                    .font(.title3.weight(.semibold))
                Text("Stage \(stage.index + 1) of \(Stage.ladder.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: fidelity)
                .tint(dominantColor(balance))

            AxisBalanceBar(balance: balance, axes: store.axes)

            if score.pendingTotal > 0 {
                Label("New growth appears on your next visit", systemImage: "leaf")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private func dominantColor(_ balance: AxisTotals) -> Color {
        let top = store.axes.max { (balance[$0.id] ?? 0) < (balance[$1.id] ?? 0) }
        return top?.color ?? .accentColor
    }
}

/// A low-detail-to-defined orb. It blurs and fades when growth is young, then
/// sharpens and saturates — "increasing fidelity, not distinct organs."
private struct AvatarOrb: View {
    let balance: AxisTotals
    let axes: [Axis]
    let fidelity: Double

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
        .frame(width: 120, height: 120)
        .blur(radius: (1 - fidelity) * 3)
        .accessibilityHidden(true)
    }
}

/// Four capsules, one per axis, brightening with that axis's share of growth.
private struct AxisBalanceBar: View {
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
