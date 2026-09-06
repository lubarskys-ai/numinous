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
        guard let cg = image.cgImage else { return [] }
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
    static func prepare(image: UIImage, personIndex: Int) throws -> Prepared {
        guard let cg = image.cgImage else { throw Failure.unreadable }
        let context = CIContext()
        let photo = CIImage(cgImage: cg)

        let mask = try personMask(cg, personIndex: personIndex, extent: photo.extent)
        // A segmentation edge always leaves a rim of the person behind, and a rim of somebody
        // is more noticeable than a slightly larger patch of wall. Grown a little, and softened
        // so the join does not read as a cut-out. This is also what catches a hat or a bag,
        // which the model does not always count as part of a person.
        let grown = mask
            .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": 9])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 4])
            .cropped(to: photo.extent)

        let background = erase(photo, person: grown)
        let person = photo.applyingFilter("CIBlendWithMask", parameters: [kCIInputMaskImageKey: grown])

        guard let backgroundCG = context.createCGImage(background, from: photo.extent),
              let personCG = context.createCGImage(person, from: photo.extent)
        else { throw Failure.couldNotPrepare }

        return Prepared(
            background: UIImage(cgImage: backgroundCG),
            person: UIImage(cgImage: personCG),
            anchors: try anchors(cg, personIndex: personIndex),
            backgroundIsBusy: isBusy(photo, behind: grown, context: context))
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
        // Older or unusual photographs: fall back to "everyone", which is right when there is
        // only one person and honest when there is not.
        let whole = VNGeneratePersonSegmentationRequest()
        whole.qualityLevel = .accurate
        whole.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try VNImageRequestHandler(cgImage: cg).perform([whole])
        guard let buffer = whole.results?.first?.pixelBuffer else { throw Failure.noPersonFound }
        return scaled(CIImage(cvPixelBuffer: buffer), to: extent)
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

    /// Close the hole by spreading the surrounding colours inward.
    ///
    /// Blur the picture, paste the KNOWN background back over the result, and repeat with a
    /// tighter radius each pass. Real colour creeps a little further into the hole every time,
    /// from its edges, until the hole is filled with what surrounds it. Crude beside a trained
    /// model and, on a plain surface, very hard to catch.
    private static func erase(_ photo: CIImage, person: CIImage) -> CIImage {
        let known = photo.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputMaskImageKey: person.applyingFilter("CIColorInvert")])
        var filled = known
        for radius in [64.0, 48.0, 32.0, 24.0, 16.0, 12.0, 8.0, 6.0, 4.0] {
            filled = filled
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: photo.extent)
                .applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: filled])
            filled = known.applyingFilter("CISourceOverCompositing",
                                          parameters: [kCIInputBackgroundImageKey: filled])
        }
        return filled.cropped(to: photo.extent)
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
