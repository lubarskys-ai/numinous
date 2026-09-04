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
    ///
    /// A composition, not an icon on a swatch: two off-hue glows, grain, and a subject drawn
    /// larger than the frame so the circle CROPS it. That crop is the difference — an icon is
    /// centred with air around it, a picture runs off the edge. Everything is seeded from the
    /// option id, so each choice is its own image and stays that image.
    ///
    /// It is still placeholder art. Generated compositions have a ceiling, and the real
    /// version of this idea wants illustration or photography; what this can settle is the
    /// mechanic and the composition, not the final look.
    ///
    /// Drawn as a CIRCLE on transparency — the silhouette then pixellates along with the
    /// contents, so a young axis is a blocky smudge rather than a crisp disc full of blocks.
    static func source(_ option: Option, tint: UIColor) -> UIImage {
        let cacheKey = "\(option.id)|\(tint.hashValue)"
        if let hit = sourceCache[cacheKey] { return hit }

        var seed = UInt64(abs(option.id.hashValue) % 100_000) &+ 7
        func rnd() -> CGFloat {                     // deterministic per option
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) % 1000) / 1000
        }

        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        tint.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        func shade(_ dh: CGFloat, _ ds: CGFloat, _ db: CGFloat, _ alpha: CGFloat = 1) -> UIColor {
            UIColor(hue: (h + dh).truncatingRemainder(dividingBy: 1),
                    saturation: min(1, max(0, sat + ds)),
                    brightness: min(1, max(0, b + db)), alpha: alpha)
        }

        let size = CGSize(width: side, height: side)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            c.addEllipse(in: CGRect(origin: .zero, size: size))
            c.clip()

            // Ground: a deep-to-light wash at a per-option angle.
            let angle = rnd() * .pi * 2
            let start = CGPoint(x: side / 2 - cos(angle) * side, y: side / 2 - sin(angle) * side)
            let end = CGPoint(x: side / 2 + cos(angle) * side, y: side / 2 + sin(angle) * side)
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [shade(0, -0.10, 0.20).cgColor, shade(0.02, 0.10, -0.30).cgColor] as CFArray,
                                  locations: [0, 1]) {
                c.drawLinearGradient(g, start: start, end: end,
                                     options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }

            // Two soft glows pulled slightly off the axis hue — what keeps it from reading flat.
            for i in 0..<2 {
                let gx = side * (0.18 + rnd() * 0.64), gy = side * (0.16 + rnd() * 0.62)
                let radius = side * (0.34 + rnd() * 0.30)
                let hueShift: CGFloat = i == 0 ? 0.055 : -0.06
                let glow = shade(hueShift, -0.18, 0.28, 0.55)
                if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: [glow.cgColor, glow.withAlphaComponent(0).cgColor] as CFArray,
                                      locations: [0, 1]) {
                    c.drawRadialGradient(g, startCenter: CGPoint(x: gx, y: gy), startRadius: 0,
                                         endCenter: CGPoint(x: gx, y: gy), endRadius: radius, options: [])
                }
            }

            // The subject, drawn BIGGER THAN THE FRAME and off-centre, so the circle crops it.
            // This is the whole difference between an icon and a picture: an icon sits
            // centred inside its badge with air around it; a photograph runs off the edge.
            let config = UIImage.SymbolConfiguration(pointSize: side * (1.02 + rnd() * 0.30), weight: .light)
            let glyph = UIImage(systemName: option.symbol, withConfiguration: config)
                ?? UIImage(systemName: "circle.fill", withConfiguration: config)
            if let glyph {
                let tinted = glyph.withTintColor(.white.withAlphaComponent(0.55), renderingMode: .alwaysOriginal)
                let cx = side * (0.30 + rnd() * 0.42), cy = side * (0.30 + rnd() * 0.42)
                tinted.draw(in: CGRect(x: cx - tinted.size.width / 2, y: cy - tinted.size.height / 2,
                                       width: tinted.size.width, height: tinted.size.height))
            }

            // Grain. A perfectly smooth gradient is the other tell of generated art, and it
            // also gives the pixellation something to bite on early in the arc.
            for _ in 0..<420 {
                let x = rnd() * side, y = rnd() * side
                let v = rnd()
                c.setFillColor(UIColor(white: v > 0.5 ? 1 : 0, alpha: 0.05 + rnd() * 0.05).cgColor)
                c.fill(CGRect(x: x, y: y, width: 2.5, height: 2.5))
            }

            // A breath of shadow at the rim so the disc has some body.
            c.setStrokeColor(UIColor.black.withAlphaComponent(0.16).cgColor)
            c.setLineWidth(side * 0.08)
            c.strokeEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: -side * 0.02, dy: -side * 0.02))
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
