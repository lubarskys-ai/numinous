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

    /// Runs 1 → 0 while the photograph comes apart. The effective maturity is the HIGHER of
    /// this and the real one, so the picture starts whole and falls to wherever your life has
    /// actually got to.
    @State private var undoing: Double = 0

    /// What to draw: the real maturity, or the intro's, whichever is further along.
    private func showing(_ axis: String) -> Double {
        max(maturity(axis), undoing)
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                Image(uiImage: background)
                    .resizable().scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                // SPIRIT IS NOT A BODY PART, so it is not drawn as one. It gathers as a glow
                // around the whole of you — present before any of you is, which is the right
                // way round for the axis that is least about anatomy.
                Image(uiImage: person)
                    .resizable().scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .blur(radius: 26)
                    .blendMode(.plusLighter)
                    // From nothing. A base glow on an empty axis lit you up before you had
                    // done anything, which is the opposite of the point.
                    .opacity(0.46 * presence(showing("spirit")))
                    .foregroundStyle(spiritColor)
                    .allowsHitTesting(false)

                // Each region is the same picture of you, coarsened by its own axis, shown only
                // where that region is. They overlap softly, so no seam is ever visible between
                // a head that has grown and a chest that has not.
                ForEach(regions, id: \.axis) { region in
                    Image(uiImage: person)
                        .resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .resolving(maturity: showing(region.axis), side: side,
                                   seed: region.seed, blocksAtZero: 26)
                        // YOU BEGIN ERASED. Coarsening alone does not do that: the coarsest
                        // block still carries your colour, so an untouched axis showed a
                        // blocky but unmistakably present man standing there. Presence has to
                        // be its own term, and it has to start at exactly nothing — the first
                        // day should be the photograph without you in it, not the photograph
                        // with a mosaic of you in it.
                        .opacity(presence(showing(region.axis)))
                        .mask {
                            RadialGradient(
                                colors: [.white, .white.opacity(0.85), .clear],
                                center: unitPoint(region.centre),
                                startRadius: 0,
                                endRadius: side * region.reach * max(0.35, anchors.height))
                        }
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            // WATCH YOURSELF GO. Arriving at an empty photograph explains nothing — it looks
            // like a picture of a wall. Coming apart, once, in front of you, says what the
            // screen is for and what the months ahead are going to undo: the coarsening runs
            // backwards, the blocks swell, and you thin out of your own photograph.
            //
            // It also fixes the order in which the eye reads the thing. You have to see it
            // whole before "not whole yet" can mean anything.
            guard introduce else { return }
            undoing = 1
            withAnimation(.easeInOut(duration: 3.4)) { undoing = 0 }
        }
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
