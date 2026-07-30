import SwiftUI
import NuminousCore

/// The connections map: notes as dots (colored by axis), links as lines,
/// cross-axis links drawn in the accent color. The 2D seed of the eventual
/// 3D graph-that-morphs-into-the-avatar.
struct GraphView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Canvas { context, size in
                    draw(context, in: size)
                }
                .frame(height: 340)
                .padding()

                Text("Each dot is a note; each line is a [[link]]. Cross-axis links (accent) grow you the most.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Spacer()
            }
            .navigationTitle("Connections")
        }
    }

    private struct Node {
        let id: UUID
        let point: CGPoint
        let color: Color
        let label: String
    }

    private func orderedNotes() -> [Note] {
        let order: [String: Int] = ["body": 0, "mind": 1, "heart": 2, "spirit": 3]
        return model.notes.sorted { a, b in
            let oa = order[model.axis(for: a)?.id ?? ""] ?? 4
            let ob = order[model.axis(for: b)?.id ?? ""] ?? 4
            if oa != ob { return oa < ob }
            return a.title < b.title
        }
    }

    private func layout(in size: CGSize) -> [Node] {
        let notes = orderedNotes()
        guard !notes.isEmpty else { return [] }
        let cx = size.width / 2
        let cy = size.height / 2
        let radius = min(size.width, size.height) / 2 - 42
        let count = Double(notes.count)
        var result: [Node] = []
        for (index, note) in notes.enumerated() {
            let angle = Double(index) / count * 2 * Double.pi - Double.pi / 2
            let x = cx + radius * CGFloat(cos(angle))
            let y = cy + radius * CGFloat(sin(angle))
            let color: Color = model.axis(for: note)?.color ?? Color.gray
            result.append(Node(id: note.id, point: CGPoint(x: x, y: y), color: color, label: note.displayName))
        }
        return result
    }

    private func draw(_ context: GraphicsContext, in size: CGSize) {
        let nodes = layout(in: size)
        guard !nodes.isEmpty else { return }
        var positions: [UUID: CGPoint] = [:]
        for node in nodes { positions[node.id] = node.point }
        for link in model.score.links { drawEdge(context, link: link, positions: positions) }
        for node in nodes { drawNode(context, node: node) }
    }

    private func drawEdge(_ context: GraphicsContext, link: ScoredLink, positions: [UUID: CGPoint]) {
        guard let p = positions[link.a], let q = positions[link.b] else { return }
        var path = Path()
        path.move(to: p)
        path.addLine(to: q)
        let cross = link.isCrossAxis && link.isCounted
        let color: Color = cross ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.35)
        let width: CGFloat = cross ? 1.7 : 1.0
        context.stroke(path, with: .color(color), lineWidth: width)
    }

    private func drawNode(_ context: GraphicsContext, node: Node) {
        let rect = CGRect(x: node.point.x - 5, y: node.point.y - 5, width: 10, height: 10)
        context.fill(Path(ellipseIn: rect), with: .color(node.color))
        let label = Text(node.label).font(.system(size: 8)).foregroundColor(.secondary)
        context.draw(label, at: CGPoint(x: node.point.x, y: node.point.y + 14))
    }
}
