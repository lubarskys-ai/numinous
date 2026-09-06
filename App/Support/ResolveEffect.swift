import SwiftUI

/// Applies the resolve shader to any view: blocky and full of holes when young, whole when
/// grown.
///
/// The point of doing this as a shader rather than a pre-rendered bitmap is that the source
/// stops mattering. A generated placeholder, a bought icon, an SVG, a running animation —
/// anything SwiftUI can draw can be put through this, and it keeps animating underneath.
struct ResolveEffect: ViewModifier {
    /// 0 = nothing here yet, 1 = whole.
    let maturity: Double
    /// The view's side in points, so a block is a real size on screen rather than a fraction.
    let side: CGFloat
    /// Keeps each picture's dissolve its own; two forms at the same maturity shouldn't lose
    /// the same cells.
    let seed: Double
    /// How many blocks span the view at zero maturity.
    ///
    /// Four is right for an axis picture at 180pt: coarse enough to read as unfinished, not so
    /// coarse that the icon is gone. It is badly wrong for a full-screen figure, where four
    /// blocks across is four rectangles and no figure at all. The avatar asks for many more.
    var blocksAtZero: Double = 4

    func body(content: Content) -> some View {
        let m = min(1, max(0, maturity))
        let block = Self.blockSize(maturity: m, side: side, blocksAtZero: blocksAtZero)
        let missing = Self.missing(maturity: m)
        content.layerEffect(
            ShaderLibrary.resolve(.float(block), .float(missing), .float(Float(seed))),
            maxSampleOffset: CGSize(width: block, height: block)
        )
    }

    /// Block size in points.
    ///
    /// Gamma-curved and slow. A linear curve reached a legible picture around a third of the
    /// way up, so most of a life's growth bought no visible change and things read as
    /// finished long before they were. Squaring the input holds the coarse end open: half
    /// grown is still unmistakably blocks, and only the last stretch resolves.
    static func blockSize(maturity m: Double, side: CGFloat, blocksAtZero: Double = 4) -> CGFloat {
        // WHOLE MEANS WHOLE. The curve tops out at 136 blocks across, which on a phone-sized
        // view is a block about three points wide — small, and still visibly not a photograph.
        // A life fully lived should end at the picture, not at a fine mosaic of it.
        if m >= 0.99 { return 1 }
        // The ceiling stays put — whole is whole — so a higher floor also means a gentler
        // climb, which is right: a big picture needs less coarsening to read as unfinished.
        let top = max(2.0, 136.0 / blocksAtZero)
        let blocks = blocksAtZero * pow(top, pow(m, 1.8))
        let size = side / CGFloat(blocks)
        return size <= 1.2 ? 1 : size                    // 1 or less means "whole"
    }

    /// The fraction of cells dropped. Gentle — coarseness already does most of the early
    /// work, and stacking a heavy dissolve on top of a four-block grid erases the picture
    /// rather than leaving it unfinished.
    static func missing(maturity m: Double) -> Float {
        Float(pow(1 - m, 2.0) * 0.34)
    }
}

extension View {
    func resolving(maturity: Double, side: CGFloat, seed: Double, blocksAtZero: Double = 4) -> some View {
        modifier(ResolveEffect(maturity: maturity, side: side, seed: seed, blocksAtZero: blocksAtZero))
    }
}
