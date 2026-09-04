import SwiftUI
import UIKit
import NuminousCore

/// The picture that stands for one axis, and the pixellation that resolves it as that
/// axis grows.
///
/// PROTOTYPE ART. These compositions are generated on the fly from a gradient and an SF
/// Symbol so the mechanic can be judged before anyone commissions a set of images. Real
/// art would be bundled assets keyed by the same ids; nothing else here would change.
///
/// Pixellation is done with genuine blocks — the image is drawn down to an N×N grid and
/// scaled back up with interpolation OFF. A Gaussian blur was the obvious alternative and
/// is the wrong one: blurred reads as "loading" or "broken", blocks read as deliberate.
enum AxisArt {

    /// One choosable picture for an axis.
    struct Option: Identifiable, Hashable {
        let id: String          // stable, stored in UserDefaults — art can be swapped under it
        let symbol: String
        let label: String
    }

    /// Four options per axis. Deliberately concrete: an axis you can *picture* is one you
    /// can feel the state of at a glance, which a coloured bar never manages.
    static func options(for axisID: String) -> [Option] {
        switch axisID {
        case "body":
            return [opt("body.walk", "figure.walk", "Walking"), opt("body.run", "figure.run", "Running"),
                    opt("body.bike", "bicycle", "Cycling"), opt("body.swim", "drop.fill", "Swimming")]
        case "gut":
            return [opt("gut.table", "fork.knife", "The table"), opt("gut.leaf", "leaf.fill", "Growing"),
                    opt("gut.cup", "cup.and.saucer.fill", "Slow mornings"), opt("gut.flame", "flame.fill", "Cooking")]
        case "mind":
            return [opt("mind.brain", "brain.head.profile", "Thinking"), opt("mind.book", "book.fill", "Reading"),
                    opt("mind.idea", "lightbulb.fill", "Ideas"), opt("mind.write", "pencil", "Writing")]
        case "meaning":
            return [opt("meaning.peaks", "mountain.2.fill", "Higher ground"), opt("meaning.globe", "globe.americas.fill", "The world"),
                    opt("meaning.sun", "sunrise.fill", "First light"), opt("meaning.map", "map.fill", "The long way")]
        case "influences":
            return [opt("infl.quote", "quote.bubble.fill", "Voices"), opt("infl.books", "books.vertical.fill", "The shelf"),
                    opt("infl.mic", "mic.fill", "Listening"), opt("infl.people", "person.2.fill", "Company")]
        case "heart":
            return [opt("heart.heart", "heart.fill", "Love"), opt("heart.hands", "hands.sparkles.fill", "Care"),
                    opt("heart.letter", "envelope.fill", "Keeping in touch"), opt("heart.people", "person.2.fill", "The people")]
        case "spirit":
            return [opt("spirit.spark", "sparkles", "Wonder"), opt("spirit.moon", "moon.stars.fill", "Stillness"),
                    opt("spirit.flame", "flame.fill", "Devotion"), opt("spirit.sun", "sun.max.fill", "Light")]
        default:
            return [opt("gen.circle", "circle.fill", "Plain"), opt("gen.spark", "sparkles", "Spark"),
                    opt("gen.leaf", "leaf.fill", "Leaf"), opt("gen.star", "star.fill", "Star")]
        }
    }

    private static func opt(_ id: String, _ symbol: String, _ label: String) -> Option {
        Option(id: id, symbol: symbol, label: label)
    }

    // MARK: - Chosen option (per axis)

    private static func key(_ axisID: String) -> String { "axis_image_\(axisID)" }

    /// The picture this axis is set to — the stored choice, else the first option. Stored in
    /// UserDefaults rather than on `Axis` while this is a prototype: `Axis` is Codable and in
    /// the persisted store, so adding a field there costs a schema migration for a decision
    /// that may not survive the week.
    static func chosen(for axisID: String) -> Option {
        let all = options(for: axisID)
        let saved = UserDefaults.standard.string(forKey: key(axisID))
        return all.first { $0.id == saved } ?? all[0]
    }

    static func choose(_ option: Option, for axisID: String) {
        UserDefaults.standard.set(option.id, forKey: key(axisID))
    }

    // MARK: - Rendering

    private static let side: CGFloat = 240
    private static var sourceCache: [String: UIImage] = [:]
    private static var blockCache: [String: UIImage] = [:]

    /// The full-fidelity picture for an option, in that axis's colour.
    static func source(_ option: Option, tint: UIColor) -> UIImage {
        let cacheKey = "\(option.id)|\(tint.hashValue)"
        if let hit = sourceCache[cacheKey] { return hit }
        let size = CGSize(width: side, height: side)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            // A two-stop wash of the axis colour, so each picture still reads as "this axis"
            // when it is too pixellated to read as anything else.
            let c = ctx.cgContext
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            tint.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            let top = UIColor(hue: h, saturation: max(0, s - 0.18), brightness: min(1, b + 0.22), alpha: 1)
            let bottom = UIColor(hue: h, saturation: min(1, s + 0.12), brightness: max(0, b - 0.24), alpha: 1)
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1]) {
                // Extend past both ends, or the corners beyond the gradient's axis stay unpainted.
                c.drawLinearGradient(g, start: .zero, end: CGPoint(x: side * 0.35, y: side),
                                     options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            let config = UIImage.SymbolConfiguration(pointSize: side * 0.44, weight: .semibold)
            // A missing symbol must not blank the picture — fall back rather than draw nothing.
            let glyph = UIImage(systemName: option.symbol, withConfiguration: config)
                ?? UIImage(systemName: "circle.fill", withConfiguration: config)
            if let glyph {
                let tinted = glyph.withTintColor(.white.withAlphaComponent(0.92), renderingMode: .alwaysOriginal)
                let r = CGRect(x: (side - tinted.size.width) / 2, y: (side - tinted.size.height) / 2,
                               width: tinted.size.width, height: tinted.size.height)
                tinted.draw(in: r)
            }
        }
        sourceCache[cacheKey] = image
        return image
    }

    /// How coarse the grid is at a given maturity. Exponential, because the interesting part
    /// of the arc is early: going 4→8 blocks is a visible event, 96→104 is not.
    static func blocks(for maturity: Double) -> Int {
        let m = min(1, max(0, maturity))
        return Int(round(pow(2.0, 2.0 + m * 5.0)))     // 4 blocks at 0 → 128 at 1
    }

    /// The picture as it stands at this maturity: blocky when young, whole when grown.
    static func rendered(_ option: Option, tint: UIColor, maturity: Double) -> UIImage {
        let src = source(option, tint: tint)
        let n = blocks(for: maturity)
        guard n < Int(side) else { return src }         // fully grown — no grid at all
        let cacheKey = "\(option.id)|\(tint.hashValue)|\(n)"
        if let hit = blockCache[cacheKey] { return hit }

        // Down to an n×n grid…
        let small = UIGraphicsImageRenderer(size: CGSize(width: n, height: n)).image { _ in
            src.draw(in: CGRect(x: 0, y: 0, width: n, height: n))
        }
        // …and back up with interpolation OFF, which is what makes them blocks and not blur.
        let out = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            ctx.cgContext.interpolationQuality = .none
            small.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        blockCache[cacheKey] = out
        return out
    }
}
