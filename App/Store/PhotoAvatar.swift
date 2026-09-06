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
///   PIXELLATE. The coarse-to-fine reading the axis pictures already use.
///
/// AND ONE THING IT NO LONGER TRIES TO DO. The first version kept the photograph and removed
/// the person from it, which meant reconstructing whatever had been standing behind them —
/// genuinely hard, four attempts deep, and never right on a busy background. Keeping the
/// PERSON and throwing the photograph away deletes that problem entirely: cutting somebody out
/// was always easy, and it was only putting them back that was not.
@MainActor
enum PhotoAvatar {

    // MARK: - What is stored

    /// Everything needed to draw the avatar, computed once when the photo is chosen.
    struct Prepared {
        /// You, cut out and cropped close, on transparency.
        ///
        /// THE PHOTOGRAPH IS NO LONGER KEPT, and losing it removed the hardest problem in this
        /// feature. Reconstructing what stood behind someone is genuinely difficult — it is
        /// what Apple's Clean Up does with a trained model and what four attempts here did with
        /// arithmetic, producing smears through a hedge and a dark patch where a torso had
        /// been. None of that exists any more. Cutting a person OUT is easy and already
        /// worked; it was only putting them back that was hard, and nothing needs putting back.
        ///
        /// It is also simply better to look at: cropped close and dropped on black, a person
        /// fills the screen instead of standing small in the middle of a holiday snap.
        let person: UIImage
        /// Where your parts are, in unit coordinates with the origin at bottom-left.
        let anchors: Anchors
    }

    /// The handful of body points the axes are hung on. Unit coordinates.
    struct Anchors: Codable {
        /// Where each part is, as a fraction of the CROPPED picture.
        var head: CGPoint
        var neck: CGPoint
        var chest: CGPoint
        var hip: CGPoint
        /// How tall the person stands in the frame, used to size each region's falloff.
        var height: CGFloat

        /// The same points, re-expressed against a crop of the original.
        ///
        /// Every anchor is a fraction of a picture, so cropping the picture moves all of them.
        /// Forgetting this is the sort of thing that puts a head in the middle of a chest and
        /// looks like a tuning problem for a day.
        func moved(into box: CGRect, from full: CGRect) -> Anchors {
            func shift(_ p: CGPoint) -> CGPoint {
                CGPoint(x: (p.x * full.width - box.minX) / max(1, box.width),
                        y: (p.y * full.height - box.minY) / max(1, box.height))
            }
            return Anchors(head: shift(head), neck: shift(neck), chest: shift(chest),
                           hip: shift(hip),
                           height: height * full.height / max(1, box.height))
        }
    }

    /// A photograph standing upright, with its rotation baked in.
    ///
    /// THE BUG THIS EXISTS TO KILL, which produced four different-looking symptoms from one
    /// cause. A phone stores a portrait photo as a landscape buffer plus a note saying "turn
    /// this a quarter turn". SwiftUI reads that note. `cgImage` does not — it hands back the
    /// sideways buffer. So Vision looked for a person in a rotated picture, the tap targets
    /// landed in rotated coordinates and missed the man standing there, the saved cut-out came
    /// out rotated, a landscape image drawn into a portrait frame looked squashed, and the
    /// cut-out came out rotated and squashed.
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

    /// Asked when the photo is CHOSEN rather than after it is committed. The answer was being
    /// worked out during preparation and reported to a screen that closed a moment later, so
    /// nobody ever saw it — advice about a decision, delivered after the decision, to a view on
    /// its way out.
    static func backgroundWillSmear(_ image: UIImage, youAt: CGPoint) -> Bool {
        guard let cg = upright(image).cgImage else { return false }
        let context = CIContext()
        let photo = CIImage(cgImage: cg)
        guard let index = try? nearestBody(cg, to: youAt),
              let mask = try? personMask(cg, personIndex: index, extent: photo.extent)
        else { return false }
        return isBusy(photo, behind: mask, context: context)
    }

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
    static func prepare(image: UIImage, youAt: CGPoint) throws -> Prepared {
        guard let cg = upright(image).cgImage else { throw Failure.unreadable }
        let context = CIContext()
        let photo = CIImage(cgImage: cg)

        let personIndex = try nearestBody(cg, to: youAt)
        let mask = try personMask(cg, personIndex: personIndex, extent: photo.extent)
        // Grown a little and softened, so no rim of background survives around a shoulder and
        // the edge does not read as scissors. This is also what catches a hat or a bag.
        let grown = mask
            .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": 6])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 3])
            .cropped(to: photo.extent)

        let cutOut = photo.applyingFilter("CIBlendWithMask", parameters: [kCIInputMaskImageKey: grown])
        let anchors = try anchors(cg, personIndex: personIndex)

        // Crop close. The frame is taken from the body's own joints rather than from the
        // mask's bounds, because a mask can pick up a stray patch of somebody's arm across the
        // room and a skeleton cannot.
        let box = tightBox(anchors, in: photo.extent)
        guard let cropped = context.createCGImage(cutOut, from: box) else { throw Failure.couldNotPrepare }

        return Prepared(person: UIImage(cgImage: cropped),
                        anchors: anchors.moved(into: box, from: photo.extent))
    }

    /// The rectangle to crop to: the body, with room around it.
    private static func tightBox(_ a: Anchors, in extent: CGRect) -> CGRect {
        // Joints sit inside a body, and hair, shoes and outstretched hands live beyond the last
        // one — so the margins are generous, and taller above the head than below the feet
        // because that is where a hat is.
        let top = min(1, a.head.y + a.height * 0.22)
        let bottom = max(0, a.head.y - a.height * 1.12)
        let halfWidth = max(0.10, a.height * 0.46)
        let left = max(0, a.head.x - halfWidth), right = min(1, a.head.x + halfWidth)
        // Vision counts from the bottom and so does a CIImage, so no flip is needed.
        return CGRect(x: left * extent.width, y: bottom * extent.height,
                      width: max(1, (right - left) * extent.width),
                      height: max(1, (top - bottom) * extent.height))
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

        // ONE CONTEXT THAT OWNS ITS OWN MEMORY, and the pixels edited in place inside it.
        //
        // The first version built a Swift array, handed its pointer to a CGContext inside a
        // `withUnsafeMutableBytes` closure, and called makeImage() there — then used the image
        // AFTER the closure returned. That image is backed by memory the closure no longer
        // guarantees, which is undefined behaviour and crashed on the first run through. It is
        // the sort of thing that appears to work in a simulator and does not on a phone.
        //
        // Letting Core Graphics allocate means the memory lives exactly as long as the context
        // does, and the image it makes is safe to use afterwards.
        guard let canvas = CGContext(data: nil, width: width, height: height,
                                     bitsPerComponent: 8, bytesPerRow: width * 4,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let maskCanvas = CGContext(data: nil, width: width, height: height,
                                         bitsPerComponent: 8, bytesPerRow: width * 4,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return photo }

        let whole = CGRect(x: 0, y: 0, width: width, height: height)
        canvas.draw(photoCG, in: whole)
        maskCanvas.draw(maskCG, in: whole)
        guard let pixels = canvas.data?.assumingMemoryBound(to: UInt8.self),
              let mask = maskCanvas.data?.assumingMemoryBound(to: UInt8.self)
        else { return photo }
        let rowBytes = canvas.bytesPerRow, maskRow = maskCanvas.bytesPerRow

        func textured(_ y: Int, _ leftX: Int, _ rightX: Int) -> Double {
            var difference = 0.0
            var samples = 0
            for probe in 1...28 {
                for side in [leftX - probe, rightX + probe] where side >= 1 && side < width - 1 {
                    difference += abs(Double(pixels[y * rowBytes + side * 4])
                                      - Double(pixels[y * rowBytes + (side + 1) * 4]))
                    samples += 1
                }
            }
            return samples > 0 ? min(1.0, (difference / Double(samples)) / 9.0) : 0
        }

        func isHole(_ x: Int, _ y: Int) -> Bool { mask[y * maskRow + x * 4] > 100 }

        // ACROSS ONLY, after trying across AND down and looking at the result.
        //
        // Filling the middle of a wide gap from above and below as well is the obvious answer
        // to a dark centre — the rows above a chest are nearer than the walls beside it — and
        // on the test photograph it came out visibly WORSE: long vertical smears down the wall
        // and through the hedge where the horizontal fill had been clean. A standing body makes
        // a tall thin hole, so a column through it spans from head to feet and has nothing near
        // it in that direction at all.
        //
        // Kept as a note rather than as code, because the reasoning was sound and the result
        // was not, and the next person to have the same good idea should know it was tried.
        for y in 0..<height {
            var x = 0
            while x < width {
                guard mask[y * maskRow + x * 4] > 100 else { x += 1; continue }
                var end = x
                while end < width && mask[y * maskRow + end * 4] > 100 { end += 1 }

                let leftX = x - 1, rightX = end
                let hasLeft = leftX >= 0, hasRight = rightX < width

                // How textured is the ground either side of this gap.
                var difference = 0.0
                var samples = 0
                for probe in 1...28 {
                    for side in [leftX - probe, rightX + probe] where side >= 1 && side < width - 1 {
                        difference += abs(Double(pixels[y * rowBytes + side * 4])
                                          - Double(pixels[y * rowBytes + (side + 1) * 4]))
                        samples += 1
                    }
                }
                let texture = samples > 0 ? min(1.0, (difference / Double(samples)) / 9.0) : 0

                for px in x..<end {
                    let t = Double(px - x + 1) / Double(end - x + 1)
                    let mirrorL = leftX - (px - x), mirrorR = rightX + (end - 1 - px)
                    for channel in 0..<3 {
                        let edgeL = hasLeft ? Double(pixels[y * rowBytes + leftX * 4 + channel]) : 0
                        let edgeR = hasRight ? Double(pixels[y * rowBytes + rightX * 4 + channel]) : 0
                        let reflectedL = (hasLeft && mirrorL >= 0)
                            ? Double(pixels[y * rowBytes + mirrorL * 4 + channel]) : edgeL
                        let reflectedR = (hasRight && mirrorR < width)
                            ? Double(pixels[y * rowBytes + mirrorR * 4 + channel]) : edgeR

                        let flat: Double, mirrored: Double
                        if hasLeft && hasRight {
                            flat = edgeL * (1 - t) + edgeR * t
                            mirrored = reflectedL * (1 - t) + reflectedR * t
                        } else if hasLeft { flat = edgeL; mirrored = reflectedL }
                        else { flat = edgeR; mirrored = reflectedR }

                        pixels[y * rowBytes + px * 4 + channel] =
                            UInt8(max(0, min(255, flat * (1 - texture) + mirrored * texture)))
                    }
                }
                x = end
            }
        }

        guard let filled = canvas.makeImage() else { return photo }

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
    static func stored() -> (person: UIImage, anchors: Anchors)? {
        guard let person = file("person.png").flatMap({ UIImage(contentsOfFile: $0.path) }),
              let data = file("anchors.json").flatMap({ try? Data(contentsOf: $0) }),
              let anchors = try? JSONDecoder().decode(Anchors.self, from: data)
        else { return nil }
        return (person, anchors)
    }

    static func save(_ prepared: Prepared) throws {
        guard let person = file("person.png"), let anchors = file("anchors.json")
        else { throw Failure.couldNotPrepare }
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
