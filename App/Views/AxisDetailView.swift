import SwiftUI
import UIKit
import NuminousCore

/// One part of a life, on its own page, reached from its own name in Setup.
///
/// The alternative — all seven floating on one canvas — costs more than it looks. Seven live
/// shader passes have to be composited and transformed together, which is where every round
/// of jerkiness came from, and it needs a whole field of its own with pan, pinch, hand-placed
/// anchors and hit-testing above a flattened layer. One at a time, none of that exists: a
/// single small view, nothing over it, nothing to re-rasterise.
///
/// What it gives up is comparison — you can't see at a glance that Heart is ahead of Spirit.
/// What it gains is room: the picture can be big enough to actually read, which on a real
/// vault it never was at 100pt in a field of seven.
struct AxisDetailView: View {
    @EnvironmentObject var model: AppModel
    let axis: Axis

    @State private var chosen: String = ""
    /// Prototype-only, as on the field: `maturityFullPerAxis` is 480 links per axis, so a
    /// real vault sits near zero and the arc would be unjudgeable without it.
    @State private var preview: Double? = nil

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    private var maturity: Double { preview ?? (model.axisMaturities()[axis.id] ?? 0) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                Divider().padding(.vertical, 26)
                options
                scrubber
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .background(backdrop)
        .navigationTitle(axis.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { chosen = AxisArt.chosen(for: axis.id).id }
    }

    // MARK: - Hero

    private var hero: some View {
        let option = AxisArt.chosen(for: axis.id)
        let m = maturity
        return VStack(spacing: 16) {
            TimelineView(.animation) { timeline in
                let mv = AxesView.motion(axis.id, timeline.date.timeIntervalSinceReferenceDate)
                Image(uiImage: AxisArt.artwork(option)
                        ?? AxisArt.source(option, tint: UIColor(axis.color)))
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: 190, height: 190)
                    .resolving(maturity: m, side: 190,
                               seed: Double(abs(axis.id.hashValue % 997)))
                    .scaleEffect(x: mv.sx, y: mv.sy)
                    .rotationEffect(.degrees(mv.rot))
                    .offset(y: mv.dy)
            }
            .frame(height: 210)

            Text(AxisState.words(for: m))
                .font(.title3).fontDesign(.serif)
            Text(AxisState.explanation(for: m, axis: axis.name))
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .padding(.top, 18)
    }

    // MARK: - Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("WHAT IT LOOKS LIKE")
                .font(.caption2.weight(.semibold)).kerning(0.8).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(AxisArt.options(for: axis.id)) { option in
                    Button {
                        AxisArt.choose(option, for: axis.id)
                        chosen = option.id
                    } label: {
                        VStack(spacing: 8) {
                            // Whole, not at current growth. Early on every option is the same
                            // smudge, and you cannot choose between pictures you can't see.
                            Image(uiImage: AxisArt.artwork(option)
                                    ?? AxisArt.source(option, tint: UIColor(axis.color)))
                                .resizable()
                                .interpolation(.medium)
                                .aspectRatio(1, contentMode: .fit)
                                .padding(12)
                                .background {
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(chosen == option.id ? axis.color.opacity(0.16) : .clear)
                                }
                            Text(option.label).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var scrubber: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider().padding(.vertical, 24)
            Text("PROTOTYPE — PREVIEW GROWTH")
                .font(.caption2.weight(.semibold)).kerning(0.6).foregroundStyle(.tertiary)
            HStack {
                Slider(value: Binding(get: { preview ?? 0 }, set: { preview = $0 }), in: 0...1)
                Button("Real") { preview = nil }.font(.caption)
            }
        }
    }

    private var backdrop: some View {
        ZStack {
            Color(.systemGroupedBackground)
            RadialGradient(colors: [axis.color.opacity(0.18), .clear],
                           center: .init(x: 0.5, y: 0.22), startRadius: 0, endRadius: 340)
        }
        .ignoresSafeArea()
    }
}

/// How far along a part of a life is, in words rather than a percentage — a number invites
/// you to farm it, which is the one thing this app is not for.
enum AxisState {
    static func words(for m: Double) -> String {
        switch m {
        case ..<0.02:  return "Nothing here yet"
        case ..<0.15:  return "Barely there"
        case ..<0.35:  return "Taking shape"
        case ..<0.60:  return "Coming through"
        case ..<0.85:  return "Nearly whole"
        default:       return "Whole"
        }
    }

    static func explanation(for m: Double, axis: String) -> String {
        switch m {
        case ..<0.02:  return "Nothing you've written has touched \(axis) yet. It comes into focus as you live it."
        case ..<0.35:  return "\(axis) has started. The more of your life connects here, the clearer this gets."
        case ..<0.85:  return "\(axis) is well underway — most of the picture is there."
        default:       return "\(axis) is as clear as it gets."
        }
    }
}
