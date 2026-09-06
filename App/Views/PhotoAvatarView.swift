import SwiftUI
import NuminousCore

/// You, coming back into your own photograph.
///
/// The background is sharp from the first day — the wall, the sign, the hedge, whatever place
/// you chose. You are not. You return coarse and slowly, and NOT all at once: your head comes
/// into focus as Mind fills, the middle of your chest as Heart does, your limbs as Body does,
/// and Spirit gathers as a glow around the whole outline rather than a part of it.
///
/// That last one is the reason this beats the organ meshes it replaces. An organ was a labelled
/// part bolted onto a mannequin; this is your own head, in your own photograph, becoming clear
/// because you have been thinking. Nothing is added to you that was not already there.
struct PhotoAvatarView: View {
    let person: UIImage
    let anchors: PhotoAvatar.Anchors
    /// Per-axis maturity, 0…1.
    let maturity: (String) -> Double
    let spiritColor: Color
    /// Play the erasure once, on the way in.
    var introduce: Bool = false
    /// True while the intro is running, so opacity can behave differently than it does across
    /// the months.

    /// Runs 1 → 0 while the photograph comes apart. The effective maturity is the HIGHER of
    /// this and the real one, so the picture starts whole and falls to wherever your life has
    /// actually got to.
    @State private var undoing: Double = 0
    /// True from the moment the dissolve starts and never set back, so the screen HOLDS at
    /// the emptied photograph rather than snapping to the resting state at the end of it.
    @State private var running = false

    // Zoom and move the picture. A photograph chosen for a life is going to be looked at
    // closely — at a face coming back, at whether a hand has sharpened — and a fixed frame
    // makes that impossible on anything smaller than a wall.
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    private var scale: CGFloat { min(6, max(1, zoom * pinch)) }
    private var offset: CGSize {
        CGSize(width: pan.width + drag.width, height: pan.height + drag.height)
    }

    /// Take the picture apart, a frame at a time.
    ///
    /// `withAnimation` cannot do this. It animates a view's own animatable properties —
    /// opacity, position, scale — and a float handed to a SHADER is not one of them: it snaps
    /// to its final value the instant the state changes. So the first version faded you out
    /// slightly and never coarsened at all, which is exactly what "only progresses minimally"
    /// looks like.
    ///
    /// Stepping the value by hand gives the shader a new block size on every frame, which is
    /// the only way the coarsening is visible at all. Eased at both ends so it does not start
    /// or stop abruptly.
    /// Slower than feels sensible, because the whole point is the coming apart and not the
    /// arrival at an empty photograph. Nine seconds is long for an animation and about right
    /// for watching something be undone.
    private func comeApart(seconds: Double = 9.0, frames: Int = 200) async {
        running = true
        let step = UInt64(seconds / Double(frames) * 1_000_000_000)
        for frame in 0...frames {
            let t = Double(frame) / Double(frames)
            undoing = 1 - (t * t * (3 - 2 * t))
            try? await Task.sleep(nanoseconds: step)
        }
        // FREEZE AT THE FAREST POINT. Handing the screen back to the resting state the instant
        // the dissolve finished put a faint ghost of you back on the wall between one frame and
        // the next — the picture came apart beautifully and then flinched. Whatever you have
        // actually grown belongs to the next time this screen is opened, not to the last
        // quarter-second of watching yourself go.
        undoing = 0
    }

    /// What to draw: the real maturity, or the intro's, whichever is further along.
    private func showing(_ axis: String) -> Double {
        max(axis == "all" ? wholeLife() : maturity(axis), undoing)
    }

    /// The five maturities, in the order the shader deals its squares out.
    ///
    /// During the dissolve they are all driven together — the picture comes apart as one thing
    /// even though it comes back as five.
    private func axisValues() -> [Double] {
        ["mind", "heart", "body", "meaning", "spirit"].map { axis in
            max(maturity(axis), undoing)
        }
    }

    /// The regions are gone, so the axes are read as one number: the least-grown part of a
    /// life holds the whole picture back a little, which is truer to the idea than an average
    /// that lets a strong axis paper over an empty one.
    private func wholeLife() -> Double {
        let axes = ["mind", "heart", "body", "meaning", "spirit"]
        let values = axes.map { maturity($0) }
        let mean = values.reduce(0, +) / Double(values.count)
        let weakest = values.min() ?? 0
        return mean * 0.7 + weakest * 0.3
    }

    var body: some View {
        GeometryReader { geo in
            let fitted = fit(person.size, in: geo.size)
            ZStack {
                // BLACK, AND NOTHING ELSE. The photograph is gone — with it went the smears,
                // the dark patch where a torso had been, and the whole business of
                // reconstructing a wall. What is left is you, cropped close, at the size the
                // screen can actually give you.
                Color.black

                ZStack {
                    // Spirit gathers as a glow around the whole of you rather than in a part,
                    // because it is the one axis that is not anatomy. The fade goes on the
                    // COLOUR — putting it on the view makes SwiftUI draw the layer against
                    // black and composite the black in, which is what once put a dark oval on
                    // his chest.
                    spiritColor
                        .opacity(running
                                 ? 0.85 * min(1, max(0, (undoing - 0.07) * 3.0))
                                 : 0.85 * presence(maturity("spirit")))
                        .mask {
                            Image(uiImage: person).resizable().scaledToFit().blur(radius: 26)
                        }
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)

                    // ONE LAYER, AND EVERY SQUARE BELONGS TO AN AXIS.
                    //
                    // Two arrangements have failed here. Four anatomical regions stacked four
                    // copies of the person around the torso and made the middle dense and dark.
                    // One layer at one maturity fixed that and meant a single new link nudged
                    // the whole figure by an amount nobody could see — and made the per-axis
                    // sliders identical, because they all drove the same number.
                    //
                    // Neither is how a life fills in. It fills in unevenly, in patches. So each
                    // square is dealt an axis, scattered across the whole body rather than
                    // pooled in a region, and lights when its own axis passes the lot it was
                    // dealt. Mind fills Mind's squares wherever they fall; nothing overlaps,
                    // because a square has exactly one owner; and one connection is a handful
                    // of squares somewhere, which is a thing you can watch happen.
                    Image(uiImage: person)
                        .resizable().scaledToFit()
                        .scattered(maturities: axisValues(), side: fitted.width, seed: 7)
                        .opacity(visible("all"))
                }
                .frame(width: fitted.width, height: fitted.height)
                .scaleEffect(scale)
                .offset(offset)
                .contentShape(Rectangle())
                .gesture(
                    SimultaneousGesture(
                        MagnifyGesture().updating($pinch) { value, state, _ in
                            state = value.magnification
                        }.onEnded { value in
                            zoom = min(6, max(1, zoom * value.magnification))
                            if zoom == 1 { pan = .zero }
                        },
                        DragGesture().updating($drag) { value, state, _ in
                            state = value.translation
                        }.onEnded { value in
                            pan.width += value.translation.width
                            pan.height += value.translation.height
                        }))
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.25)) { zoom = 1; pan = .zero }
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            guard introduce else { return }
            Task { await comeApart() }
        }
    }

    /// The photograph's rectangle inside the screen, scaled to fit and centred.
    private func fit(_ size: CGSize, in box: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: box) }
        let scale = min(box.width / size.width, box.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    /// How much of you shows, right now.
    ///
    /// The intro needs the OPPOSITE curve to the months. Across a life, presence rises slowly
    /// from nothing, so a first few notes barely trouble the picture. During the dissolve it
    /// has to HOLD while the blocks swell — otherwise you are already too faint to see by the
    /// time the coarsening becomes dramatic, and the whole thing reads as a fade with some
    /// texture in it rather than as a picture coming apart.
    private func visible(_ axis: String) -> Double {
        // The freeze holds the emptied photograph after the dissolve; once it is over, what
        // shows is simply how far the life has actually got.
        guard running else {
            return presence(axis == "all" ? wholeLife() : maturity(axis))
        }
        // Zero a little BEFORE the run ends. Fading to nothing exactly at the last frame left
        // a few surviving cells twinkling out one at a time, which read as the effect finishing
        // untidily rather than finishing. The last stretch is empty on purpose.
        return min(1, max(0, (undoing - 0.07) * 3.0))
    }

    /// How much of you is there at all, as against how sharp that much is.
    ///
    /// Deliberately unhurried, and deliberately zero at zero. Squaring the early part means a
    /// first few notes barely trouble the picture — you arrive as something you are not sure
    /// you can see — and the middle of a life is where it becomes plainly you.
    private func presence(_ maturity: Double) -> Double {
        let m = min(1, max(0, maturity))
        return m * m * (3 - 2 * m) * 0.94 + m * 0.06
    }



    /// Vision reports the body with the origin at the BOTTOM left; SwiftUI draws from the top.
    /// Getting this backwards puts your head at your feet, which is the sort of thing that is
    /// obvious the moment you see it and invisible until then.
    private func unitPoint(_ p: CGPoint) -> UnitPoint {
        UnitPoint(x: p.x, y: 1 - p.y)
    }
}
