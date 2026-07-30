import SwiftUI
import NuminousCore

/// The growth "payoff" screen: a larger avatar, the stage and progress, a
/// per-axis breakdown, and a summary of the connections driving growth — with
/// the cross-axis count highlighted, since that's the whole point.
struct GrowthView: View {
    @EnvironmentObject var store: NoteStore

    var body: some View {
        let score = store.score
        let stage = score.stage()
        let fidelity = score.fidelity()
        let balance = score.axisBalance(over: store.axes)

        let counted = score.links.filter(\.isCounted)
        let cross = counted.filter(\.isCrossAxis).count
        let same = counted.count - cross
        let inPerson = counted.filter(\.isInPerson).count
        let realNotes = store.notes.filter { !$0.isStub && $0.categoryID != nil }.count

        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 12) {
                        AvatarOrb(balance: balance, axes: store.axes, fidelity: fidelity, size: 180)
                        Text(stage.name)
                            .font(.title2.weight(.semibold))
                        Text("Stage \(stage.index + 1) of \(Stage.ladder.count)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        ProgressView(value: fidelity)
                            .tint(dominantAxisColor(balance, axes: store.axes))
                            .padding(.horizontal, 40)
                    }
                    .padding(.top, 16)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Where you're growing")
                            .font(.headline)
                        ForEach(store.axes) { axis in
                            AxisRow(axis: axis,
                                    points: score.revealedTotals.points(axis.id),
                                    share: balance[axis.id] ?? 0)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your connections")
                            .font(.headline)
                        HStack(spacing: 10) {
                            StatTile(value: realNotes, label: "notes")
                            StatTile(value: cross, label: "cross-axis", highlight: true)
                            StatTile(value: same, label: "same-axis")
                            StatTile(value: inPerson, label: "in person")
                        }
                        Text("Cross-axis links — connecting different parts of your life — grow you the most.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if score.pendingTotal > 0 {
                        Label("New growth from your last session appears on your next visit.",
                              systemImage: "leaf")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .navigationTitle("Growth")
        }
    }
}

private struct AxisRow: View {
    let axis: Axis
    let points: Double
    let share: Double

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(axis.color).frame(width: 12, height: 12)
            Text(axis.name).frame(width: 66, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(axis.color.opacity(0.15)).frame(height: 8)
                    Capsule().fill(axis.color)
                        .frame(width: max(8, geo.size.width * share), height: 8)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 12)
            Text("\(Int(points.rounded()))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

private struct StatTile: View {
    let value: Int
    let label: String
    var highlight: Bool = false

    var body: some View {
        VStack(spacing: 4) {
            Text("\(value)").font(.title3.weight(.bold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            (highlight ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08)),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }
}
