import AppKit
import AVFoundation
import ImageIO

// Install artwork for one axis (or one picture option), so it ships with the app.
//
//   swift Tools/install-axis-art.swift mind ~/Downloads/brain.apng
//   swift Tools/install-axis-art.swift heart ~/Downloads/heart.png
//
// Writes into App/Resources/AxisArt/, which the app picks up automatically. AxisArt looks for
// the option id first, then the axis id, so seven files named body / gut / mind / meaning /
// influences / heart / spirit dress the whole app.
//
// An animated APNG or GIF is installed as FRAMES and plays. Anything else becomes a still.
//
// Handles the two things an export usually gets wrong here:
//
//   NO ALPHA. An MP4 (and a JPEG) carries none, so the picture arrives on white — and these
//   float with no container behind them, so the white shows as a box. Near-neutral pixels are
//   keyed out; only NEUTRAL ones, because keying on lightness alone dissolves the artwork's
//   own pale tints along with the paper.
//
//   TOO SMALL. Icon exports are often 128px, which is ~43pt of real resolution on a 3x screen
//   against a picture displayed at 180pt. Anything smaller is scaled up.

let stillSide = 512
let animationSide = 256
let maxFrames = 30

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: swift Tools/install-axis-art.swift <axis-or-option-id> <file>")
}
let name = CommandLine.arguments[1]
let input = URL(fileURLWithPath: (CommandLine.arguments[2] as NSString).expandingTildeInPath)
guard FileManager.default.fileExists(atPath: input.path) else { fail("no such file: \(input.path)") }

let dir = URL(fileURLWithPath: "App/Resources/AxisArt")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

/// Flat file names, not a folder: a directory inside the app bundle can be flattened by the
/// build, which would collide 000.png across seven axes.
func frameName(_ index: Int) -> String { String(format: "%@.frame%03d", name, index) }

// MARK: - Preparing one image

/// Key the paper out (only if there is no real alpha), fit into a square, and encode.
func normalized(_ cg: CGImage, side: Int) -> Data? {
    let rep = NSBitmapImageRep(cgImage: cg)
    let w = rep.pixelsWide, h = rep.pixelsHigh

    let hasAlpha = rep.hasAlpha && stride(from: 0, to: h, by: 4).contains { y in
        stride(from: 0, to: w, by: 4).contains { x in
            (rep.colorAt(x: x, y: y)?.alphaComponent ?? 1) < 0.99
        }
    }

    guard let keyed = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: w * 4, bitsPerPixel: 32) else { return nil }
    for y in 0..<h {
        for x in 0..<w {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
            var a = c.alphaComponent
            if !hasAlpha {
                let hi = max(r, max(g, b)), lo = min(r, min(g, b))
                if hi - lo < 0.035 && hi > 0.93 {          // near-neutral AND near-white: paper
                    a = max(0, min(1, (0.995 - hi) / 0.05))
                }
            }
            keyed.setColor(NSColor(deviceRed: r, green: g, blue: b, alpha: a), atX: x, y: y)
        }
    }

    let target = CGFloat(max(side, max(w, h) < side ? side : max(w, h)))
    let out = NSImage(size: NSSize(width: target, height: target))
    out.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    let scale = min(target / CGFloat(w), target / CGFloat(h))
    let drawn = NSSize(width: CGFloat(w) * scale, height: CGFloat(h) * scale)
    NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
        keyed.draw(in: rect); return true
    }.draw(in: NSRect(x: (target - drawn.width) / 2, y: (target - drawn.height) / 2,
                      width: drawn.width, height: drawn.height))
    out.unlockFocus()

    return out.tiffRepresentation
        .flatMap(NSBitmapImageRep.init(data:))
        .flatMap { $0.representation(using: .png, properties: [:]) }
}

// MARK: - Animated

func installAnimation(_ data: Data) -> Bool {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
    let count = CGImageSourceGetCount(src)
    guard count > 1 else { return false }

    var total = 0.0
    for i in 0..<count {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
        else { continue }
        for key in [kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary] {
            guard let d = props[key] as? [CFString: Any] else { continue }
            for dk in [kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime,
                       kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime] {
                if let v = d[dk] as? Double, v > 0 { total += v; break }
            }
        }
    }
    if total <= 0.05 { total = Double(count) / 25.0 }

    // The same budget the app uses: thirty frames at 256 is about 8MB held in memory, where
    // 61 frames at full size would be several times that for a single axis.
    let wanted = min(count, maxFrames)
    let indices = (0..<wanted).map { Int(Double($0) * Double(count) / Double(wanted)) }

    // Clear previous frames so a shorter animation can't leave a tail of the old one.
    for i in 0..<200 {
        let old = dir.appendingPathComponent("\(frameName(i)).png")
        guard FileManager.default.fileExists(atPath: old.path) else { break }
        try? FileManager.default.removeItem(at: old)
    }

    var written = 0
    for (n, i) in indices.enumerated() {
        guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil),
              let png = normalized(cg, side: animationSide) else { continue }
        try? png.write(to: dir.appendingPathComponent("\(frameName(n)).png"))
        written += 1
    }
    try? String(total).write(to: dir.appendingPathComponent("\(name).duration.txt"),
                             atomically: true, encoding: .utf8)

    // A still of the first frame too, so anywhere that doesn't animate has a picture.
    if let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
       let png = normalized(cg, side: stillSide) {
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
    }

    print("""
    installed \(written) frames for \(name) — \(String(format: "%.2f", total))s loop, \
    sampled from \(count) in the source
    """)
    return true
}

// MARK: - Do it

let data = (try? Data(contentsOf: input)) ?? Data()
if !data.isEmpty, installAnimation(data) { exit(0) }

func frameFromVideo(_ url: URL) -> CGImage? {
    let asset = AVURLAsset(url: url)
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    // The last frame: an icon animation usually ENDS at rest, and rest is the picture.
    let seconds = CMTimeGetSeconds(asset.duration)
    return try? gen.copyCGImage(at: CMTime(seconds: max(0, seconds - 0.02), preferredTimescale: 600),
                                actualTime: nil)
}

let isVideo = ["mp4", "mov", "m4v"].contains(input.pathExtension.lowercased())
let still: CGImage? = isVideo
    ? frameFromVideo(input)
    : NSImage(contentsOf: input)?.cgImage(forProposedRect: nil, context: nil, hints: nil)

guard let still, let png = normalized(still, side: stillSide) else {
    fail("couldn't read an image out of \(input.lastPathComponent)")
}
let dest = dir.appendingPathComponent("\(name).png")
do { try png.write(to: dest) } catch { fail("couldn't write \(dest.path): \(error)") }
print("installed \(dest.path) as a still")
