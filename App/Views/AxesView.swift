import SwiftUI
import UIKit
import NuminousCore

/// Seven parts of a life, each alive in its own way and each coming into focus on its own.
///
/// PROTOTYPE. It renders `AppModel.axisMaturities()`, which the app already computes — every
/// region of the 3D avatar has always faded in on its own axis maturity. The only reason you
/// have never seen these seven numbers is that `maturity` averages them into one before
/// anything displays them. This doesn't measure anything new; it stops averaging.
///
/// Nothing drifts around the screen any more. Sliding a pixellated image across the display
/// resamples its blocks every frame, and no amount of slowing that down stopped it reading as
/// jitter. The life is in the subjects instead — a heart beats, an arm flexes — which is both
/// steadier and more alive than the whole field wandering.
///
/// Pan and pinch mirror `ConstellationView` exactly, because "move the world around" is a
/// gesture this app already has.
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

    @State private var picking: Axis?
    /// Prototype-only: `maturityFullPerAxis` is 480 links per axis, so a real vault sits near
    /// zero for a long time and the arc would be unjudgeable without this.
    @State private var preview: Double? = nil
    @State private var showScrubber = false

    private var zoom: CGFloat { min(4, max(0.7, scale * pinch)) }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                // Both computed ONCE per render. Reading maturity per form per frame meant
                // seven whole-graph scans thirty times a second, and re-deriving the images on
                // top of that; the animation only needs the transforms.
                let mats = preview == nil ? model.axisMaturities() : [:]
                let frames: [(axis: Axis, image: UIImage, size: CGFloat)] = model.axes.map { axis in
                    let m = preview ?? (mats[axis.id] ?? 0)
                    return (axis,
                            AxisArt.rendered(AxisArt.chosen(for: axis.id),
                                             tint: UIColor(axis.color), maturity: m),
                            diameter(m))
                }
                let fit = min(geo.size.width / dw, geo.size.height / dh)

                ZStack {
                    // The canvas takes the pan; each form takes its own drag, so pushing one
                    // around never slides the whole world with it.
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

                    TimelineView(.animation) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        // The ZStack is load-bearing. A bare ForEach as TimelineView's content
                        // is not stacked — the forms accumulate down the screen instead of
                        // sitting where .position puts them.
                        ZStack {
                            ForEach(Array(frames.enumerated()), id: \.element.axis.id) { index, f in
                                FloatingForm(axis: f.axis, image: f.image, size: f.size,
                                             base: Self.anchors[index % Self.anchors.count],
                                             t: t) { picking = f.axis }
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

    /// A soft wash of every axis at once, so the space the forms float in belongs to them.
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

    // MARK: - The forms

    /// Hand-placed scatter, not a grid — the point of the screen is that these are seven
    /// separate things, and a grid says "rows of the same thing".
    private static let anchors: [CGPoint] = [
        CGPoint(x: 98,  y: 74),
        CGPoint(x: 246, y: 150),
        CGPoint(x: 82,  y: 232),
        CGPoint(x: 252, y: 306),
        CGPoint(x: 96,  y: 386),
        CGPoint(x: 250, y: 452),
        CGPoint(x: 116, y: 516),
    ]

    /// No labels, so the forms can be bigger. A part of your life you have to read the name
    /// of isn't being shown to you, it's being reported to you — and the shape says which.
    private func diameter(_ m: Double) -> CGFloat { 100 + 46 * CGFloat(min(1, max(0, m))) }

    // MARK: - Motion

    struct Motion {
        var sx: CGFloat = 1
        var sy: CGFloat = 1
        var rot: Double = 0
        var dy: CGFloat = 0
    }

    /// Each part moves the way that part of a life moves. This is where the character lives
    /// now: a still symbol is a still symbol, but a heart that beats is a heart.
    static func motion(_ axisID: String, _ t: TimeInterval) -> Motion {
        switch axisID {
        case "heart":
            // Lub-dub, then rest. Two Gaussian pulses in a 1.5s cycle — a plain sine reads as
            // throbbing, not as a heartbeat, because the rest between beats is the whole tell.
            let p = t.truncatingRemainder(dividingBy: 1.5) / 1.5
            let lub = exp(-pow((p - 0.05) / 0.045, 2))
            let dub = exp(-pow((p - 0.19) / 0.055, 2)) * 0.62
            let k = CGFloat(lub + dub)
            return Motion(sx: 1 + 0.11 * k, sy: 1 + 0.11 * k)
        case "body":
            // A flex: one sharp squeeze every couple of seconds, not a constant wobble. sin^6
            // holds it at rest for most of the cycle, which is what makes it read as an effort.
            let p = t.truncatingRemainder(dividingBy: 2.2) / 2.2
            let e = CGFloat(pow(sin(p * .pi), 6))
            return Motion(sx: 1 + 0.06 * e, sy: 1 - 0.05 * e, rot: Double(-5 * e))
        case "mind":
            let k = CGFloat(sin(t / 1.7))
            return Motion(sx: 1 + 0.02 * k, sy: 1 + 0.02 * k, rot: sin(t / 3.4) * 1.5)
        case "gut":
            return Motion(rot: sin(t / 1.9) * 3.5)
        case "meaning":
            // Slow and geological — mountains shouldn't fidget.
            return Motion(sy: 1 + 0.015 * CGFloat(sin(t / 3.2)), dy: CGFloat(sin(t / 3.2)) * 3)
        case "influences":
            // A bob, as if spoken.
            let p = t.truncatingRemainder(dividingBy: 2.0) / 2.0
            return Motion(dy: -CGFloat(abs(sin(p * .pi))) * 5)
        case "spirit":
            let k = CGFloat(sin(t / 1.25))
            return Motion(sx: 1 + 0.06 * k, sy: 1 + 0.06 * k, rot: sin(t / 3.1) * 9)
        default:
            return Motion(sy: 1 + 0.02 * CGFloat(sin(t / 2.0)))
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

/// One floating form, owning its own drag.
///
/// This is a separate view for a reason that is entirely about smoothness: while the drag
/// lived on the parent, every touch event during a drag invalidated the parent's body, which
/// re-ran axisMaturities() over the whole graph and re-derived all seven images. Dragging was
/// the jerkiest thing on the screen because it was doing the most work. Here a drag touches
/// nothing but this one view.
private struct FloatingForm: View {
    let axis: Axis
    let image: UIImage
    let size: CGFloat
    let base: CGPoint
    let t: TimeInterval
    let onTap: () -> Void

    /// Where the user has pushed it. It stays where you put it.
    @State private var nudge: CGSize = .zero
    @GestureState private var live: CGSize = .zero

    var body: some View {
        let mv = AxesView.motion(axis.id, t)
        Image(uiImage: image)
            .resizable()
            // SMOOTH interpolation, deliberately. The blocks are baked into the bitmap, so
            // they stay blocks; what this changes is the RESAMPLING. With .none every block
            // edge snaps to a whole pixel, and under a moving transform each edge crosses its
            // boundary on its own frame — the blocks pop and crawl a pixel at a time.
            .interpolation(.high)
            .frame(width: size, height: size)
            .scaleEffect(x: mv.sx, y: mv.sy)
            .rotationEffect(.degrees(mv.rot))
            .offset(y: mv.dy)
            .contentShape(Rectangle())
            .position(x: base.x + nudge.width + live.width,
                      y: base.y + nudge.height + live.height)
            .onTapGesture { onTap() }
            .gesture(
                DragGesture(minimumDistance: 6)
                    .updating($live) { v, state, _ in state = v.translation }
                    .onEnded { v in
                        nudge.width += v.translation.width
                        nudge.height += v.translation.height
                    }
            )
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
