import Foundation

/// One of the small, fixed set of growth axes the avatar can render along.
///
/// Axes are stable in *identity* (`id`) but user-renamable in *display* (`name`)
/// and re-colorable (`colorHex`). Because classification of a new category is a
/// runtime call against the current axis names, nothing here is hardcoded into
/// scoring logic — the engine only ever reasons about axis `id`s.
public struct Axis: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var name: String
    /// Hex color (e.g. `#5B8A72`) used for the avatar's subtle per-axis color cast.
    public var colorHex: String

    public init(id: String, name: String, colorHex: String) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }
}

public extension Axis {
    /// The starting set. The brain is bicameral: `mind` is the left hemisphere
    /// (practical / problem-solving) and `meaning` the right (intuition / the big
    /// picture). `spirit` stays the core, `heart` the chest, `body` the limbs.
    /// All fully renamable by the user without touching scoring.
    static let body       = Axis(id: "body",       name: "Body",       colorHex: "#C4674A")
    static let gut        = Axis(id: "gut",        name: "Gut",        colorHex: "#6FA24A")
    static let mind       = Axis(id: "mind",       name: "Mind",       colorHex: "#4A73C4")
    static let meaning    = Axis(id: "meaning",    name: "Meaning",    colorHex: "#3E9E8E")
    /// People who shape you at a distance — through their books, talks, work. Sits
    /// between Mind (the ideas) and Heart (the people), bridging the two.
    static let influences = Axis(id: "influences", name: "Influences", colorHex: "#B08A3E")
    static let heart      = Axis(id: "heart",      name: "Heart",      colorHex: "#C44A73")
    static let spirit     = Axis(id: "spirit",     name: "Spirit",     colorHex: "#8A6DB0")

    static let defaultSet: [Axis] = [.body, .gut, .mind, .meaning, .influences, .heart, .spirit]
}
