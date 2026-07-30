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

    // Pinch-to-zoom + pan. Labels fade in as you zoom past ~1.4×.
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    private var zoom: CGFloat { min(5, max(1, scale * pinch)) }
    private func labelOpacity() -> Double { Double(min(1, max(0, (zoom - 1.4) / 0.6))) }

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
                if labelOpacity() > 0.01 {
                    ForEach(placement.nodes) { node in
                        Text(node.name)
                            .font(.system(size: 7, weight: .medium))
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(.regularMaterial, in: Capsule())
                            .fixedSize()
                            .position(x: map(node.point).x, y: map(node.point).y + 12)
                            .opacity(labelOpacity())
                            .allowsHitTesting(false)
                    }
                }
            }
            .scaleEffect(zoom, anchor: .center)
            .offset(x: offset.width + drag.width, y: offset.height + drag.height)
            .simultaneousGesture(
                MagnificationGesture()
                    .updating($pinch) { value, state, _ in state = value }
                    .onEnded { value in
                        scale = min(5, max(1, scale * value))
                        if scale <= 1.01 { offset = .zero }
                    }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .updating($drag) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        offset.width += value.translation.width
                        offset.height += value.translation.height
                    }
            )
            .contentShape(Rectangle())
        }
    }

    // MARK: - Placement

    private struct PlacedNode: Identifiable { let id: UUID; let point: CGPoint; let color: Color; let name: String }
    private struct Placement { var nodes: [PlacedNode]; var points: [UUID: CGPoint] }

    /// Anchor per axis in design space (where that axis's nodes cluster).
    private func anchor(_ axisID: String) -> CGPoint {
        switch axisID {
        case "mind": return CGPoint(x: 89, y: 40)       // left brain
        case "meaning": return CGPoint(x: 111, y: 40)   // right brain
        case "heart": return CGPoint(x: 100, y: 104)
        case "body": return CGPoint(x: 100, y: 210)
        case "spirit": return CGPoint(x: 100, y: 145)   // core
        case "gut": return CGPoint(x: 100, y: 170)      // belly
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
                nodes.append(PlacedNode(id: note.id, point: p, color: axis.color, name: note.displayName))
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
        // Neutral aura backdrop — the whole figure brightens with total growth.
        let aura = min(0.20, 0.05 + model.score.revealedTotal / 4500)
        ctx.fill(ellipse(100, 150, 92, 138).path.applying(mapTransform(map)), with: .color(.secondary.opacity(aura)))
        // body: limbs + hips + neck
        var body = Path()
        body.addPath(ellipse(100, 178, 30, 26).path)   // hips
        body.addPath(rect(52, 86, 13, 96))             // arms
        body.addPath(rect(135, 86, 13, 96))
        body.addPath(rect(83, 190, 14, 92))            // legs
        body.addPath(rect(103, 190, 14, 92))
        body.addPath(rect(92, 56, 16, 16))             // neck
        region(body, "body")
        // spirit: the core
        region(ellipse(100, 145, 22, 20).path, "spirit")
        // gut: the belly
        region(ellipse(100, 170, 24, 16).path, "gut")
        // heart: chest
        region(ellipse(100, 104, 36, 32).path, "heart")
        // bicameral brain: mind (left hemisphere) + meaning (right hemisphere)
        region(ellipse(90, 40, 13, 22).path, "mind")
        region(ellipse(110, 40, 13, 22).path, "meaning")
    }

    private func drawEdges(_ ctx: GraphicsContext, placement: Placement, map: (CGPoint) -> CGPoint) {
        for link in model.score.links where link.isCounted {
            guard let a = placement.points[link.a], let b = placement.points[link.b] else { continue }
            let pa = map(a), pb = map(b)
            // A gently bowed path (organic, dendrite-like) with a soft glow.
            var path = Path()
            path.move(to: pa)
            let dx = pb.x - pa.x, dy = pb.y - pa.y
            let control = CGPoint(x: (pa.x + pb.x) / 2 - dy * 0.14, y: (pa.y + pb.y) / 2 + dx * 0.14)
            path.addQuadCurve(to: pb, control: control)
            let color = link.isCrossAxis ? Color.accentColor : Color.secondary
            ctx.stroke(path, with: .color(color.opacity(0.14)), lineWidth: link.isCrossAxis ? 5 : 3.5)
            ctx.stroke(path, with: .color(color.opacity(link.isCrossAxis ? 0.7 : 0.35)), lineWidth: link.isCrossAxis ? 1.5 : 1)
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
