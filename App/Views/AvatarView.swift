import SwiftUI
import NuminousCore

struct AvatarView: View {
    @EnvironmentObject var model: AppModel
    @State private var breathe = false

    var body: some View {
        let score = model.score
        let stage = score.stage()
        let fidelity = score.fidelity()
        let balance = score.axisBalance(over: model.axes)

        let counted = score.links.filter(\.isCounted)
        let cross = counted.filter(\.isCrossAxis).count
        let same = counted.count - cross
        let realNotes = model.notes.filter { !$0.isStub && model.axis(for: $0) != nil }.count

        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    AvatarFigure(balance: balance, axes: model.axes, fidelity: fidelity)
                        .scaleEffect(breathe ? 1.03 : 1.0)
                        .padding(.top, 24)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 6.5).repeatForever(autoreverses: true)) { breathe = true }
                        }

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
                        statTile("\(realNotes)", "notes", false)
                        statTile("\(cross)", "cross-axis", true)
                        statTile("\(same)", "same-axis", false)
                    }
                    .padding(.horizontal)

                    if score.pendingTotal > 0 {
                        Label("New growth appears on your next visit", systemImage: "leaf")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 30)
            }
            .navigationTitle("Numinous")
        }
    }

    private func dominantColor(_ b: AxisTotals) -> Color {
        (model.axes.max { (b[$0.id] ?? 0) < (b[$1.id] ?? 0) })?.color ?? .accentColor
    }

    private func statTile(_ value: String, _ label: String, _ hi: Bool) -> some View {
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

/// A smoothed, androgynous figure whose color cast reflects axis balance and
/// which sharpens (less blur, more opacity) as fidelity grows.
struct AvatarFigure: View {
    let balance: AxisTotals
    let axes: [Axis]
    let fidelity: Double

    var body: some View {
        LinearGradient(gradient: Gradient(stops: stops()), startPoint: .top, endPoint: .bottom)
            .mask(FigureShape())
            .frame(width: 150, height: 210)
            .opacity(0.3 + 0.7 * fidelity)
            .blur(radius: (1 - fidelity) * 4)
            .accessibilityLabel("Your avatar")
    }

    private func stops() -> [Gradient.Stop] {
        var out: [Gradient.Stop] = []
        var acc = 0.0
        for axis in axes {
            let f = balance[axis.id] ?? 0
            if f <= 0 { continue }
            out.append(.init(color: axis.color, location: acc))
            acc += f
            out.append(.init(color: axis.color, location: min(1, acc)))
        }
        if out.isEmpty {
            return [.init(color: .gray.opacity(0.5), location: 0), .init(color: .gray.opacity(0.5), location: 1)]
        }
        return out
    }
}

private struct FigureShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let sx = rect.width / 200, sy = rect.height / 280
        func e(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) {
            p.addEllipse(in: CGRect(x: (cx - rx) * sx, y: (cy - ry) * sy, width: 2 * rx * sx, height: 2 * ry * sy))
        }
        func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ rad: Double) {
            p.addRoundedRect(in: CGRect(x: x * sx, y: y * sy, width: w * sx, height: h * sy),
                             cornerSize: CGSize(width: rad * sx, height: rad * sy))
        }
        e(100, 34, 16, 20)       // head
        r(92, 50, 16, 13, 6)     // neck
        e(100, 96, 38, 33)       // chest / broad shoulders
        e(100, 132, 26, 26)      // waist
        e(100, 166, 33, 28)      // hips
        r(52, 74, 13, 98, 6)     // left arm
        r(135, 74, 13, 98, 6)    // right arm
        e(58, 174, 8, 12)        // left hand
        e(142, 174, 8, 12)       // right hand
        r(83, 186, 15, 90, 7)    // left leg
        r(102, 186, 15, 90, 7)   // right leg
        e(90, 277, 11, 7)        // left foot
        e(110, 277, 11, 7)       // right foot
        return p
    }
}
