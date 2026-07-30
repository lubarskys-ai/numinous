import Foundation
import Combine
import NuminousCore

/// A folder's notes, for grouped display. A struct (not a tuple) so it's
/// `Identifiable` and usable directly in `ForEach`.
struct FolderGroup: Identifiable {
    let id: String       // folder path ("" = Unfiled)
    let notes: [Note]
}

/// A normalized item any import source (Contacts, Calendar, Health…) produces.
/// `AppModel.ingest` upserts these into notes idempotently by `origin`, creating
/// the target folder if needed. Adding a new source means mapping it to these.
struct ImportedItem {
    var folder: String
    var name: String
    var body: String = ""
    var details: [NoteDetail] = []
    var date: Date = Date()
    var intensity: Int = 3
    var origin: NoteOrigin
    var folderCategory: String
    var folderAxisID: String?
    /// Imported-but-not-yet-engaged (e.g. a bare contact). Dormant notes are
    /// linkable/searchable but grant *zero* growth until you actually engage —
    /// so importing your whole address book can't inflate an axis. Growth comes
    /// from connection, not volume.
    var isDormant: Bool = false
}

/// The app's single source of truth. Everything the UI shows flows from here;
/// mutations recompute the whole score from scratch (the engine is a pure
/// function), which is what makes remapping a folder's axis reflow all history.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var notes: [Note] = []
    @Published private(set) var folders: [Folder] = []
    @Published private(set) var axes: [Axis] = Axis.defaultSet
    @Published private(set) var score: ScoreResult

    private let engine = ScoreEngine()
    private let storage = Storage()
    private let classifier = AxisClassifier()

    init() {
        let loaded = storage.load()
        var f = loaded?.folders.isEmpty == false ? loaded!.folders : SampleData.folders
        var n = loaded?.notes.isEmpty == false ? loaded!.notes : SampleData.notes
        let a = (loaded?.axes.isEmpty == false) ? loaded!.axes : Axis.defaultSet

        let version = loaded?.schemaVersion ?? 0
        var didMigrate = false
        if version < 1, Self.migrateContactsToDormantMarkdown(&n) { didMigrate = true }
        if version < 2, Self.migrateDiaryUnderNotes(&n, &f) { didMigrate = true }

        self.folders = f
        self.notes = n
        self.axes = a
        self.score = ScoreEngine().score(notes: n, folders: f, axes: a)
        if loaded == nil || didMigrate || version < Self.schemaVersion {
            storage.save(StoredData(notes: n, folders: f, axes: a, schemaVersion: Self.schemaVersion))
        }
    }

    static let schemaVersion = 2

    /// One-time (v2): make `diary` a subfolder of `notes` (`diary/x` → `notes/diary/x`).
    private static func migrateDiaryUnderNotes(_ notes: inout [Note], _ folders: inout [Folder]) -> Bool {
        var changed = false
        for i in notes.indices where notes[i].folderName == "diary" {
            notes[i].title = "notes/diary/" + notes[i].displayName
            changed = true
        }
        if !folders.contains(where: { $0.id == "notes/diary" }) {
            let old = folders.first { $0.id == "diary" }
            folders.removeAll { $0.id == "diary" }
            folders.append(Folder(name: "notes/diary", category: old?.category ?? "Journal",
                                  axisID: old?.axisID ?? "spirit", defaultIntensity: old?.defaultIntensity ?? 4))
            changed = true
        }
        if !folders.contains(where: { $0.id == "notes" }) {
            folders.append(Folder(name: "notes", category: "Notes", axisID: nil))
            changed = true
        }
        return changed
    }

    /// One-time (v1): older contact imports granted growth just by existing and
    /// stored info as structured details. Convert those details to a markdown
    /// body (so you can add [[links]] inside) and make them dormant.
    private static func migrateContactsToDormantMarkdown(_ notes: inout [Note]) -> Bool {
        var changed = false
        for i in notes.indices where notes[i].origin?.source == "contacts" {
            if notes[i].body.isEmpty && !notes[i].details.isEmpty {
                notes[i].body = notes[i].details.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
                notes[i].details = []
            }
            if !notes[i].isStub { notes[i].isStub = true }
            changed = true
        }
        return changed
    }

    // MARK: - Lookups

    func note(id: UUID) -> Note? { notes.first { $0.id == id } }

    func note(titled title: String) -> Note? {
        let key = Self.norm(title)
        return notes.first { Self.norm($0.title) == key }
    }

    func folder(named name: String) -> Folder? {
        let key = Folder.normalize(name)
        return folders.first { $0.id == key }
    }

    func axis(for note: Note) -> Axis? {
        guard let axisID = folder(named: note.folderName)?.axisID else { return nil }
        return axes.first { $0.id == axisID }
    }

    func axis(id: String?) -> Axis? {
        guard let id else { return nil }
        return axes.first { $0.id == id }
    }

    func noteExists(titled title: String) -> Bool { note(titled: title) != nil }

    func noteID(forCalendarEvent eventID: String) -> UUID? {
        notes.first { $0.origin?.source == "calendar" && $0.origin?.externalID == eventID }?.id
    }

    /// Notes grouped by folder path, folders alphabetized, "Unfiled" last.
    var groupedByFolder: [FolderGroup] {
        let groups = Dictionary(grouping: notes) { $0.folderName }
        return groups.keys.sorted { a, b in
            if a.isEmpty { return false }
            if b.isEmpty { return true }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }.map { key in
            let sorted = (groups[key] ?? []).sorted { a, b in
                if a.date != b.date { return a.date > b.date }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
            return FolderGroup(id: key, notes: sorted)
        }
    }

    /// Notes that link *to* the given note (Obsidian-style backlinks).
    func backlinks(to note: Note) -> [Note] {
        let key = Self.norm(note.title)
        return notes.filter { $0.id != note.id && $0.linkTargets.contains { Self.norm($0) == key } }
    }

    // MARK: - Mutations

    /// Insert or update a note; auto-create untyped stubs for any missing links.
    func save(_ note: Note) {
        if let i = notes.firstIndex(where: { $0.id == note.id }) { notes[i] = note }
        else { notes.append(note) }
        for target in note.linkTargets where !noteExists(titled: target) {
            notes.append(Note(title: target, date: note.date, isStub: true))
        }
        persist()
    }

    func delete(_ toDelete: [Note]) {
        let ids = Set(toDelete.map(\.id))
        notes.removeAll { ids.contains($0.id) }
        persist()
    }

    func addDetail(to noteID: UUID, key: String, value: String) {
        guard let i = notes.firstIndex(where: { $0.id == noteID }) else { return }
        notes[i].details.append(NoteDetail(key: key, value: value))
        persist()
    }

    func addPhoto(to noteID: UUID, data: Data) {
        guard let i = notes.firstIndex(where: { $0.id == noteID }),
              let name = ImageStore.save(data) else { return }
        var photos = notes[i].photos ?? []
        photos.append(name)
        notes[i].photos = photos
        persist()
    }

    func removePhoto(from noteID: UUID, name: String) {
        guard let i = notes.firstIndex(where: { $0.id == noteID }) else { return }
        notes[i].photos?.removeAll { $0 == name }
        ImageStore.delete(name)
        persist()
    }

    func removeDetail(from noteID: UUID, at index: Int) {
        guard let i = notes.firstIndex(where: { $0.id == noteID }),
              notes[i].details.indices.contains(index) else { return }
        notes[i].details.remove(at: index)
        persist()
    }

    @discardableResult
    func upsertFolder(name: String, category: String, axisID: String?) -> Folder {
        let id = Folder.normalize(name)
        if let i = folders.firstIndex(where: { $0.id == id }) {
            folders[i].category = category
            folders[i].axisID = axisID
            persist()
            return folders[i]
        }
        let folder = Folder(name: name, category: category, axisID: axisID)
        folders.append(folder)
        persist()
        return folder
    }

    /// Adds each contact name as a `people/<Name>` note (skipping duplicates).
    // MARK: - Imports (idempotent by origin)

    /// Insert or update notes from any import source, keyed by `origin` so
    /// re-importing updates instead of duplicating. Returns (added, updated).
    @discardableResult
    func ingest(_ items: [ImportedItem]) -> (added: Int, updated: Int) {
        var added = 0, updated = 0
        for item in items {
            if folder(named: item.folder) == nil {
                folders.append(Folder(name: item.folder, category: item.folderCategory, axisID: item.folderAxisID))
            }
            let title = item.folder + "/" + item.name
            if let i = notes.firstIndex(where: { $0.origin == item.origin }) {
                notes[i].title = title
                notes[i].details = Self.mergeDetails(notes[i].details, item.details)
                if notes[i].body.isEmpty {
                    notes[i].body = item.body
                    // Still un-engaged (no body of its own) → keep it dormant.
                    if item.isDormant { notes[i].isStub = true }
                }
                updated += 1
            } else if let i = notes.firstIndex(where: { Self.norm($0.title) == Self.norm(title) && $0.origin == nil }) {
                // Adopt a *hand-made* note with this title rather than duplicate it.
                notes[i].origin = item.origin
                notes[i].details = Self.mergeDetails(notes[i].details, item.details)
                updated += 1
            } else {
                // Disambiguate if a *different* origin already holds this title.
                var uniqueTitle = title, n = 2
                while notes.contains(where: { Self.norm($0.title) == Self.norm(uniqueTitle) }) {
                    uniqueTitle = "\(title) (\(n))"; n += 1
                }
                notes.append(Note(title: uniqueTitle, date: item.date, body: item.body,
                                  intensity: item.intensity, details: item.details,
                                  origin: item.origin, isStub: item.isDormant))
                added += 1
            }
        }
        if added + updated > 0 { persist() }
        return (added, updated)
    }

    /// Import contacts into the People folder (idempotent by contact identifier).
    @discardableResult
    func importContacts(_ contacts: [ImportedContact]) -> (added: Int, updated: Int) {
        let items: [ImportedItem] = contacts.compactMap { contact in
            let name = contact.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            // Info goes into the markdown body so you can open the note and add
            // your own text and [[links]] to it.
            var lines: [String] = []
            if let phone = contact.phones.first { lines.append("Phone: \(phone)") }
            if let email = contact.emails.first { lines.append("Email: \(email)") }
            return ImportedItem(folder: "people", name: name, body: lines.joined(separator: "\n"),
                                origin: NoteOrigin(source: "contacts", externalID: contact.id),
                                folderCategory: "Relationships", folderAxisID: "heart",
                                isDormant: true)
        }
        return ingest(items)
    }

    /// Create (or re-open) a note from a calendar event. Filed under a folder
    /// named after the event's calendar (so multiple calendars become folders);
    /// the body carries the date, location, and [[people/…]] links for attendees.
    /// Returns the note id so the UI can open it. Idempotent by event id.
    func createNote(from event: CalendarEvent) -> UUID? {
        let name = event.title.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = event.isAllDay ? .none : .short
        var lines = [df.string(from: event.start)]
        if let location = event.location, !location.isEmpty { lines.append("📍 \(location)") }
        lines.append("🗓 \(event.calendarTitle)")
        let people = event.attendees
            .map { $0.replacingOccurrences(of: "/", with: "-") }
            .filter { !$0.isEmpty }
            .map { "[[people/\($0)]]" }
        if !people.isEmpty { lines.append("With " + people.joined(separator: ", ")) }

        // All calendar events are a kind of note → filed under notes/calendar.
        let item = ImportedItem(
            folder: "notes/calendar", name: name, body: lines.joined(separator: "\n"), date: event.start,
            origin: NoteOrigin(source: "calendar", externalID: event.id),
            folderCategory: "Calendar", folderAxisID: nil, isDormant: false
        )
        ingest([item])
        return notes.first { $0.origin?.source == "calendar" && $0.origin?.externalID == event.id }?.id
    }

    private static func mergeDetails(_ existing: [NoteDetail], _ incoming: [NoteDetail]) -> [NoteDetail] {
        var result = existing
        for detail in incoming {
            if let i = result.firstIndex(where: { Self.norm($0.key) == Self.norm(detail.key) }) {
                result[i].value = detail.value
            } else {
                result.append(detail)
            }
        }
        return result
    }

    func setFolderAxis(_ axisID: String, forFolder folderID: String) {
        guard let i = folders.firstIndex(where: { $0.id == folderID }) else { return }
        folders[i].axisID = axisID
        persist()
    }

    func setFolderIntensity(_ intensity: Int?, forFolder name: String) {
        if let i = folders.firstIndex(where: { $0.id == Folder.normalize(name) }) {
            folders[i].defaultIntensity = intensity
        } else {
            folders.append(Folder(name: name, category: name.capitalized, axisID: nil, defaultIntensity: intensity))
        }
        persist()
    }

    /// The intensity a new note in this folder should start at (3 if unset).
    func defaultIntensity(forFolderNamed name: String) -> Int {
        folder(named: name)?.defaultIntensity ?? 3
    }

    /// Set a folder's axis, creating the folder mapping if it doesn't exist yet
    /// (e.g. a folder that so far only exists as note paths).
    func assignAxis(toFolder name: String, axisID: String) {
        if let existing = folder(named: name) {
            setFolderAxis(axisID, forFolder: existing.id)
        } else {
            upsertFolder(name: name, category: name.capitalized, axisID: axisID)
        }
    }

    func suggestAxis(forNewFolderNamed name: String) -> AxisClassifier.Suggestion {
        classifier.suggestAxis(forNewFolderNamed: name, existingFolders: folders, axes: axes)
    }

    // Axis customization
    func renameAxis(_ axisID: String, name: String) {
        guard let i = axes.firstIndex(where: { $0.id == axisID }) else { return }
        axes[i].name = name; persist()
    }
    func setAxisColor(_ axisID: String, hex: String) {
        guard let i = axes.firstIndex(where: { $0.id == axisID }) else { return }
        axes[i].colorHex = hex; persist()
    }

    // MARK: - Internals

    private func persist() {
        score = engine.score(notes: notes, folders: folders, axes: axes)
        storage.save(StoredData(notes: notes, folders: folders, axes: axes, schemaVersion: Self.schemaVersion))
    }

    /// Edit a note's markdown body. Engaging a dormant/imported note (writing
    /// about it, adding [[links]]) activates it so it starts growing you.
    func updateBody(_ id: UUID, body: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].body = body
        notes[i].isStub = false
        for target in notes[i].linkTargets where !noteExists(titled: target) {
            notes.append(Note(title: target, date: notes[i].date, isStub: true))
        }
        persist()
    }

    private static func norm(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
