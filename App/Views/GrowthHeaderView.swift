import SwiftUI
import NuminousCore

/// Compact growth summary at the top of the notes list: the avatar orb, the
/// current stage, an axis-balance bar, and a gentle note when new growth is
/// waiting to be revealed. The full breakdown lives in `GrowthView`.
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
                .tint(dominantAxisColor(balance, axes: store.axes))

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
}
