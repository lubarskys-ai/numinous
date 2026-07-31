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
    /// The primary axis (kept for color/display and backward compatibility). When
    /// a folder grows several axes, this is the first of `axisIDs`.
    public var axisID: String?
    /// The full set of axes a folder grows. A note's base credit (and its share of
    /// link/breadth bonuses) is divided equally among these — so a "golf" folder
    /// set to Body+Mind+Spirit spreads each note's growth three ways. Optional for
    /// backward compatibility; when nil/empty, `axisID` is the single axis.
    public var axisIDs: [String]?
    /// Default intensity for notes created in this folder (nil = neutral 3).
    /// Lets a "type" of note carry its own weight — a quick-capture folder can
    /// default low, a deep-reflection folder high.
    public var defaultIntensity: Int?

    /// The axes this folder actually grows (multi-axis, else the single `axisID`).
    public var growthAxes: [String] {
        if let axisIDs, !axisIDs.isEmpty { return axisIDs }
        return axisID.map { [$0] } ?? []
    }

    public init(id: String, name: String, category: String, axisID: String? = nil, axisIDs: [String]? = nil, defaultIntensity: Int? = nil) {
        self.id = id
        self.name = name
        self.category = category
        self.axisID = axisID
        self.axisIDs = axisIDs
        self.defaultIntensity = defaultIntensity
    }

    public init(name: String, category: String, axisID: String? = nil, axisIDs: [String]? = nil, defaultIntensity: Int? = nil) {
        self.init(id: Folder.normalize(name), name: name, category: category, axisID: axisID, axisIDs: axisIDs, defaultIntensity: defaultIntensity)
    }

    /// Lowercased, trimmed key used to match a note's folder path to a folder.
    public static func normalize(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
