import SwiftUI
import UIKit
import NuminousCore

/// Seven parts of a life, drifting, each coming into focus on its own.
///
/// PROTOTYPE. It renders `AppModel.axisMaturities()`, which the app already computes —
/// every region of the 3D avatar has always faded in on its own axis maturity. The only
/// reason you have never seen these seven numbers is that `maturity` averages them into one
/// before anything displays them. This doesn't measure anything new; it stops averaging.
///
/// Pan, pinch and node-dragging deliberately mirror `ConstellationView` — same clamps, same
/// simultaneous gestures — because this is the same gesture in the user's hand as the graph,
/// and two different feels for "move the world around" would be one too many.
struct AxesView: View {
    @EnvironmentObject var model: AppModel

    // The field is a canvas of EXACTLY this size, scaled to fit whatever it is given.
    // `.position` inside an unsized ZStack resolves against a space that is not the
    // GeometryReader's, which is why two rounds of tuning kept leaving half the field below
    // the fold. With an explicit frame the coordinates mean what they say.
    private let dw: CGFloat = 340
    private let dh: CGFloat = 560

    // Canvas pan + pinch.
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    /// Where the user has pushed a disc, in design space. They stay where you put them.
    @State private var nudges: [String: CGSize] = [:]
    @GestureState private var dragging: (id: String, translation: CGSize)? = nil

    @State private var picking: Axis?
    /// Prototype-only: `maturityFullPerAxis` is 480 links per axis, so a real vault sits near
    /// zero for a long time and the arc would be unjudgeable without this.
    @State private var preview: Double? = nil
    @State private var showScrubber = false

    private var zoom: CGFloat { min(4, max(0.7, scale * pinch)) }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                // Once per render, not once per disc per frame.
                let mats = preview == nil ? model.axisMaturities() : [:]
                let fit = min(geo.size.width / dw, geo.size.height / dh)

                ZStack {
                    // The canvas itself takes the pan; discs take their own drags, so pushing
                    // one around never slides the whole world with it.
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 8)
                                .updating($drag) { v, state, _ in state = v.translation }
                                .onEnded { v in
                                    offset.width += v.translation.width
                                    offset.height += v.translation.height
                                }
                        )

                    // ONE timeline for the whole field, not one per disc: seven independent
                    // animation clocks were seven separate invalidation storms.
                    TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        // The ZStack is load-bearing. A bare ForEach as TimelineView's content
                        // is not stacked — the forms accumulate down the screen instead of
                        // sitting where .position puts them, which is why the field kept
                        // running off the bottom no matter how the coordinates were tuned.
                        ZStack {
                            ForEach(Array(model.axes.enumerated()), id: \.element.id) { index, axis in
                                let m = preview ?? (mats[axis.id] ?? 0)
                                form(axis, maturity: m)
                                    .position(place(index, axis: axis, t: t))
                            }
                        }
                    }
                }
                .frame(width: dw, height: dh)
                .scaleEffect(fit * zoom, anchor: .center)
                .frame(width: geo.size.width, height: geo.size.height)
                .offset(x: offset.width + drag.width, y: offset.height + drag.height)
                .simultaneousGesture(
                    MagnificationGesture()
                        .updating($pinch) { v, state, _ in state = v }
                        .onEnded { v in
                            scale = min(4, max(0.7, scale * v))
                            if scale <= 1.01 { offset = .zero }
                        }
                )
            }
            .background(backdrop)
            .navigationTitle("You")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { withAnimation { showScrubber.toggle() } } label: {
                        Image(systemName: "slider.horizontal.below.rectangle")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { if showScrubber { scrubber } }
            .sheet(item: $picking) { axis in
                AxisImagePicker(axis: axis, maturity: maturity(axis))
            }
        }
    }

    /// Only for the picker sheet — the field itself reads the whole set once per render.
    private func maturity(_ axis: Axis) -> Double {
        preview ?? (model.axisMaturities()[axis.id] ?? 0)
    }

    /// A soft wash of every axis at once, so the space the discs float in belongs to them.
    private var backdrop: some View {
        ZStack {
            Color(.systemBackground)
            ForEach(Array(model.axes.enumerated()), id: \.element.id) { i, axis in
                RadialGradient(colors: [axis.color.opacity(0.16), .clear],
                               center: UnitPoint(x: 0.5 + 0.42 * cos(Double(i) * 0.9),
                                                 y: 0.5 + 0.42 * sin(Double(i) * 1.3)),
                               startRadius: 0, endRadius: 260)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Placement and drift

    /// Hand-placed scatter in unit coordinates, not a grid — the point of the screen is that
    /// these are seven separate things, and a grid says "rows of the same thing". Kept clear
    /// of the very top and bottom so a form's label never lands under the tab bar.
    private static let anchors: [CGPoint] = [
        CGPoint(x: 96,  y: 62),
        CGPoint(x: 248, y: 140),
        CGPoint(x: 82,  y: 220),
        CGPoint(x: 250, y: 300),
        CGPoint(x: 92,  y: 378),
        CGPoint(x: 250, y: 444),
        CGPoint(x: 108, y: 496),
    ]

    private func place(_ index: Int, axis: Axis, t: TimeInterval) -> CGPoint {
        let base = Self.anchors[index % Self.anchors.count]
        let nudge = nudges[axis.id] ?? .zero
        let live = dragging?.id == axis.id ? (dragging?.translation ?? .zero) : .zero
        // A slow breath, not a jitter: ~5pt over the better part of half a minute, each on
        // its own period so the field never pulses in unison.
        let phase = Double(index) * 1.9
        let dx = CGFloat(sin(t / 19.0 + phase) * 5)
        let dy = CGFloat(cos(t / 26.0 + phase * 1.4) * 6)
        // Snapped to whole points. Pixel blocks moved across fractions of a point resample
        // every frame, and that shimmer is what read as shaky.
        return CGPoint(x: (base.x + nudge.width + live.width + dx).rounded(),
                       y: (base.y + nudge.height + live.height + dy).rounded())
    }

    /// Size carries growth too, quietly: a part you have barely touched is a small far-off
    /// thing, a grown one is close and present. Pixellation still does the real work.
    private func diameter(_ m: Double) -> CGFloat { 88 + 38 * CGFloat(min(1, max(0, m))) }

    private func form(_ axis: Axis, maturity m: Double) -> some View {
        let option = AxisArt.chosen(for: axis.id)
        let d = diameter(m)
        return VStack(spacing: 6) {
            Image(uiImage: AxisArt.rendered(option, tint: UIColor(axis.color), maturity: m))
                .resizable()
                .interpolation(.none)          // never let SwiftUI smooth the blocks away
                .frame(width: d, height: d)
                .shadow(color: axis.color.opacity(0.28), radius: 10, y: 5)
            VStack(spacing: 1) {
                Text(axis.name).font(.footnote.weight(.semibold))
                Text(readout(m)).font(.caption2).foregroundStyle(.secondary)
            }
            .fixedSize()
            .frame(height: 30)
        }
        .contentShape(Rectangle())
        .onTapGesture { picking = axis }
        .gesture(
            DragGesture(minimumDistance: 6)
                .updating($dragging) { v, state, _ in state = (axis.id, v.translation) }
                .onEnded { v in
                    var n = nudges[axis.id] ?? .zero
                    n.width += v.translation.width
                    n.height += v.translation.height
                    nudges[axis.id] = n
                }
        )
    }

    /// Words, not a percentage. A number invites you to farm it, which is the one thing this
    /// app is not for.
    private func readout(_ m: Double) -> String {
        switch m {
        case ..<0.02:  return "Nothing here yet"
        case ..<0.15:  return "Barely there"
        case ..<0.35:  return "Taking shape"
        case ..<0.60:  return "Coming through"
        case ..<0.85:  return "Nearly whole"
        default:       return "Whole"
        }
    }

    private var scrubber: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PROTOTYPE — PREVIEW GROWTH")
                .font(.caption2.weight(.semibold)).kerning(0.6).foregroundStyle(.tertiary)
            HStack {
                Slider(value: Binding(get: { preview ?? 0 }, set: { preview = $0 }), in: 0...1)
                Button("Real") { preview = nil }.font(.caption)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }
}

/// Pick the picture for one axis. Options are shown at that axis's CURRENT maturity, not
/// clear — you are choosing the thing you will actually be looking at for months.
private struct AxisImagePicker: View {
    @Environment(\.dismiss) private var dismiss
    let axis: Axis
    let maturity: Double

    @State private var chosen: String = ""

    private let columns = [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(AxisArt.options(for: axis.id)) { option in
                        Button {
                            AxisArt.choose(option, for: axis.id)
                            chosen = option.id
                        } label: {
                            VStack(spacing: 9) {
                                Image(uiImage: AxisArt.rendered(option, tint: UIColor(axis.color), maturity: maturity))
                                    .resizable()
                                    .interpolation(.none)
                                    .aspectRatio(1, contentMode: .fit)
                                    .padding(10)
                                    .background {
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .fill(chosen == option.id ? Color.accentColor.opacity(0.14) : .clear)
                                    }
                                Text(option.label).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
                Text("Shown as they look right now, at this part's current growth.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
            }
            .navigationTitle(axis.name)
            .navigationBarTitleDisplayMode(.inline)
            .background(Color(.systemGroupedBackground))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { chosen = AxisArt.chosen(for: axis.id).id }
        }
    }
}
