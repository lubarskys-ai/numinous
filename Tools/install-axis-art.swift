import AppKit
import AVFoundation

// Install artwork for one axis (or one picture option).
//
//   swift Tools/install-axis-art.swift mind ~/Downloads/brain.png
//   swift Tools/install-axis-art.swift heart ~/Downloads/heart.mp4
//
// Writes App/Resources/AxisArt/<name>.png, which the app picks up automatically:
// AxisArt.artwork() looks for the option id first, then the axis id, so seven files named
// body / gut / mind / meaning / influences / heart / spirit dress the whole app.
//
// Handles the two things an export usually gets wrong for this app:
//
//   NO ALPHA. An MP4 (and a JPEG) carries none, so the picture arrives on white — and these
//   float with no container behind them, so the white shows as a box. A frame is lifted from
//   video and near-neutral pixels are keyed out. Only NEUTRAL ones: an early version keyed on
//   lightness alone and dissolved the artwork's own pale tints along with the paper.
//
//   TOO SMALL. Icon exports are often 128px, which is ~43pt of real resolution on a 3x
//   screen against a picture displayed at 180pt. Anything smaller than 512 is scaled up.

let side: CGFloat = 512

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: swift Tools/install-axis-art.swift <axis-or-option-id> <file.png|file.mp4>")
}
let name = CommandLine.arguments[1]
let input = URL(fileURLWithPath: (CommandLine.arguments[2] as NSString).expandingTildeInPath)
guard FileManager.default.fileExists(atPath: input.path) else { fail("no such file: \(input.path)") }

// MARK: - Get an image out of whatever was handed over

func frameFromVideo(_ url: URL) -> NSImage? {
    let asset = AVURLAsset(url: url)
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    // The last frame: an icon animation usually ENDS at rest, and rest is the picture.
    let seconds = CMTimeGetSeconds(asset.duration)
    let time = CMTime(seconds: max(0, seconds - 0.02), preferredTimescale: 600)
    guard let cg = try? gen.copyCGImage(at: time, actualTime: nil) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

let isVideo = ["mp4", "mov", "m4v"].contains(input.pathExtension.lowercased())
guard let source = isVideo ? frameFromVideo(input) : NSImage(contentsOf: input) else {
    fail("couldn't read an image out of \(input.lastPathComponent)")
}
guard let sourceRep = source.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) else {
    fail("couldn't decode \(input.lastPathComponent)")
}

// MARK: - Key the paper out, if there is any

let hasAlpha = sourceRep.hasAlpha && (0..<sourceRep.pixelsHigh).contains { y in
    (0..<sourceRep.pixelsWide).contains { x in (sourceRep.colorAt(x: x, y: y)?.alphaComponent ?? 1) < 0.99 }
}

let w = sourceRep.pixelsWide, h = sourceRep.pixelsHigh
guard let keyed = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: w * 4, bitsPerPixel: 32) else {
    fail("couldn't allocate the output bitmap")
}
for y in 0..<h {
    for x in 0..<w {
        guard let c = sourceRep.colorAt(x: x, y: y) else { continue }
        let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
        var a = c.alphaComponent
        if !hasAlpha {
            let hi = max(r, max(g, b)), lo = min(r, min(g, b))
            if hi - lo < 0.035 && hi > 0.93 {           // near-neutral AND near-white: paper
                a = max(0, min(1, (0.995 - hi) / 0.05))
            }
        }
        keyed.setColor(NSColor(deviceRed: r, green: g, blue: b, alpha: a), atX: x, y: y)
    }
}

// MARK: - Scale up if the export was small, and write

let target = max(side, CGFloat(max(w, h)))
let out = NSImage(size: NSSize(width: target, height: target))
out.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high
let scale = min(target / CGFloat(w), target / CGFloat(h))
let drawn = NSSize(width: CGFloat(w) * scale, height: CGFloat(h) * scale)
NSImage(size: NSSize(width: w, height: h), flipped: false, drawingHandler: { rect in
    keyed.draw(in: rect); return true
}).draw(in: NSRect(x: (target - drawn.width) / 2, y: (target - drawn.height) / 2,
                   width: drawn.width, height: drawn.height))
out.unlockFocus()

guard let finalRep = out.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
      let png = finalRep.representation(using: .png, properties: [:]) else {
    fail("couldn't encode the result")
}

let dir = URL(fileURLWithPath: "App/Resources/AxisArt")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let dest = dir.appendingPathComponent("\(name).png")
do { try png.write(to: dest) } catch { fail("couldn't write \(dest.path): \(error)") }

print("installed \(dest.path) — \(Int(target))x\(Int(target)), alpha \(hasAlpha ? "kept from source" : "keyed from white")")
