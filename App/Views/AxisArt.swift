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
/// This file only makes the FULL-FIDELITY picture. The blocks and the dissolve that carry
/// growth live in `Resolve.metal` and are applied on the GPU, so the arc is continuous, the
/// picture can animate while it is coarse, and a bought icon drops in wherever one exists.
/// The block curve deliberately lives in exactly one place — `ResolveEffect` — because two
/// copies of it would drift.
enum AxisArt {

    /// One element of a picture: a symbol, how big, and where it sits.
    struct Layer: Hashable {
        let symbol: String
        let scale: CGFloat      // fraction of the canvas
        let x: CGFloat          // unit position of its centre
        let y: CGFloat
    }

    /// One choosable picture for an axis. Two or three elements, not one glyph — a subject
    /// with something around it reads as a scene, and a lone centred symbol reads as an icon
    /// no matter how it is drawn.
    struct Option: Identifiable, Hashable {
        let id: String          // stable, stored in UserDefaults — art can be swapped under it
        let label: String
        let layers: [Layer]
    }

    private static func scene(_ id: String, _ label: String,
                              _ subject: String, _ accent: String,
                              _ accent2: String? = nil) -> Option {
        var layers = [Layer(symbol: subject, scale: 0.62, x: 0.44, y: 0.56),
                      Layer(symbol: accent,  scale: 0.24, x: 0.80, y: 0.22)]
        if let accent2 { layers.append(Layer(symbol: accent2, scale: 0.17, x: 0.16, y: 0.84)) }
        return Option(id: id, label: label, layers: layers)
    }

    /// Four options per axis. Deliberately concrete: an axis you can *picture* is one you can
    /// feel the state of at a glance, which a coloured bar never manages.
    static func options(for axisID: String) -> [Option] {
        switch axisID {
        case "body":
            return [scene("body.walk", "Walking", "figure.walk", "sun.max.fill", "leaf.fill"),
                    scene("body.run",  "Running", "figure.run", "flame.fill"),
                    scene("body.bike", "Cycling", "bicycle", "sun.max.fill"),
                    scene("body.swim", "Swimming", "figure.pool.swim", "drop.fill")]
        case "gut":
            return [scene("gut.table", "The table", "fork.knife", "leaf.fill", "drop.fill"),
                    scene("gut.leaf",  "Growing", "leaf.fill", "sun.max.fill"),
                    scene("gut.cup",   "Slow mornings", "cup.and.saucer.fill", "sun.max.fill"),
                    scene("gut.flame", "Cooking", "flame.fill", "fork.knife")]
        case "mind":
            return [scene("mind-brain", "Thinking", "brain.head.profile", "lightbulb.fill"),
                    scene("mind.book",  "Reading", "book.fill", "lightbulb.fill", "sparkles"),
                    scene("mind.idea",  "Ideas", "lightbulb.fill", "sparkles"),
                    scene("mind.write", "Writing", "pencil", "book.fill")]
        case "meaning":
            return [scene("meaning.peaks", "Higher ground", "mountain.2.fill", "sun.max.fill", "cloud.fill"),
                    scene("meaning.globe", "The world", "globe.americas.fill", "sparkles"),
                    scene("meaning.sun",   "First light", "sunrise.fill", "cloud.fill"),
                    scene("meaning.map",   "The long way", "map.fill", "mappin")]
        case "influences":
            return [scene("infl.quote", "Voices", "quote.bubble.fill", "person.fill"),
                    scene("infl.books", "The shelf", "books.vertical.fill", "lightbulb.fill"),
                    scene("infl.mic",   "Listening", "mic.fill", "waveform"),
                    scene("infl.people", "Company", "person.2.fill", "quote.bubble.fill")]
        case "heart":
            return [scene("heart.heart",  "Love", "heart.fill", "sparkles", "heart.fill"),
                    scene("heart.hands",  "Care", "hands.sparkles.fill", "heart.fill"),
                    scene("heart.letter", "Keeping in touch", "envelope.fill", "heart.fill"),
                    scene("heart.people", "The people", "person.2.fill", "heart.fill")]
        case "spirit":
            return [scene("spirit.spark", "Wonder", "sparkles", "moon.stars.fill"),
                    scene("spirit.moon",  "Stillness", "moon.stars.fill", "sparkles"),
                    scene("spirit.flame", "Devotion", "flame.fill", "sparkles"),
                    scene("spirit.sun",   "Light", "sun.max.fill", "cloud.fill")]
        default:
            return [scene("gen.circle", "Plain", "circle.fill", "sparkles"),
                    scene("gen.spark", "Spark", "sparkles", "circle.fill"),
                    scene("gen.leaf", "Leaf", "leaf.fill", "sun.max.fill"),
                    scene("gen.star", "Star", "star.fill", "sparkles")]
        }
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

    // MARK: - Real artwork

    /// A bought or drawn image for this option, if one is bundled. Falls back to the
    /// generated placeholder, so the seven can be replaced one at a time rather than all at
    /// once — which is how they will actually arrive.
    static func artwork(_ option: Option) -> UIImage? {
        guard let url = Bundle.main.url(forResource: option.id, withExtension: "png",
                                        subdirectory: "AxisArt")
                ?? Bundle.main.url(forResource: option.id, withExtension: "png") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    // MARK: - Rendering

    private static let side: CGFloat = 240
    private static var sourceCache: [String: UIImage] = [:]

    /// The full-fidelity picture for an option, in that axis's colour.
    ///
    /// NO CONTAINER. The scene is drawn on transparency and floats on its own — a shape in a
    /// filled circle is an app icon by construction, however the inside is composed.
    ///
    /// One gradient masked by ALL the layers at once, so a scene reads as one object cut from
    /// one piece of colour rather than as a collage of separate glyphs.
    ///
    /// Still placeholder art. What this can settle is the mechanic and the composition.
    static func source(_ option: Option, tint: UIColor) -> UIImage {
        let cacheKey = "\(option.id)|\(tint.hashValue)"
        if let hit = sourceCache[cacheKey] { return hit }

        var seed = UInt64(abs(option.id.hashValue) % 100_000) &+ 7
        func rnd() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) % 1000) / 1000
        }

        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        tint.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        func shade(_ dh: CGFloat, _ ds: CGFloat, _ db: CGFloat) -> UIColor {
            UIColor(hue: (h + dh).truncatingRemainder(dividingBy: 1),
                    saturation: min(1, max(0, sat + ds)),
                    brightness: min(1, max(0, b + db)), alpha: 1)
        }

        let size = CGSize(width: side, height: side)

        // Every layer on one transparent sheet — this becomes the mask.
        let mask = UIGraphicsImageRenderer(size: size).image { _ in
            for layer in option.layers {
                let config = UIImage.SymbolConfiguration(pointSize: side * layer.scale, weight: .regular)
                guard let glyph = (UIImage(systemName: layer.symbol, withConfiguration: config)
                                   ?? UIImage(systemName: "circle.fill", withConfiguration: config))?
                    .withTintColor(.white, renderingMode: .alwaysOriginal) else { continue }
                glyph.draw(in: CGRect(x: side * layer.x - glyph.size.width / 2,
                                      y: side * layer.y - glyph.size.height / 2,
                                      width: glyph.size.width, height: glyph.size.height))
            }
        }

        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [shade(0.04, -0.16, 0.26).cgColor,
                                           shade(-0.02, 0.14, -0.16).cgColor] as CFArray,
                                  locations: [0, 1]) {
                let angle = rnd() * .pi * 2
                c.drawLinearGradient(g,
                                     start: CGPoint(x: side/2 - cos(angle)*side/2, y: side/2 - sin(angle)*side/2),
                                     end: CGPoint(x: side/2 + cos(angle)*side/2, y: side/2 + sin(angle)*side/2),
                                     options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            for _ in 0..<500 {
                let v = rnd()
                c.setFillColor(UIColor(white: v > 0.5 ? 1 : 0, alpha: 0.06).cgColor)
                c.fill(CGRect(x: rnd() * side, y: rnd() * side, width: 3, height: 3))
            }
            // The mask must cover the WHOLE canvas: destinationIn only clears the rect it is
            // drawn into, so masking with a glyph's own smaller rect leaves bars of raw
            // gradient standing beside it.
            mask.draw(in: CGRect(origin: .zero, size: size), blendMode: .destinationIn, alpha: 1)
        }
        sourceCache[cacheKey] = image
        return image
    }

}
