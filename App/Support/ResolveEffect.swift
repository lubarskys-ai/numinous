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

    func body(content: Content) -> some View {
        let m = min(1, max(0, maturity))
        let block = Self.blockSize(maturity: m, side: side)
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
    static func blockSize(maturity m: Double, side: CGFloat) -> CGFloat {
        let blocks = 4.0 * pow(34.0, pow(m, 1.8))       // 4 across at 0, ~11 at ½, 136 at 1
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
    func resolving(maturity: Double, side: CGFloat, seed: Double) -> some View {
        modifier(ResolveEffect(maturity: maturity, side: side, seed: seed))
    }
}
