import SwiftUI
import NuminousCore

/// The Avatar tab: just the figure, woven from your connection constellation —
/// the avatar speaks for itself. Tap a node (a note) to open it. A gentle
/// "Numinous noticed…" reflection may sit beneath it.
struct AvatarView: View {
    @EnvironmentObject var model: AppModel
    @State private var path: [UUID] = []
    @State private var reflection: ReflectionRecord?
    @State private var show3D = false

    var body: some View {
        let balance = model.score.axisBalance(over: model.axes)

        NavigationStack(path: $path) {
            VStack(spacing: 12) {
                ConstellationView(onTapNote: { path.append($0) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let reflection {
                    reflectionCard(reflection, tint: dominantColor(balance))
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .navigationTitle("Numinous")
            .navigationDestination(for: UUID.self) { id in NoteDetailView(noteID: id) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { show3D = true } label: { Image(systemName: "rotate.3d") }
                        .accessibilityLabel("3D preview")
                }
            }
            .sheet(isPresented: $show3D) { Avatar3DScreen() }
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
}
