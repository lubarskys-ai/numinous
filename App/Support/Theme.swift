import SwiftUI
import UIKit
import NuminousCore

// `Axis` collides with SwiftUI.Axis; alias so bare `Axis` means our domain type.
typealias Axis = NuminousCore.Axis
typealias Folder = NuminousCore.Folder

extension Color {
    /// A `#RRGGBB` string for this color, or nil if components can't be read.
    func toHex() -> String? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return String(format: "#%02X%02X%02X",
                      Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }

    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&value), cleaned.count == 6 else {
            self = .gray
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

extension Axis {
    var color: Color { Color(hex: colorHex) }
}

/// Distances, written the way the reader expects them — miles where they'd say miles.
/// Shared by the note's travel reading and the map's reach bar, so the same trip never reads
/// two different ways in two places.
enum DistanceFormat {
    static func short(km: Double) -> String {
        formatter.string(from: Measurement(value: km, unit: UnitLength.kilometers))
    }

    private static let formatter: MeasurementFormatter = {
        let f = MeasurementFormatter()
        f.unitOptions = .naturalScale
        f.numberFormatter.maximumFractionDigits = 0
        return f
    }()
}
