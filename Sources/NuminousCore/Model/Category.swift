import Foundation

/// A free-form, user-defined category (Golf, Novels, Close friends…) mapped onto
/// exactly one growth `Axis`.
///
/// The mapping is a *reference* (`axisID`), so reassigning a category to a
/// different axis retroactively reflows every past note's contribution — the
/// engine recomputes from the current state each time, so history never migrates.
///
/// `axisID == nil` means the category exists but hasn't been mapped to an axis
/// yet; notes in an unmapped category contribute zero growth until it's mapped.
public struct Category: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var name: String
    public var axisID: String?

    public init(id: String, name: String, axisID: String? = nil) {
        self.id = id
        self.name = name
        self.axisID = axisID
    }

    /// Convenience initializer that slugifies the display name into a stable id.
    public init(name: String, axisID: String? = nil) {
        self.init(id: Category.slug(name), name: name, axisID: axisID)
    }

    /// Lowercased, whitespace-collapsed identifier used as a stable key.
    public static func slug(_ name: String) -> String {
        let lowered = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = lowered.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "_" })
        return collapsed.joined(separator: "-")
    }
}
