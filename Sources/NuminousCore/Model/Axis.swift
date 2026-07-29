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
    /// A sensible 4-axis starting set. The brief leaves the exact set open;
    /// these match its running example (Body / Mind / Heart / Spirit) and are
    /// fully renamable by the user without touching scoring.
    static let body   = Axis(id: "body",   name: "Body",   colorHex: "#C4674A")
    static let mind   = Axis(id: "mind",   name: "Mind",   colorHex: "#4A73C4")
    static let heart  = Axis(id: "heart",  name: "Heart",  colorHex: "#C44A73")
    static let spirit = Axis(id: "spirit", name: "Spirit", colorHex: "#8A6DB0")

    static let defaultSet: [Axis] = [.body, .mind, .heart, .spirit]
}
