import Foundation
import NuminousCore

struct StoredData: Codable {
    var notes: [Note]
    var folders: [Folder]
    var axes: [Axis]
    /// Bumped when a one-time data migration runs (nil = pre-versioning / 0).
    var schemaVersion: Int? = nil
    /// Reflections already shown, so the app varies them and can reference the
    /// past ("last month your Heart was quiet"). Optional = backward-compatible.
    var reflections: [ReflectionRecord]? = nil
    /// Follow-up reminders set from notes, tracked so completing one rewards you.
    var followUps: [FollowUp]? = nil
    /// What Find-links has learned from your Add/Edit/Skip decisions. Optional =
    /// backward-compatible with stores written before learning existed.
    var linkLearning: LinkLearning? = nil
}

/// What the app has learned from your Find-links decisions, so suggestions get
/// better with use:
/// - `aliases`: a surface you confirmed (e.g. "shawna") → the target you linked it
///   to ("contacts/Shawna Flanagan"). Next time that surface appears it auto-links
///   silently — deterministically, so it works even without the on-device model.
/// - `skips`: names you rejected — never re-proposed as new notes.
/// - `folderForName`: the folder you tend to file a given name under, so a re-mention
///   is proposed there instead of the model's guess.
struct LinkLearning: Codable {
    var aliases: [String: String] = [:]
    var skips: [String] = []
    var folderForName: [String: String] = [:]
}

/// A reminder set from a note ("call Sam in two weeks"). When the user completes
/// it in iOS Reminders, the app rewards the follow-through (grows the connection).
struct FollowUp: Codable, Identifiable {
    var id: String { reminderID }
    let reminderID: String
    let noteTitle: String     // the note it was set from, e.g. "people/Sam" — to link back
    let title: String         // the reminder's title, for display
    let due: Date
    var rewarded: Bool = false
}

/// A reflection the app has surfaced. `signature` ties back to the grounding
/// `Observation` so we don't repeat one too soon and can notice when it changes.
struct ReflectionRecord: Codable, Identifiable, Equatable {
    var id: String { signature + date.timeIntervalSinceReferenceDate.description }
    var signature: String
    var text: String
    var date: Date
}

/// Local-first persistence. For this model iteration everything is one JSON file
/// (notes carry structured details, which a flat markdown frontmatter can't hold
/// cleanly). Markdown import/export via NuminousCore's parser/serializer can be
/// layered back on later.
struct Storage {
    private let fm = FileManager.default
    private var root: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Numinous", isDirectory: true)
    }
    private var file: URL { root.appendingPathComponent("store.json") }

    /// The on-disk store file (exposed for backup/export).
    var fileURL: URL { file }

    init() { try? fm.createDirectory(at: root, withIntermediateDirectories: true) }

    func load() -> StoredData? {
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode(StoredData.self, from: data) else { return nil }
        return decoded
    }

    func save(_ data: StoredData) {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        try? encoded.write(to: file, options: .atomic)
    }
}
