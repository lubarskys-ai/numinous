import SwiftUI
import NuminousCore

/// The Graph + Avatar fusion: the figure drawn from your connection web. Each
/// note is a node clustered near its axis's body region; links arc between them
/// (cross-axis in accent); the figure's regions glow with that axis's growth.
/// Tap a node to open it.
struct ConstellationView: View {
    @EnvironmentObject var model: AppModel
    var onTapNote: (UUID) -> Void

    // Design space (matches the standalone figure); scaled to fit.
    private let dw: CGFloat = 200
    private let dh: CGFloat = 300

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width / dw, geo.size.height / dh)
            let ox = (geo.size.width - dw * s) / 2
            let oy = (geo.size.height - dh * s) / 2
            let map: (CGPoint) -> CGPoint = { CGPoint(x: ox + $0.x * s, y: oy + $0.y * s) }
            let placement = nodePlacements()

            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    drawFigure(ctx, map: map)
                    drawEdges(ctx, placement: placement, map: map)
                }
                ForEach(placement.nodes) { node in
                    Button { onTapNote(node.id) } label: {
                        Circle().fill(node.color)
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(.background, lineWidth: 1.5))
                    }
                    .position(map(node.point))
                }
            }
        }
    }

    // MARK: - Placement

    private struct PlacedNode: Identifiable { let id: UUID; let point: CGPoint; let color: Color }
    private struct Placement { var nodes: [PlacedNode]; var points: [UUID: CGPoint] }

    /// Anchor per axis in design space (where that axis's nodes cluster).
    private func anchor(_ axisID: String) -> CGPoint {
        switch axisID {
        case "mind": return CGPoint(x: 100, y: 40)
        case "heart": return CGPoint(x: 100, y: 104)
        case "body": return CGPoint(x: 100, y: 210)
        case "spirit": return CGPoint(x: 100, y: 150)   // aura / whole-body
        default: return CGPoint(x: 100, y: 150)
        }
    }

    private func nodePlacements() -> Placement {
        var nodes: [PlacedNode] = []
        var points: [UUID: CGPoint] = [:]
        let golden = 2.399963  // golden angle → even, organic phyllotaxis fill
        for (axisIndex, axis) in model.axes.enumerated() {
            let axisNotes = model.notes.filter { !$0.isStub && model.axis(for: $0)?.id == axis.id }
            let a = anchor(axis.id)
            let phase = Double(axisIndex) * 1.2
            for (i, note) in axisNotes.enumerated() {
                let radius = 15 * CGFloat((Double(i)).squareRoot())   // node 0 sits on the region
                let angle = CGFloat(Double(i) * golden + phase)
                let p = CGPoint(x: a.x + radius * cos(angle), y: a.y + radius * sin(angle) * 0.9)
                points[note.id] = p
                nodes.append(PlacedNode(id: note.id, point: p, color: axis.color))
            }
        }
        return Placement(nodes: nodes, points: points)
    }

    // MARK: - Drawing

    private func drawFigure(_ ctx: GraphicsContext, map: (CGPoint) -> CGPoint) {
        func fill(_ axisID: String) -> Double {
            min(1, model.score.revealedTotals.points(axisID) / 150)
        }
        func region(_ path: Path, _ axisID: String) {
            let color = model.axis(id: axisID)?.color ?? .gray
            ctx.fill(path.applying(mapTransform(map)), with: .color(color.opacity(0.12 + 0.35 * fill(axisID))))
        }
        // aura (spirit)
        region(ellipse(100, 150, 92, 138).path, "spirit")
        // body: torso + limbs + hips
        var body = Path()
        body.addPath(ellipse(100, 178, 30, 26).path)
        body.addPath(rect(52, 86, 13, 96))
        body.addPath(rect(135, 86, 13, 96))
        body.addPath(rect(83, 190, 14, 92))
        body.addPath(rect(103, 190, 14, 92))
        region(body, "body")
        // heart: chest
        region(ellipse(100, 104, 36, 32).path, "heart")
        // mind: head + neck
        var mind = Path()
        mind.addPath(ellipse(100, 40, 18, 22).path)
        mind.addPath(rect(92, 56, 16, 14))
        region(mind, "mind")
    }

    private func drawEdges(_ ctx: GraphicsContext, placement: Placement, map: (CGPoint) -> CGPoint) {
        for link in model.score.links where link.isCounted {
            guard let a = placement.points[link.a], let b = placement.points[link.b] else { continue }
            let pa = map(a), pb = map(b)
            var path = Path()
            path.move(to: pa)
            let mid = CGPoint(x: (pa.x + pb.x) / 2, y: (pa.y + pb.y) / 2)
            path.addQuadCurve(to: pb, control: mid)
            ctx.stroke(path,
                       with: .color(link.isCrossAxis ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.3)),
                       lineWidth: link.isCrossAxis ? 1.4 : 1)
        }
    }

    // MARK: - Path helpers (design space)

    private struct E { let cx, cy, rx, ry: CGFloat; var path: Path { Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: 2 * rx, height: 2 * ry)) } }
    private func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> E { E(cx: cx, cy: cy, rx: rx, ry: ry) }
    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: min(w, h) / 2)
    }
    private func mapTransform(_ map: (CGPoint) -> CGPoint) -> CGAffineTransform {
        let o = map(CGPoint(x: 0, y: 0)), u = map(CGPoint(x: 1, y: 0)), v = map(CGPoint(x: 0, y: 1))
        return CGAffineTransform(a: u.x - o.x, b: u.y - o.y, c: v.x - o.x, d: v.y - o.y, tx: o.x, ty: o.y)
    }
}
