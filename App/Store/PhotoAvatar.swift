import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Vision

/// Your own photograph as the avatar: you are taken out of a picture you love, and come back
/// into it as you live.
///
/// The 3D figure had one problem no amount of modelling fixes — it is not you. A photograph of
/// you somewhere that meant something is already meaningful before the app touches it, and
/// watching yourself return to it is a different feeling from watching a mannequin fill in.
///
/// Everything here happens on the phone. The photo is never uploaded, and nothing about it
/// leaves the device — which matters more for this feature than any other in the app.
///
/// FOUR THINGS THE SYSTEM CAN DO, all of which were tested on a real photograph before this
/// was written:
///
///   SEPARATE ONE PERSON from the others. Not "cut out everybody" — individual outlines, so
///   in a photo of two people only the one you tap dissolves and the other stays sharp.
///   FIND THE PARTS OF A BODY. Head, neck, shoulders, hips, knees, ankles, located in YOUR
///   photograph. That is what lets Mind fill in your head and Heart the middle of your chest,
///   rather than guessing from a rectangle.
///   ERASE, not just fade. There is no public "clean up" on iOS — that is the Photos app's
///   own, not offered to other apps — so the hole is closed by spreading the surrounding
///   colours inward. Against a wall or a sky it is invisible. Against a hedge it is not,
///   which is why `backgroundIsBusy` warns you at the moment you choose.
///   PIXELLATE. The coarse-to-fine reading the axis pictures already use.
@MainActor
enum PhotoAvatar {

    // MARK: - What is stored

    /// Everything needed to draw the avatar, computed once when the photo is chosen.
    struct Prepared {
        /// The photograph with you taken out of it.
        let background: UIImage
        /// Just you, on transparency.
        let person: UIImage
        /// Where your parts are, in unit coordinates with the origin at bottom-left.
        let anchors: Anchors
        /// True when erasing left visible smears, so the caller can say so out loud.
        let backgroundIsBusy: Bool
    }

    /// The handful of body points the axes are hung on. Unit coordinates.
    struct Anchors: Codable {
        var head: CGPoint
        var neck: CGPoint
        var chest: CGPoint
        var hip: CGPoint
        /// How tall the person stands in the frame, used to size each region's falloff.
        var height: CGFloat
    }

    /// A photograph standing upright, with its rotation baked in.
    ///
    /// THE BUG THIS EXISTS TO KILL, which produced four different-looking symptoms from one
    /// cause. A phone stores a portrait photo as a landscape buffer plus a note saying "turn
    /// this a quarter turn". SwiftUI reads that note. `cgImage` does not — it hands back the
    /// sideways buffer. So Vision looked for a person in a rotated picture, the tap targets
    /// landed in rotated coordinates and missed the man standing there, the saved cut-out came
    /// out rotated, a landscape image drawn into a portrait frame looked squashed, and the
    /// erase blurred a band across the wrong part of the photograph.
    ///
    /// Redrawing the image once, upright, makes every one of those go away — and it must
    /// happen before anything else looks at the pixels, which is why it is the first line of
    /// both entry points.
    static func upright(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    // MARK: - Choosing

    /// Every person in the photo, with a point to tap on each — so "which one is you" is a tap
    /// and never a guess.
    ///
    /// Built from BODY POSE rather than from the instance masks, for two reasons. Pose is
    /// available far more widely — instance masking is missing on the Simulator entirely, which
    /// is where this first ran and found nobody in a photograph of two people. And a neck joint
    /// is a much better thing to tap than a mask's centroid, which for someone standing with
    /// their arms out lands in the empty air between them.
    static func people(in image: UIImage) throws -> [(index: Int, centre: CGPoint)] {
        guard let cg = upright(image).cgImage else { return [] }
        let pose = VNDetectHumanBodyPoseRequest()
        try VNImageRequestHandler(cgImage: cg).perform([pose])
        return (pose.results ?? []).enumerated().compactMap { position, body in
            for joint in [VNHumanBodyPoseObservation.JointName.neck, .nose, .root] {
                if let p = try? body.recognizedPoint(joint), p.confidence > 0.2 {
                    return (position, p.location)
                }
            }
            return nil
        }
    }

    // MARK: - Preparing

    /// Take one person out of the photograph and keep both halves.
    ///
    /// `cleanBackground` is the same photograph with you already removed — Apple's Clean Up,
    /// in the Photos app, does this properly: a generative model that RECONSTRUCTS what was
    /// behind you rather than borrowing from beside you. It is not offered to other apps, so
    /// it cannot be called from here. It can, however, be handed the result.
    ///
    /// When one is supplied it is used as-is and the fill below is skipped entirely, because
    /// nothing written here will beat it. When one is not, the row fill does its best, and its
    /// best is very good on a plain wall and merely decent through a hedge.
    /// `youAt` is WHERE YOU TAPPED, not which entry you tapped.
    ///
    /// The picker detects the people once to draw its circles, and this detects them again to
    /// do the work. Vision does not promise the same order from two runs, so an index agreed
    /// between them is a handshake nobody guaranteed — and the cost of it being wrong is
    /// erasing the wrong person out of a photograph of a marriage. A point cannot get out of
    /// order. Whoever is nearest it is who was meant.
    static func prepare(image: UIImage, youAt: CGPoint,
                        cleanBackground: UIImage? = nil) throws -> Prepared {
        guard let cg = upright(image).cgImage else { throw Failure.unreadable }
        let context = CIContext()
        let photo = CIImage(cgImage: cg)

        let personIndex = try nearestBody(cg, to: youAt)
        let mask = try personMask(cg, personIndex: personIndex, extent: photo.extent)
        // A segmentation edge always leaves a rim of the person behind, and a rim of somebody
        // is more noticeable than a slightly larger patch of wall. Grown a little, and softened
        // so the join does not read as a cut-out. This is also what catches a hat or a bag,
        // which the model does not always count as part of a person.
        let grown = mask
            .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": 9])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 4])
            .cropped(to: photo.extent)

        // A background that has already been repaired properly beats anything computed here.
        let background: CIImage
        if let clean = cleanBackground.map(upright), let cleanCG = clean.cgImage {
            background = CIImage(cgImage: cleanCG)
                .transformed(by: CGAffineTransform(scaleX: photo.extent.width / CGFloat(cleanCG.width),
                                                   y: photo.extent.height / CGFloat(cleanCG.height)))
        } else {
            background = erase(photo, person: grown, context: context)
        }
        let person = photo.applyingFilter("CIBlendWithMask", parameters: [kCIInputMaskImageKey: grown])

        guard let backgroundCG = context.createCGImage(background, from: photo.extent),
              let personCG = context.createCGImage(person, from: photo.extent)
        else { throw Failure.couldNotPrepare }

        return Prepared(
            background: UIImage(cgImage: backgroundCG),
            person: UIImage(cgImage: personCG),
            anchors: try anchors(cg, personIndex: personIndex),
            // A supplied background is never "busy" — it has already been dealt with.
            backgroundIsBusy: cleanBackground == nil && isBusy(photo, behind: grown, context: context))
    }

    /// Which detected body is nearest the point that was tapped.
    private static func nearestBody(_ cg: CGImage, to point: CGPoint) throws -> Int {
        let request = VNDetectHumanBodyPoseRequest()
        try VNImageRequestHandler(cgImage: cg).perform([request])
        guard let bodies = request.results, !bodies.isEmpty else { throw Failure.noPersonFound }
        var best = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, body) in bodies.enumerated() {
            guard let points = try? body.recognizedPoints(.all) else { continue }
            for candidate in points.values where candidate.confidence > 0.15 {
                let dx = Double(candidate.location.x - point.x)
                let dy = Double(candidate.location.y - point.y)
                let distance = dx * dx + dy * dy
                if distance < bestDistance { bestDistance = distance; best = index }
            }
        }
        return best
    }

    /// One person's outline, or everybody's when the photo holds only one.
    private static func personMask(_ cg: CGImage, personIndex: Int, extent: CGRect) throws -> CIImage {
        let handler = VNImageRequestHandler(cgImage: cg)
        let instances = VNGeneratePersonInstanceMaskRequest()
        // Two different requests do not number people the same way, so the instance is found by
        // asking which outline actually covers the body that was tapped.
        if (try? handler.perform([instances])) != nil,
           let result = instances.results?.first,
           let anchor = try? anchors(cg, personIndex: personIndex),
           let instance = instanceCovering(anchor.chest, in: result, handler: handler, extent: extent),
           let buffer = try? result.generateScaledMaskForImage(forInstances: [instance], from: handler) {
            return scaled(CIImage(cvPixelBuffer: buffer), to: extent)
        }
        // When instance masking is unavailable or inconclusive, fall back to "everyone" — and
        // then CUT IT DOWN to the person who was chosen.
        //
        // Falling back to everyone on its own is what erased both people. It was written as
        // "right when there is only one person and honest when there is not", which was wrong:
        // there is nothing honest about dissolving somebody's wife because the first method
        // did not resolve. If a photograph has two people in it, the one that was tapped is
        // the only acceptable answer.
        //
        // The chosen body's own joints give a box around it. Intersecting the everyone-mask
        // with that box isolates one person reliably whenever they are not overlapping, which
        // covers the ordinary case of two people standing apart in a photograph.
        let whole = VNGeneratePersonSegmentationRequest()
        whole.qualityLevel = .accurate
        whole.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try VNImageRequestHandler(cgImage: cg).perform([whole])
        guard let buffer = whole.results?.first?.pixelBuffer else { throw Failure.noPersonFound }
        let everyone = scaled(CIImage(cvPixelBuffer: buffer), to: extent)

        guard let box = bodyBox(cg, personIndex: personIndex, extent: extent) else { return everyone }
        // A soft-edged box, so the cut does not leave a straight vertical line down the
        // photograph where it clipped.
        let keep = CIImage(color: .white).cropped(to: box)
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 24])
            .cropped(to: extent)
        return everyone.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: keep]).cropped(to: extent)
    }

    /// A padded box around one body, from its own joints.
    private static func bodyBox(_ cg: CGImage, personIndex: Int, extent: CGRect) -> CGRect? {
        let request = VNDetectHumanBodyPoseRequest()
        try? VNImageRequestHandler(cgImage: cg).perform([request])
        guard let bodies = request.results, bodies.count > 1,
              let body = bodies[safe: personIndex],
              let points = try? body.recognizedPoints(.all) else { return nil }
        let found = points.values.filter { $0.confidence > 0.15 }.map(\.location)
        guard found.count >= 4 else { return nil }

        let minX = found.map(\.x).min()!, maxX = found.map(\.x).max()!
        let minY = found.map(\.y).min()!, maxY = found.map(\.y).max()!
        // Generous padding: joints sit inside a body, and hair, hats, shoes and outstretched
        // hands all live outside the last joint.
        let padX = max(0.10, (maxX - minX) * 0.65), padY = max(0.08, (maxY - minY) * 0.22)
        let x0 = max(0, minX - padX), x1 = min(1, maxX + padX)
        let y0 = max(0, minY - padY), y1 = min(1, maxY + padY)
        // Vision counts up from the bottom; a CIImage does too, so no flip is needed here.
        return CGRect(x: x0 * extent.width, y: y0 * extent.height,
                      width: (x1 - x0) * extent.width, height: (y1 - y0) * extent.height)
    }

    /// Which outline covers this point on the body.
    private static func instanceCovering(_ point: CGPoint,
                                         in result: VNInstanceMaskObservation,
                                         handler: VNImageRequestHandler,
                                         extent: CGRect) -> Int? {
        for instance in result.allInstances {
            guard let buffer = try? result.generateScaledMaskForImage(forInstances: [instance],
                                                                      from: handler) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self)
            else { continue }
            // Vision's origin is bottom-left; the buffer's is top-left.
            let x = min(w - 1, max(0, Int(point.x * CGFloat(w))))
            let y = min(h - 1, max(0, Int((1 - point.y) * CGFloat(h))))
            if base[y * stride + x] > 40 { return instance }
        }
        return nil
    }

    private static func scaled(_ image: CIImage, to extent: CGRect) -> CIImage {
        image.transformed(by: CGAffineTransform(scaleX: extent.width / image.extent.width,
                                                y: extent.height / image.extent.height))
    }

    /// Close the hole ROW BY ROW, taking each row's own neighbours across the gap.
    ///
    /// The first version blurred the picture repeatedly and pasted the known background back
    /// each time, so colour crept inward from the edges. It closed a hole in a wall invisibly
    /// and made a mess of everything else, because a blur has no idea which way the world
    /// runs. It dragged the hedge up onto the plaster.
    ///
    /// A person standing in front of scenery almost always has a HORIZONTALLY BANDED
    /// background — a wall, a hedge, a kerb, a road, each carrying straight on through where
    /// they stand. Filling each row from its own left and right keeps every band at its own
    /// height, which is most of the difference between "he was never there" and "something has
    /// been smudged out".
    ///
    /// How the gap is filled then depends on what the ground is made of, measured rather than
    /// chosen:
    ///
    ///   FLAT ground — plaster, sky, sand — takes the two edge colours run across it. Smooth
    ///   is what flat looks like.
    ///   TEXTURED ground — foliage, gravel, paving — takes the real pixels just outside the
    ///   gap, REFLECTED inward, so leaves stay leaves instead of becoming a green streak.
    ///
    /// Mixing them in proportion matters more than picking one: a standing figure crosses
    /// plaster, then hedge, then paving on its way down the frame, and each row gets what that
    /// row needs. Reflecting on flat ground was what dragged a pink smear of somebody's arm
    /// across the wall.
    private static func erase(_ photo: CIImage, person: CIImage, context: CIContext) -> CIImage {
        let extent = photo.extent
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0,
              let photoCG = context.createCGImage(photo, from: extent),
              let maskCG = context.createCGImage(person, from: extent)
        else { return photo }

        func bitmap(_ image: CGImage) -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            buffer.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return buffer
        }

        var pixels = bitmap(photoCG)
        let mask = bitmap(maskCG)

        for y in 0..<height {
            var x = 0
            while x < width {
                guard mask[(y * width + x) * 4] > 100 else { x += 1; continue }
                var end = x
                while end < width && mask[(y * width + end) * 4] > 100 { end += 1 }

                let leftX = x - 1, rightX = end
                let hasLeft = leftX >= 0, hasRight = rightX < width

                // How textured is the ground either side of this gap.
                var difference = 0.0
                var samples = 0
                for probe in 1...28 {
                    for side in [leftX - probe, rightX + probe] where side >= 1 && side < width - 1 {
                        difference += abs(Double(pixels[(y * width + side) * 4])
                                          - Double(pixels[(y * width + side + 1) * 4]))
                        samples += 1
                    }
                }
                let texture = samples > 0 ? min(1.0, (difference / Double(samples)) / 9.0) : 0

                for px in x..<end {
                    let t = Double(px - x + 1) / Double(end - x + 1)
                    let mirrorL = leftX - (px - x), mirrorR = rightX + (end - 1 - px)
                    for channel in 0..<3 {
                        let edgeL = hasLeft ? Double(pixels[(y * width + leftX) * 4 + channel]) : 0
                        let edgeR = hasRight ? Double(pixels[(y * width + rightX) * 4 + channel]) : 0
                        let reflectedL = (hasLeft && mirrorL >= 0)
                            ? Double(pixels[(y * width + mirrorL) * 4 + channel]) : edgeL
                        let reflectedR = (hasRight && mirrorR < width)
                            ? Double(pixels[(y * width + mirrorR) * 4 + channel]) : edgeR

                        let flat: Double, mirrored: Double
                        if hasLeft && hasRight {
                            flat = edgeL * (1 - t) + edgeR * t
                            mirrored = reflectedL * (1 - t) + reflectedR * t
                        } else if hasLeft { flat = edgeL; mirrored = reflectedL }
                        else { flat = edgeR; mirrored = reflectedR }

                        pixels[(y * width + px) * 4 + channel] =
                            UInt8(max(0, min(255, flat * (1 - texture) + mirrored * texture)))
                    }
                }
                x = end
            }
        }

        guard let filled = pixels.withUnsafeMutableBytes({ raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }) else { return photo }

        // A whisker of softening, inside the hole only, so the run-across does not read as
        // suspiciously cleaner than the photograph around it.
        let image = CIImage(cgImage: filled)
        return image
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.2])
            .cropped(to: extent)
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: person])
            .cropped(to: extent)
    }

    /// How much detail sat behind the person, which is what decides whether erasing them is
    /// invisible or a smear. A wall has almost no edges; a hedge is nothing but edges.
    private static func isBusy(_ photo: CIImage, behind mask: CIImage, context: CIContext) -> Bool {
        // Look in a band around the outline — the fill is only ever as good as what borders it.
        let ring = mask.applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": 40])
            .applyingFilter("CIColorInvert")
            .applyingFilter("CIMultiplyCompositing", parameters: [
                kCIInputBackgroundImageKey: mask.applyingFilter("CIMorphologyMaximum",
                                                                parameters: ["inputRadius": 90])])
        let edges = photo.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 6.0])
            .applyingFilter("CIBlendWithMask", parameters: [kCIInputMaskImageKey: ring])
            .applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: photo.extent)])
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(edges, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let busyness = Double(Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / 3.0
        return busyness > 11
    }

    /// Where the parts of the body are, so each axis can fill in its own.
    private static func anchors(_ cg: CGImage, personIndex: Int) throws -> Anchors {
        let request = VNDetectHumanBodyPoseRequest()
        try VNImageRequestHandler(cgImage: cg).perform([request])
        guard let body = request.results?[safe: personIndex] ?? request.results?.first else {
            throw Failure.noPersonFound
        }
        func point(_ joint: VNHumanBodyPoseObservation.JointName, _ fallback: CGPoint) -> CGPoint {
            guard let p = try? body.recognizedPoint(joint), p.confidence > 0.2 else { return fallback }
            return p.location
        }
        let head = point(.nose, CGPoint(x: 0.5, y: 0.8))
        let neck = point(.neck, CGPoint(x: head.x, y: head.y - 0.08))
        let hip = point(.root, CGPoint(x: neck.x, y: neck.y - 0.25))
        let ankle = point(.leftAnkle, CGPoint(x: hip.x, y: hip.y - 0.3))
        return Anchors(head: head, neck: neck,
                       // The heart sits above the midpoint of the trunk, not at it.
                       chest: CGPoint(x: (neck.x + hip.x) / 2, y: neck.y - (neck.y - hip.y) * 0.35),
                       hip: hip,
                       height: max(0.15, head.y - ankle.y))
    }

    enum Failure: Error { case unreadable, noPersonFound, couldNotPrepare }

    /// Why nobody was found — and it is not always the photograph's fault.
    ///
    /// Vision's human-body models want the Neural Engine and do not run on the Simulator at
    /// all: the same photograph that yields two people and sixteen joints on a Mac yields
    /// nothing there. Saying "no one recognisable in this photo" in that situation sends the
    /// user hunting through their library for a better picture that does not exist.
    static func whyNoOneFound() -> String {
        #if targetEnvironment(simulator)
        return "Finding people needs the Neural Engine, which the Simulator does not have. "
             + "This works on a real iPhone — try it there."
        #else
        return "No one recognisable in this photo. Try one where you're standing clear of the "
             + "background, head to foot."
        #endif
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Keeping it

extension PhotoAvatar {
    /// On the device, in the app's own folder, and nowhere else. A photograph of yourself is
    /// the most personal thing this app will ever hold, and it does not travel.
    private static var folder: URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = docs.appendingPathComponent("PhotoAvatar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func file(_ name: String) -> URL? { folder?.appendingPathComponent(name) }

    /// Everything needed to draw, loaded back. Nil when no photo has been chosen.
    static func stored() -> (background: UIImage, person: UIImage, anchors: Anchors)? {
        guard let bg = file("background.png").flatMap({ UIImage(contentsOfFile: $0.path) }),
              let person = file("person.png").flatMap({ UIImage(contentsOfFile: $0.path) }),
              let data = file("anchors.json").flatMap({ try? Data(contentsOf: $0) }),
              let anchors = try? JSONDecoder().decode(Anchors.self, from: data)
        else { return nil }
        return (bg, person, anchors)
    }

    static func save(_ prepared: Prepared) throws {
        guard let bg = file("background.png"), let person = file("person.png"),
              let anchors = file("anchors.json") else { throw Failure.couldNotPrepare }
        try prepared.background.pngData()?.write(to: bg, options: .atomic)
        try prepared.person.pngData()?.write(to: person, options: .atomic)
        try JSONEncoder().encode(prepared.anchors).write(to: anchors, options: .atomic)
    }

    static func forget() {
        for name in ["background.png", "person.png", "anchors.json"] {
            if let url = file(name) { try? FileManager.default.removeItem(at: url) }
        }
    }

    static var exists: Bool { stored() != nil }
}
