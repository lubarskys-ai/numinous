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
                Canvas { ctx, size in
                    let ns = orderedNotes()
                    guard !ns.isEmpty else { return }
                    let cx = size.width / 2, cy = size.height / 2
                    let radius = min(size.width, size.height) / 2 - 42
                    var pos: [UUID: CGPoint] = [:]
                    for (i, n) in ns.enumerated() {
                        let ang = Double(i) / Double(ns.count) * 2 * .pi - .pi / 2
                        pos[n.id] = CGPoint(x: cx + radius * cos(ang), y: cy + radius * sin(ang))
                    }

                    for link in model.score.links {
                        guard let p = pos[link.a], let q = pos[link.b] else { continue }
                        var path = Path(); path.move(to: p); path.addLine(to: q)
                        let cross = link.isCrossAxis && link.isCounted
                        ctx.stroke(path,
                                   with: .color(cross ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.35)),
                                   lineWidth: cross ? 1.7 : 1)
                    }

                    for n in ns {
                        guard let p = pos[n.id] else { continue }
                        let color = model.axis(for: n)?.color ?? Color.gray
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)),
                                 with: .color(color))
                        ctx.draw(Text(n.displayName).font(.system(size: 8)).foregroundColor(.secondary),
                                 at: CGPoint(x: p.x, y: p.y + 14))
                    }
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

    private func orderedNotes() -> [Note] {
        let order = ["body": 0, "mind": 1, "heart": 2, "spirit": 3]
        return model.notes.sorted { a, b in
            let oa = order[model.axis(for: a)?.id ?? ""] ?? 4
            let ob = order[model.axis(for: b)?.id ?? ""] ?? 4
            if oa != ob { return oa < ob }
            return a.title < b.title
        }
    }
}
