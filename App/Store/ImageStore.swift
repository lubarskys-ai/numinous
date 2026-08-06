import Foundation
import UIKit
import ImageIO

/// Saves note photos as files on disk (referenced by filename from the note).
/// Kept out of the JSON store so image bytes never bloat it.
enum ImageStore {
    private static let fm = FileManager.default

    private static var dir: URL {
        let url = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Numinous/images", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Saves image data (re-encoded as JPEG) and returns its filename.
    static func save(_ data: Data) -> String? {
        guard let image = UIImage(data: data),
              let jpeg = image.jpegData(compressionQuality: 0.85) else { return nil }
        let name = UUID().uuidString + ".jpg"
        do {
            try jpeg.write(to: dir.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    static func load(_ name: String) -> UIImage? {
        UIImage(contentsOfFile: dir.appendingPathComponent(name).path)
    }

    /// A downsampled thumbnail decoded via ImageIO (never loads the full image into
    /// memory) — cheap enough to build off the main thread for list rows.
    static func thumbnail(_ name: String, maxPixel: CGFloat) -> UIImage? {
        let url = dir.appendingPathComponent(name)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    static func delete(_ name: String) {
        try? fm.removeItem(at: dir.appendingPathComponent(name))
    }
}
