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
    let background: UIImage
    let person: UIImage
    let anchors: PhotoAvatar.Anchors
    /// Per-axis maturity, 0…1.
    let maturity: (String) -> Double
    let spiritColor: Color
    /// Play the erasure once, on the way in.
    var introduce: Bool = false
    /// Overrides the real maturities while the rebuild is being worked on. Nil in normal use.
    var preview: [String: Double]? = nil
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
        max(preview?[axis] ?? maturity(axis), undoing)
    }

    var body: some View {
        GeometryReader { geo in
            // THE WHOLE PHOTOGRAPH, not a slice of its middle.
            //
            // scaledToFill blows a landscape picture up until its HEIGHT covers a portrait
            // screen, which throws away most of its width — a man standing at the left of the
            // frame came out as a close-up of his arm. The picture is the point here: it is a
            // place you chose, and it has to be seen whole.
            //
            // Everything is then laid out inside that fitted rectangle, so the head and chest
            // anchors line up with the photograph rather than with the screen.
            let fitted = fit(background.size, in: geo.size)
            ZStack {
                // The letterbox is filled with an out-of-focus copy of the picture, so the
                // screen is of a place rather than a photo on a black card.
                Image(uiImage: background)
                    .resizable().scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped().blur(radius: 34).opacity(0.5)
                    .overlay(Color.black.opacity(0.35))

                ZStack {
                    Image(uiImage: background)
                        .resizable().scaledToFit()

                    // Spirit is not a body part, so it is not drawn as one: a glow gathering
                    // around the whole of you, present before any of you is.
                    Image(uiImage: person)
                        .resizable().scaledToFit()
                        .blur(radius: 26)
                        .blendMode(.plusLighter)
                        .opacity(running ? 0.46 * min(1, max(0, (undoing - 0.07) * 3.0))
                                         : 0.46 * presence(preview?["spirit"] ?? maturity("spirit")))
                        .foregroundStyle(spiritColor)
                        .allowsHitTesting(false)

                    // Each region is the same picture of you, coarsened by its own axis and
                    // shown only where that region is. They overlap softly, so no seam shows
                    // between a head that has grown and a chest that has not.
                    ForEach(regions, id: \.axis) { region in
                        // COARSEN SOMETHING OPAQUE, then cut your shape out of it.
                        //
                        // Coarsening the cut-out directly does not work, and this is why the
                        // blocks never looked like blocks: the filter averages the transparent
                        // pixels around you along with you. Every block came out part-alpha, so
                        // a coarse setting produced a uniformly see-through smudge instead of
                        // big squares — faint, which is exactly what "blurring minimal at best"
                        // looks like.
                        //
                        // Laying you over the background first gives the filter something solid
                        // to work on. The blocks are then real blocks, and your outline is
                        // taken out of them afterwards, so the photograph around you stays as
                        // sharp as it ever was.
                        ZStack {
                            Image(uiImage: background).resizable().scaledToFit()
                            Image(uiImage: person).resizable().scaledToFit()
                        }
                        .resolving(maturity: showing(region.axis), side: fitted.width,
                                   seed: region.seed, blocksAtZero: 9)
                        .mask {
                            // COARSEN THE OUTLINE TOO. Cutting blocks out with a sharp
                            // silhouette leaves a crisp edge with a mosaic inside it, and a
                            // crisp edge reads as a person who is present — just oddly
                            // textured. Running the same effect over the mask breaks the
                            // outline into the same squares, so you actually come apart at the
                            // edges rather than staying a neat cut-out full of pixels.
                            Image(uiImage: person)
                                .resizable().scaledToFit()
                                .resolving(maturity: showing(region.axis), side: fitted.width,
                                           seed: region.seed, blocksAtZero: 9)
                        }
                        .opacity(visible(region.axis))
                        .mask {
                            RadialGradient(
                                colors: [.white, .white.opacity(0.85), .clear],
                                center: unitPoint(region.centre),
                                startRadius: 0,
                                endRadius: fitted.height * region.reach
                                    * max(0.35, anchors.height))
                        }
                    }
                }
                .frame(width: fitted.width, height: fitted.height)
                .scaleEffect(scale)
                .offset(offset)
                .clipped()
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
                // Back to the whole picture, without hunting for the exact pinch that
                // gets there.
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.25)) { zoom = 1; pan = .zero }
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            // WATCH YOURSELF GO. Arriving at an empty photograph explains nothing — it looks
            // like a picture of a wall. Coming apart, once, in front of you says what the
            // screen is for and what the months ahead are going to undo.
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
        guard running else { return presence(preview?[axis] ?? maturity(axis)) }
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

    private struct Region { let axis: String; let centre: CGPoint; let reach: CGFloat; let seed: Double }

    /// Which axis owns which part of you. Read off the body the phone actually found in your
    /// photograph, so it is your head and your chest — not a rectangle's top third.
    private var regions: [Region] {
        [
            Region(axis: "mind", centre: anchors.head, reach: 0.42, seed: 3),
            Region(axis: "heart", centre: anchors.chest, reach: 0.52, seed: 17),
            // Body is the whole standing frame rather than a spot: legs, arms, the lot. Anchored
            // at the hips, which is where a body's mass actually sits.
            Region(axis: "body", centre: anchors.hip, reach: 1.15, seed: 29),
            Region(axis: "meaning", centre: CGPoint(x: anchors.neck.x, y: anchors.neck.y), reach: 0.75, seed: 41),
        ]
    }

    /// Vision reports the body with the origin at the BOTTOM left; SwiftUI draws from the top.
    /// Getting this backwards puts your head at your feet, which is the sort of thing that is
    /// obvious the moment you see it and invisible until then.
    private func unitPoint(_ p: CGPoint) -> UnitPoint {
        UnitPoint(x: p.x, y: 1 - p.y)
    }
}
