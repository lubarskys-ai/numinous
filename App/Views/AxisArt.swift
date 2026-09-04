import SwiftUI
import UIKit
import ImageIO
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

    /// Where a picture the user imported for this axis lives. Their own choice sits in
    /// Documents, not the bundle, so it survives an app update and can be removed again.
    private static func customURL(_ name: String) -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return nil }
        return docs.appendingPathComponent("AxisArt", isDirectory: true)
            .appendingPathComponent("\(name).png")
    }

    /// Loaded images, including the misses — without this, seven rows in Setup hit the disk
    /// on every render looking for files that mostly aren't there.
    private static var artCache: [String: UIImage?] = [:]

    static func clearArtCache() { artCache.removeAll() }

    /// The picture to draw: the user's own import first, then bundled artwork, then nil —
    /// and per OPTION before per AXIS at each step, so a single imported file dresses an axis
    /// whichever of its four pictures is selected.
    static func artwork(_ option: Option, axisID: String) -> UIImage? {
        let key = "\(option.id)|\(axisID)"
        if let hit = artCache[key] { return hit }
        var found: UIImage?
        outer: for name in [option.id, axisID] {
            if let url = customURL(name), FileManager.default.fileExists(atPath: url.path),
               let image = UIImage(contentsOfFile: url.path) {
                found = image; break outer
            }
            if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "AxisArt")
                ?? Bundle.main.url(forResource: name, withExtension: "png"),
               let image = UIImage(contentsOfFile: url.path) {
                found = image; break outer
            }
        }
        artCache[key] = found
        return found
    }

    /// Artwork filed under THIS OPTION only — no axis fallback.
    ///
    /// The fallback is what lets one imported file dress a whole axis, which is right on the
    /// axis page. It is wrong in the chooser: with it, all four of Mind's options rendered
    /// the same imported brain and there was nothing to choose between.
    static func optionArtwork(_ option: Option) -> UIImage? {
        let key = "option-only|\(option.id)"
        if let hit = artCache[key] { return hit }
        var found: UIImage?
        if let url = customURL(option.id), FileManager.default.fileExists(atPath: url.path) {
            found = UIImage(contentsOfFile: url.path)
        }
        if found == nil,
           let url = Bundle.main.url(forResource: option.id, withExtension: "png", subdirectory: "AxisArt")
            ?? Bundle.main.url(forResource: option.id, withExtension: "png") {
            found = UIImage(contentsOfFile: url.path)
        }
        artCache[key] = found
        return found
    }

    static func hasCustomArtwork(axisID: String) -> Bool {
        guard let url = customURL(axisID) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Importing

    enum ImportError: LocalizedError {
        case unreadable, tooSmall, couldNotSave
        var errorDescription: String? {
            switch self {
            case .unreadable:    return "That file isn't an image Numinous can read."
            case .tooSmall:      return "That image is too small — 256 pixels or more works best."
            case .couldNotSave:  return "Couldn't save that picture."
            }
        }
    }

    /// Take a picture the user chose and make it usable here: keyed, square, and capped.
    ///
    /// The keying matters. These float with no container behind them, so a JPEG — which has
    /// no alpha — arrives as a white box. Only NEAR-NEUTRAL pixels are cleared: keying on
    /// lightness alone eats the artwork's own pale tints along with the background. An image
    /// that already has transparency is left alone, because real alpha always beats a guess.
    @discardableResult
    static func importArtwork(_ image: UIImage, forAxis axisID: String) throws -> UIImage {
        guard let prepared = prepare(image) else { throw ImportError.unreadable }
        guard let url = customURL(axisID), let data = prepared.pngData() else {
            throw ImportError.couldNotSave
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw ImportError.couldNotSave
        }
        clearArtCache()
        return prepared
    }

    static func removeArtwork(forAxis axisID: String) {
        if let url = customURL(axisID) { try? FileManager.default.removeItem(at: url) }
        if let dir = framesDir(axisID) { try? FileManager.default.removeItem(at: dir) }
        animationCache.removeValue(forKey: axisID)
        clearArtCache()
    }

    // MARK: - Animated artwork

    /// A picture that moves: prepared frames and how long the loop runs.
    struct Animation {
        let frames: [UIImage]
        let duration: Double
    }

    private static func framesDir(_ axisID: String) -> URL? {
        customURL(axisID)?.deletingLastPathComponent()
            .appendingPathComponent("\(axisID).frames", isDirectory: true)
    }

    private static var animationCache: [String: Animation?] = [:]

    /// The imported animation for an axis, if there is one. Decoded once and held — the
    /// frames are read off disk, and doing that per render would be absurd.
    static func animation(forAxis axisID: String) -> Animation? {
        if let hit = animationCache[axisID] { return hit }
        var found: Animation?
        if let dir = framesDir(axisID),
           let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            let pngs = names.filter { $0.hasSuffix(".png") }.sorted()
            let frames = pngs.compactMap { UIImage(contentsOfFile: dir.appendingPathComponent($0).path) }
            let seconds = (try? String(contentsOf: dir.appendingPathComponent("duration.txt"), encoding: .utf8))
                .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 2.0
            if frames.count > 1 { found = Animation(frames: frames, duration: max(0.2, seconds)) }
        }
        animationCache[axisID] = found
        return found
    }

    /// Which frame is showing at this moment. Nil when the axis has no animation, so callers
    /// fall through to the still picture without branching twice.
    static func frame(forAxis axisID: String, at t: TimeInterval) -> UIImage? {
        guard let anim = animation(forAxis: axisID) else { return nil }
        let phase = t.truncatingRemainder(dividingBy: anim.duration) / anim.duration
        let index = min(anim.frames.count - 1, max(0, Int(phase * Double(anim.frames.count))))
        return anim.frames[index]
    }

    static func hasAnimation(forAxis axisID: String) -> Bool { animation(forAxis: axisID) != nil }

    /// Import an animated GIF or APNG. Returns false when the file turns out to hold a single
    /// frame, so the caller can fall back to importing it as a still rather than reporting a
    /// failure for something that is simply a picture.
    @discardableResult
    static func importAnimation(data: Data, forAxis axisID: String) throws -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImportError.unreadable
        }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return false }

        // Total loop length, from whichever delay key the format uses.
        var total = 0.0
        for i in 0..<count { total += frameDelay(source, i) }
        if total <= 0.05 { total = Double(count) / 25.0 }

        // Even sample down to a manageable number of frames.
        let wanted = min(count, maxFrames)
        let indices = (0..<wanted).map { Int(Double($0) * Double(count) / Double(wanted)) }

        guard let dir = framesDir(axisID) else { throw ImportError.couldNotSave }
        try? FileManager.default.removeItem(at: dir)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (n, i) in indices.enumerated() {
                guard let cg = CGImageSourceCreateImageAtIndex(source, i, nil),
                      let prepared = prepare(UIImage(cgImage: cg), side: animationSide),
                      let png = prepared.pngData() else { continue }
                let name = String(format: "%03d.png", n)
                try png.write(to: dir.appendingPathComponent(name), options: .atomic)
            }
            try String(total).write(to: dir.appendingPathComponent("duration.txt"),
                                    atomically: true, encoding: .utf8)
        } catch {
            throw ImportError.couldNotSave
        }

        // A still of the first frame too, so anywhere that doesn't animate still has a picture.
        if let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            try? importArtwork(UIImage(cgImage: cg), forAxis: axisID)
        }
        animationCache.removeValue(forKey: axisID)
        clearArtCache()
        return true
    }

    private static func frameDelay(_ source: CGImageSource, _ index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        else { return 0 }
        for key in [kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary] {
            guard let d = props[key] as? [CFString: Any] else { continue }
            for delayKey in [kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime,
                             kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime] {
                if let v = d[delayKey] as? Double, v > 0 { return v }
            }
        }
        return 0
    }

    private static let importSide = 512
    /// Animation frames are held in memory all at once, so they are smaller than a still.
    private static let animationSide = 256
    /// Enough to read as motion, few enough to keep the memory sane: 30 frames at 256 square
    /// is about 8MB, where a 3.5s Lordicon GIF at 40fps would have been 140 frames of 512.
    private static let maxFrames = 30

    private static func prepare(_ image: UIImage, side: Int = importSide) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let n = side
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &pixels, width: n, height: n, bitsPerComponent: 8,
                                  bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        // Fit, don't fill: cropping someone's icon to a square would cut the subject.
        let scale = min(CGFloat(n) / CGFloat(cg.width), CGFloat(n) / CGFloat(cg.height))
        let w = CGFloat(cg.width) * scale, h = CGFloat(cg.height) * scale
        ctx.draw(cg, in: CGRect(x: (CGFloat(n) - w) / 2, y: (CGFloat(n) - h) / 2, width: w, height: h))

        // Was there any real transparency to begin with? If so, trust it.
        var hadAlpha = false
        for i in stride(from: 3, to: pixels.count, by: 4) where pixels[i] < 250 { hadAlpha = true; break }

        if !hadAlpha {
            for i in stride(from: 0, to: pixels.count, by: 4) {
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                let hi = max(r, max(g, b)), lo = min(r, min(g, b))
                guard hi - lo < 9, hi > 237 else { continue }      // near-neutral AND near-white
                let a = max(0, min(255, Int((254.0 - Double(hi)) / 13.0 * 255.0)))
                pixels[i] = UInt8(Double(r) * Double(a) / 255.0)   // premultiplied
                pixels[i + 1] = UInt8(Double(g) * Double(a) / 255.0)
                pixels[i + 2] = UInt8(Double(b) * Double(a) / 255.0)
                pixels[i + 3] = UInt8(a)
            }
        }
        guard let out = ctx.makeImage() else { return nil }
        return UIImage(cgImage: out)
    }

    // MARK: - Rendering    // MARK: - Rendering

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
