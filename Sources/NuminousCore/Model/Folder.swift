import Foundation

/// A folder is the organizing unit for notes. Its `name` is the path prefix used
/// in a note's title (`people/Sam` → folder `people`), and it carries a
/// predefined `category` that maps to exactly one growth `Axis`.
///
/// This is the settled model: you file a note under a folder, and the folder
/// decides its category and which axis it grows — you organize once, and growth
/// follows. Every `[[link]]` a note makes to a note in another folder adds that
/// folder's axis, so a note's connections are its categories.
///
/// `axisID == nil` means the folder exists but isn't mapped yet; its notes
/// contribute zero growth until it's given an axis.
public struct Folder: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var name: String
    public var category: String
    public var axisID: String?

    public init(id: String, name: String, category: String, axisID: String? = nil) {
        self.id = id
        self.name = name
        self.category = category
        self.axisID = axisID
    }

    public init(name: String, category: String, axisID: String? = nil) {
        self.init(id: Folder.normalize(name), name: name, category: category, axisID: axisID)
    }

    /// Lowercased, trimmed key used to match a note's folder path to a folder.
    public static func normalize(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
