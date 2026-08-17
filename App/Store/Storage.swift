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
    /// Folder paths the user created explicitly (empty), so they're kept even with no notes
    /// yet — otherwise the empty-folder prune would remove them. Optional = back-compat.
    var manualFolders: [String]? = nil
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
    /// Serial background queue for all store writes. Encoding a large store to JSON and
    /// writing it is far too slow to run on the main thread on every change — doing it
    /// here keeps the UI responsive, and serial ordering means writes never interleave.
    private static let ioQueue = DispatchQueue(label: "com.lubarskys.numinous.storage-io", qos: .utility)
    // Coalescing: rapid saves (e.g. during import/sync) must NOT pile up a backlog of
    // whole-store encodes on the background queue — that saturates a CPU core and makes
    // the app feel slow. We keep only the *latest* pending snapshot and run at most one
    // encode at a time; intermediate saves are dropped (each write is the full store, so
    // only the last one matters).
    private static let pendingLock = NSLock()
    private static var pendingSnapshot: StoredData?
    private static var isWriting = false
    private let fm = FileManager.default
    private var root: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Numinous", isDirectory: true)
    }
    private var file: URL { root.appendingPathComponent("store.json") }

    /// The on-disk store file (exposed for backup/export).
    var fileURL: URL { file }

    init() { try? fm.createDirectory(at: root, withIntermediateDirectories: true) }

    func load() -> StoredData? {
        guard let data = try? Data(contentsOf: file) else { return nil }   // no file yet → first launch
        if let decoded = try? JSONDecoder().decode(StoredData.self, from: data) { return decoded }
        // The file exists but won't decode (e.g. a future schema change). NEVER silently drop
        // it: the app would then seed sample data and overwrite it. Back the raw bytes up first
        // so real data is recoverable instead of lost.
        let backup = root.appendingPathComponent("store.corrupt-\(Int(Date().timeIntervalSince1970)).json")
        try? data.write(to: backup)
        return nil
    }

    /// Persist the store off the main thread, coalescing bursts. `data` is an immutable
    /// snapshot; only the latest pending one is written, and at most one encode runs at a
    /// time — so a flurry of saves can't back up a queue of whole-store encodes.
    func save(_ data: StoredData) {
        let file = self.file
        Self.pendingLock.lock()
        Self.pendingSnapshot = data
        let shouldStart = !Self.isWriting
        if shouldStart { Self.isWriting = true }
        Self.pendingLock.unlock()
        guard shouldStart else { return }
        Self.ioQueue.async {
            while true {
                Self.pendingLock.lock()
                guard let next = Self.pendingSnapshot else { Self.isWriting = false; Self.pendingLock.unlock(); return }
                Self.pendingSnapshot = nil
                Self.pendingLock.unlock()
                if let encoded = try? JSONEncoder().encode(next) {
                    try? encoded.write(to: file, options: .atomic)
                }
            }
        }
    }

    /// Synchronously encode + write the store (blocking). Used when the app is going to
    /// the background, so a change made right before backgrounding can't be lost to an
    /// in-flight async write.
    func saveSync(_ data: StoredData) {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        try? encoded.write(to: file, options: .atomic)
    }

    /// Encode `data` synchronously to a JSON file at `dest` (for user-initiated export,
    /// where the file must exist immediately for sharing). Returns success.
    @discardableResult
    func writeSnapshot(_ data: StoredData, to dest: URL) -> Bool {
        guard let encoded = try? JSONEncoder().encode(data) else { return false }
        do { try encoded.write(to: dest, options: .atomic); return true } catch { return false }
    }

    /// Write a store snapshot into a security-scoped backup folder (resolved from
    /// `bookmark`) under each filename — all on the background queue, keeping the scoped
    /// access alive for the whole write. `staleRefresh` is called on the main thread if
    /// the bookmark needs refreshing. Used for automatic backups to a user-chosen iCloud
    /// Drive folder, so a copy survives even if the app is deleted.
    func backup(_ data: StoredData, resolving bookmark: Data, filenames: [String],
                staleRefresh: @escaping (Data) -> Void) {
        Self.ioQueue.async {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let encoded = try? JSONEncoder().encode(data) else { return }
            for name in filenames {
                try? encoded.write(to: url.appendingPathComponent(name), options: .atomic)
            }
            if stale, let refreshed = try? url.bookmarkData() {
                DispatchQueue.main.async { staleRefresh(refreshed) }
            }
        }
    }
}
