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

    /// Memoised against `model.revision`, which AppModel documents as the way to hold
    /// expensive derived collections: axisMaturities() walks every link, and recomputing it
    /// inside a gesture-driven body meant a full graph scan per frame of every pan and pinch.
    @State private var mats: [String: Double] = [:]
    @State private var matsRevision: Int = -1

    @State private var picking: Axis?
    /// Prototype-only: `maturityFullPerAxis` is 480 links per axis, so a real vault sits near
    /// zero for a long time and the arc would be unjudgeable without this.
    @State private var preview: Double? = nil
    @State private var showScrubber = false

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let frames: [AxisFrame] = model.axes.map { axis in
                    let option = AxisArt.chosen(for: axis.id)
                    let m = preview ?? (mats[axis.id] ?? 0)
                    // Full fidelity, always. The blocks and the dissolve are a shader now, so
                    // nothing is pre-rendered per maturity and the source can be a bought icon
                    // (or eventually a running animation) rather than only what we can draw.
                    return AxisFrame(axis: axis,
                                     image: AxisArt.artwork(option)
                                         ?? AxisArt.source(option, tint: UIColor(axis.color)),
                                     maturity: m,
                                     size: diameter(m))
                }
                AxesField(frames: frames,
                          fit: min(geo.size.width / dw, geo.size.height / dh),
                          canvas: CGSize(width: dw, height: dh),
                          viewport: geo.size) { picking = $0 }
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
            .onAppear { refreshMaturities() }
            .onChange(of: model.revision) { _ in refreshMaturities() }
        }
    }

    private func refreshMaturities() {
        guard matsRevision != model.revision else { return }
        mats = model.axisMaturities()
        matsRevision = model.revision
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
    static let anchors: [CGPoint] = [
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

/// One form's ingredients, computed by the parent and handed down as plain values so the
/// field can pan and zoom without anything recomputing.
struct AxisFrame: Identifiable {
    let axis: Axis
    let image: UIImage
    let maturity: Double
    let size: CGFloat
    var id: String { axis.id }
}

/// The pannable, zoomable field.
///
/// This is a separate view for the same reason FloatingForm is: while pan and pinch lived on
/// the parent, every frame of every gesture invalidated the parent's body, which walked the
/// whole graph for maturities and re-derived all seven images. The gesture was paying for a
/// full recomputation of the screen on every touch event. Here it owns its own state and the
/// frames arrive as finished values, so a pan moves pixels and nothing else.
private struct AxesField: View {
    let frames: [AxisFrame]
    let fit: CGFloat
    let canvas: CGSize
    let viewport: CGSize
    let onPick: (Axis) -> Void

    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    private var zoom: CGFloat { min(4, max(0.7, scale * pinch)) }
    private var gesturing: Bool { pinch != 1 || drag != .zero }

    var body: some View {
        ZStack {
            // The canvas takes the pan; each form takes its own drag, so pushing one around
            // never slides the whole world with it.
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

            // Pause the breathing WHILE a gesture is live. Measured at ~14% CPU during a
            // pinch, so this was never CPU-bound: the cost is the renderer resampling seven
            // images every frame against a scale that is also changing every frame. Paused,
            // the content is identical frame to frame and a pinch becomes a transform applied
            // to something already drawn. Nobody is watching a heart beat while they zoom.
            TimelineView(.animation(minimumInterval: nil, paused: gesturing)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                // The ZStack is load-bearing. A bare ForEach as TimelineView's content is not
                // stacked — the forms accumulate down the screen instead of sitting where
                // .position puts them.
                ZStack {
                    ForEach(Array(frames.enumerated()), id: \.element.id) { index, f in
                        FloatingForm(axis: f.axis, image: f.image, maturity: f.maturity,
                                     size: f.size,
                                     base: AxesView.anchors[index % AxesView.anchors.count],
                                     t: t) { onPick(f.axis) }
                    }
                }
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        // Flatten the field to ONE texture before the zoom touches it. Each form carries a
        // layerEffect, which is an offscreen pass of its own; scaling seven of those live
        // meant re-rasterising seven effects on every frame of a pinch. Rasterised once, a
        // pinch scales a single already-drawn texture — and since the breathing pauses during
        // a gesture, that texture doesn't change while you are moving it.
        .drawingGroup()
        .scaleEffect(fit * zoom, anchor: .center)
        .frame(width: viewport.width, height: viewport.height)
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
    let maturity: Double
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
            // Smooth: the picture underneath is full fidelity now, and the blocks are cut by
            // the shader at exactly the right size. Nearest-neighbour here would only fight it.
            .interpolation(.medium)
            .frame(width: size, height: size)
            .resolving(maturity: maturity, side: size,
                       seed: Double(abs(axis.id.hashValue % 997)))
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
                                Image(uiImage: AxisArt.artwork(option)
                                        ?? AxisArt.source(option, tint: UIColor(axis.color)))
                                    .resizable()
                                    .interpolation(.medium)
                                    .aspectRatio(1, contentMode: .fit)
                                    .frame(width: 120, height: 120)
                                    .resolving(maturity: maturity, side: 120,
                                               seed: Double(abs(option.id.hashValue % 997)))
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
