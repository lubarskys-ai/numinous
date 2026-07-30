import SwiftUI
import NuminousCore

/// The Avatar tab, now the Graph+Avatar fusion: your figure woven from the
/// connection constellation, with stage, growth, and stats below. Tap a node
/// (a note) to open it.
struct AvatarView: View {
    @EnvironmentObject var model: AppModel
    @State private var path: [UUID] = []
    @State private var reflection: ReflectionRecord?

    var body: some View {
        let score = model.score
        let stage = score.stage()
        let fidelity = score.fidelity()
        let balance = score.axisBalance(over: model.axes)
        let counted = score.links.filter(\.isCounted)
        let cross = counted.filter(\.isCrossAxis).count
        let same = counted.count - cross
        let realNotes = model.notes.filter { !$0.isStub && model.axis(for: $0) != nil }.count

        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 20) {
                    ConstellationView(onTapNote: { path.append($0) })
                        .frame(height: 380)
                        .padding(.top, 8)

                    VStack(spacing: 4) {
                        Text(stage.name).font(.title2.weight(.semibold))
                        Text("Stage \(stage.index + 1) of \(Stage.ladder.count)")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }

                    ProgressView(value: fidelity)
                        .tint(dominantColor(balance))
                        .padding(.horizontal, 50)

                    HStack(spacing: 12) {
                        ForEach(model.axes) { axis in
                            VStack(spacing: 6) {
                                Capsule().fill(axis.color)
                                    .opacity(0.25 + 0.75 * (balance[axis.id] ?? 0))
                                    .frame(height: 6)
                                Text(axis.name).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal)

                    HStack(spacing: 10) {
                        stat("\(realNotes)", "notes", false)
                        stat("\(cross)", "cross-axis", true)
                        stat("\(same)", "same-axis", false)
                    }
                    .padding(.horizontal)

                    if let reflection {
                        reflectionCard(reflection, tint: dominantColor(balance))
                            .padding(.horizontal)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    if score.pendingTotal > 0 {
                        Label("New growth appears on your next visit", systemImage: "leaf")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 30)
            }
            .navigationTitle("Numinous")
            .navigationDestination(for: UUID.self) { id in NoteDetailView(noteID: id) }
            .onAppear { if reflection == nil { reflection = model.currentReflection() } }
        }
    }

    /// "Numinous noticed…" — the app reflecting a true pattern back to you.
    private func reflectionCard(_ record: ReflectionRecord, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text("Numinous noticed").font(.caption.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(tint)
            Text(record.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Got it") {
                    model.acknowledgeReflection(record)
                    withAnimation { reflection = model.currentReflection() }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
            }
        }
        .padding(16)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(tint.opacity(0.25)))
    }

    private func dominantColor(_ b: AxisTotals) -> Color {
        (model.axes.max { (b[$0.id] ?? 0) < (b[$1.id] ?? 0) })?.color ?? .accentColor
    }

    private func stat(_ value: String, _ label: String, _ hi: Bool) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title3.weight(.bold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(hi ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12))
    }
}
