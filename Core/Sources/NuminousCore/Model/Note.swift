import Foundation

/// Where a note came from. Passive HealthKit notes earn *base* axis credit only;
/// the larger cross-axis link bonus always requires an actual written, linked note.
public enum NoteSource: String, Codable, Sendable {
    case manual
    case healthKit
}

/// A structured detail on a note — e.g. `Phone: 555-0192`, `Favorite team: Warriors`.
/// Free-form key/value, primarily useful on person/place notes.
public struct NoteDetail: Hashable, Codable, Sendable {
    public var key: String
    public var value: String
    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// Where an imported note came from, so re-importing updates instead of
/// duplicating. `nil` means the note was written by hand. `externalID` is stable
/// within its `source` (a contact identifier, calendar event id, HealthKit uuid…).
public struct NoteOrigin: Hashable, Codable, Sendable {
    public var source: String
    public var externalID: String
    public init(source: String, externalID: String) {
        self.source = source
        self.externalID = externalID
    }
}

/// A single markdown note — a diary entry, a person, a book, an activity, a trip.
///
/// The `title` may be a path like `people/Sam`: the part before the last `/` is
/// its folder (which decides its category and axis), the part after is its
/// display name. Identity for wikilinking is the full `title`, matched
/// case-insensitively.
public struct Note: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var date: Date
    public var body: String

    /// 1–5 growth multiplier: how intensely this note develops you.
    /// See `ScoringConfig.factor(forIntensity:)` (3 is neutral ×1).
    public var intensity: Int
    /// Optional free-text location (a place name, or "lat, long").
    public var location: String?
    /// Free-form key/value details (phone number, favorite team, …).
    public var details: [NoteDetail]
    /// Filenames of attached photos (stored on disk by the app). Optional for
    /// backward-compatible decoding of notes saved before photos existed.
    public var photos: [String]?

    public var source: NoteSource
    /// Where this note was imported from (nil = hand-written). Used to re-import
    /// idempotently.
    public var origin: NoteOrigin?
    /// Groups notes logged in one sitting so growth can be capped per session.
    /// `nil` falls back to bucketing by calendar day.
    public var sessionID: String?
    /// True for placeholder notes auto-created by a link to a missing note.
    public var isStub: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        date: Date = Date(),
        body: String = "",
        intensity: Int = 3,
        location: String? = nil,
        details: [NoteDetail] = [],
        photos: [String]? = nil,
        source: NoteSource = .manual,
        origin: NoteOrigin? = nil,
        sessionID: String? = nil,
        isStub: Bool = false
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.body = body
        self.intensity = intensity
        self.location = location
        self.details = details
        self.photos = photos
        self.source = source
        self.origin = origin
        self.sessionID = sessionID
        self.isStub = isStub
    }

    /// The folder path prefix (`people/Sam` → `people`; `Loose` → `""`).
    public var folderName: String {
        guard let slash = title.lastIndex(of: "/") else { return "" }
        return String(title[..<slash])
    }

    /// The display name after the last `/` (`people/Sam` → `Sam`).
    public var displayName: String {
        guard let slash = title.lastIndex(of: "/") else { return title }
        return String(title[title.index(after: slash)...])
    }

    /// Outgoing wikilink targets (`[[Name]]`) extracted from the body.
    public var linkTargets: [String] {
        WikilinkParser.extract(from: body)
    }
}
