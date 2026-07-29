import Foundation

/// How a person interaction happened. In-person connection is weighted more
/// heavily than mediated connection — the app rewards a connected life, not
/// screen time. `nil` on a non-person note.
public enum InteractionMode: String, Codable, Sendable, CaseIterable {
    case inPerson
    case call
    case text
    case social
}

/// Where a note came from. Passive HealthKit notes earn *base* axis credit only;
/// the larger cross-axis link bonus always requires an actual written, linked note.
public enum NoteSource: String, Codable, Sendable {
    case manual
    case healthKit
}

/// A single markdown note — a diary entry, a person, a book, an activity, a trip.
///
/// Identity for wikilinking is the `title` (Obsidian-style), matched
/// case-insensitively. `categoryID == nil` marks an untyped stub (e.g. one
/// auto-created by a `[[link]]` to a not-yet-written note); it contributes zero
/// growth until it's given a category.
public struct Note: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var categoryID: String?
    public var date: Date
    public var body: String

    /// For person notes: how the interaction happened. Drives the in-person bonus.
    public var interaction: InteractionMode?
    /// Light 1–5 self-rating of depth. Deliberately *not* scored (word count and
    /// depth invite padding); it only tunes the avatar's visual detail/tone.
    public var depth: Int?
    public var source: NoteSource
    /// Groups notes logged in one sitting so growth can be capped per session.
    /// `nil` falls back to bucketing by calendar day.
    public var sessionID: String?
    /// True for placeholder notes auto-created by a link to a missing note.
    public var isStub: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        categoryID: String? = nil,
        date: Date = Date(),
        body: String = "",
        interaction: InteractionMode? = nil,
        depth: Int? = nil,
        source: NoteSource = .manual,
        sessionID: String? = nil,
        isStub: Bool = false
    ) {
        self.id = id
        self.title = title
        self.categoryID = categoryID
        self.date = date
        self.body = body
        self.interaction = interaction
        self.depth = depth
        self.source = source
        self.sessionID = sessionID
        self.isStub = isStub
    }

    /// Outgoing wikilink targets (`[[Name]]`) extracted from the body.
    public var linkTargets: [String] {
        WikilinkParser.extract(from: body)
    }
}
