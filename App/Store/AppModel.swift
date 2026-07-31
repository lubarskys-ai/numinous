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
/// A signal that a new connection just formed, and which axis it lit up. Carries
/// a fresh id each time so the UI re-fires even for the same axis twice in a row.
struct ConnectionSpark: Equatable {
    let id: UUID
    let axisID: String
}

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

    /// Visual maturity, 0→1 — the single value both the avatar and companion read,
    /// so they evolve in lockstep. Deliberately *very slow and connection-intensive*:
    /// driven by the uncapped thesis total (dominated by cross-axis links + breadth
    /// bonuses), so the body only forms after *many* connections. Reaching the body
    /// stage (~0.42) takes on the order of 1500 points ≈ dozens of cross-axis links.
    /// Fully formed only after this many connections — deliberately a lot, so the
    /// avatar spends a long time as scattered nodes slowly drifting together.
    static let maturityFullAtLinks = 120.0
    var maturity: Double {
        let connections = score.links.filter { $0.isCounted }.count
        return min(1, Double(connections) / Self.maturityFullAtLinks)
    }

    private let engine = ScoreEngine()
    private let storage = Storage()
    private let classifier = AxisClassifier()

    init() {
        let loaded = storage.load()
        var f = loaded?.folders.isEmpty == false ? loaded!.folders : SampleData.folders
        var n = loaded?.notes.isEmpty == false ? loaded!.notes : SampleData.notes
        var a = (loaded?.axes.isEmpty == false) ? loaded!.axes : Axis.defaultSet

        let version = loaded?.schemaVersion ?? 0
        var didMigrate = false
        if version < 1, Self.migrateContactsToDormantMarkdown(&n) { didMigrate = true }
        if version < 2, Self.migrateDiaryUnderNotes(&n, &f) { didMigrate = true }
        if version < 3, Self.migrateAddMeaningAxis(&a) { didMigrate = true }
        if version < 4, Self.migrateAddGutAxis(&a) { didMigrate = true }

        self.folders = f
        self.notes = n
        self.axes = a
        self.reflectionLog = loaded?.reflections ?? []
        self.followUps = loaded?.followUps ?? []
        self.readwiseToken = UserDefaults.standard.string(forKey: Self.readwiseTokenKey)
        self.score = ScoreEngine().score(notes: n, folders: f, axes: a)
        if loaded == nil || didMigrate || version < Self.schemaVersion {
            storage.save(StoredData(notes: n, folders: f, axes: a, schemaVersion: Self.schemaVersion,
                                    reflections: reflectionLog, followUps: followUps))
        }
        // Reward any follow-ups you've since completed in iOS Reminders.
        Task { await checkFollowUps() }
    }

    static let schemaVersion = 4

    /// One-time (v3): add the right-brain `meaning` axis to installs that stored
    /// the original four, placing it just after `mind` (its left-brain twin).
    private static func migrateAddMeaningAxis(_ axes: inout [Axis]) -> Bool {
        guard !axes.contains(where: { $0.id == "meaning" }) else { return false }
        if let mindIndex = axes.firstIndex(where: { $0.id == "mind" }) {
            axes.insert(.meaning, at: mindIndex + 1)
        } else {
            axes.append(.meaning)
        }
        return true
    }

    /// One-time (v4): add the `gut` (gut-biome) axis, placed just after `body`
    /// (its fellow physical axis; fed by nutrition data via HealthKit).
    private static func migrateAddGutAxis(_ axes: inout [Axis]) -> Bool {
        guard !axes.contains(where: { $0.id == "gut" }) else { return false }
        if let bodyIndex = axes.firstIndex(where: { $0.id == "body" }) {
            axes.insert(.gut, at: bodyIndex + 1)
        } else {
            axes.append(.gut)
        }
        return true
    }

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

    /// A suggested connection plus a human reason for why we're proposing it.
    struct Suggestion: Identifiable {
        let note: Note
        let reason: String
        var id: UUID { note.id }
    }

    /// Generative connection suggestions, strongest signal first:
    ///  1. **Who you were with** — people linked by a calendar event that overlaps
    ///     this note's time. A workout at 8am that overlaps "Run with [[people/Sam]]"
    ///     proposes Sam even though Sam's own note isn't dated to today. This is the
    ///     strongest signal (a real event places you two together) and, for a
    ///     workout, a Body↔Heart cross-axis link.
    ///  2. **Around this time** — any other real note near this one in time, not
    ///     already linked, cross-axis first (co-occurrence you confirm with a tap).
    func connectionSuggestions(for note: Note, within hours: Double = 18) -> [Suggestion] {
        guard !note.isStub else { return [] }
        let noteKey = Self.norm(note.title)
        let noteAxis = axis(for: note)?.id
        let window = hours * 3600
        var out: [Suggestion] = []
        var seen: Set<UUID> = [note.id]

        func alreadyConnected(_ other: Note) -> Bool {
            if note.linkTargets.contains(where: { Self.norm($0) == Self.norm(other.title) }) { return true }
            if other.linkTargets.contains(where: { Self.norm($0) == noteKey }) { return true }
            return false
        }

        // 1. People placed with you by a time-overlapping calendar event.
        let calendarNotes = notes.filter {
            $0.origin?.source == "calendar" && abs($0.date.timeIntervalSince(note.date)) <= window
        }
        for event in calendarNotes {
            for target in event.linkTargets {
                guard let person = self.note(titled: target),
                      !person.isStub, axis(for: person) != nil,
                      !seen.contains(person.id), !alreadyConnected(person) else { continue }
                seen.insert(person.id)
                out.append(Suggestion(note: person, reason: "With you at \(event.displayName)"))
            }
        }

        // 2. Other real notes near this one in time (cross-axis first).
        let temporal = notes.filter { other in
            guard !seen.contains(other.id), !other.isStub, axis(for: other) != nil else { return false }
            if alreadyConnected(other) { return false }
            return abs(other.date.timeIntervalSince(note.date)) <= window
        }.sorted { a, b in
            let aSame = (axis(for: a)?.id == noteAxis) ? 1 : 0
            let bSame = (axis(for: b)?.id == noteAxis) ? 1 : 0
            if aSame != bSame { return aSame < bSame }
            return abs(a.date.timeIntervalSince(note.date)) < abs(b.date.timeIntervalSince(note.date))
        }
        for other in temporal {
            out.append(Suggestion(note: other, reason: "Around this time"))
        }

        return Array(out.prefix(5))
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

    /// Import Readwise books (Kindle + others) into type folders under Mind,
    /// idempotent by `user_book_id`. Highlights — and any `[[link]]` inside them —
    /// go into the body verbatim so they become real connections. Intensity is
    /// graded per book (type + engagement + genre); the folder carries the type's
    /// base as its default so new same-type notes inherit it.
    @discardableResult
    func importReadwise(_ books: [ReadwiseBook]) -> (added: Int, updated: Int) {
        let items: [ImportedItem] = books.compactMap { book in
            let title = (book.title ?? book.readableTitle)?
                .replacingOccurrences(of: "/", with: "-")
                .trimmingCharacters(in: .whitespaces)
            guard let title, !title.isEmpty else { return nil }
            let folder = ReadwiseService.folder(book.category)
            var details: [NoteDetail] = []
            if let author = book.author?.trimmingCharacters(in: .whitespaces), !author.isEmpty {
                details.append(NoteDetail(key: "Author", value: author))
            }
            if let cover = book.coverImageUrl?.trimmingCharacters(in: .whitespaces), !cover.isEmpty {
                details.append(NoteDetail(key: "Cover", value: cover))
            }
            return ImportedItem(
                folder: folder, name: title, body: Self.readwiseBody(book),
                details: details,
                date: Self.readwiseDate(book),
                intensity: ReadwiseService.intensity(for: book),
                origin: NoteOrigin(source: "readwise", externalID: String(book.userBookId)),
                folderCategory: "Ideas", folderAxisID: "mind",
                // A book grows you only once you've *finished* it — import dormant
                // (zero growth) and let the reader mark it finished. Volume of an
                // unread library must not inflate Mind.
                isDormant: true
            )
        }
        let result = ingest(items)
        // Let the type's base intensity be the folder default (retunable per-folder).
        for category in Set(books.map { $0.category ?? "books" }) {
            let folder = ReadwiseService.folder(category)
            if self.folder(named: folder)?.defaultIntensity == nil {
                setFolderIntensity(ReadwiseService.typeBase(category), forFolder: folder)
            }
        }
        return result
    }

    /// Date a book by its most recent highlight, so it lands in your timeline when
    /// you actually read it (making "around this time" suggestions meaningful).
    /// Falls back to now when no highlight carries a timestamp.
    private static let readwiseDateFormatter = ISO8601DateFormatter()
    private static func readwiseDate(_ book: ReadwiseBook) -> Date {
        let dates = (book.highlights ?? []).compactMap { h -> Date? in
            guard let stamp = h.highlightedAt else { return nil }
            return readwiseDateFormatter.date(from: stamp)
        }
        return dates.max() ?? Date()
    }

    /// Markdown body for a Readwise book: summary, then each highlight as a
    /// blockquote with your note beneath it (links preserved as written). Author
    /// and cover live in the note's metadata, not the body.
    private static func readwiseBody(_ book: ReadwiseBook) -> String {
        var lines: [String] = []
        if let summary = book.summary?.trimmingCharacters(in: .whitespaces), !summary.isEmpty {
            lines.append(summary)
        }
        let highlights = (book.highlights ?? []).sorted { ($0.location ?? 0) < ($1.location ?? 0) }
        if !highlights.isEmpty {
            lines.append("")
            for h in highlights {
                let text = (h.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let note = h.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !text.isEmpty || !note.isEmpty else { continue }
                if !text.isEmpty { lines.append("> \(text)") }
                // Your own annotation on the highlight, tied to it (links preserved).
                if !note.isEmpty { lines.append("📝 \(note)") }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Readwise connection

    /// The saved Readwise access token (nil until the user connects). Stored in
    /// UserDefaults for now — fine for a personal build; move to Keychain before
    /// shipping since it's a credential.
    @Published private(set) var readwiseToken: String?
    private static let readwiseTokenKey = "readwise_token"

    var isReadwiseConnected: Bool { !(readwiseToken ?? "").isEmpty }

    func setReadwiseToken(_ token: String?) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        readwiseToken = (trimmed?.isEmpty == false) ? trimmed : nil
        if let readwiseToken {
            UserDefaults.standard.set(readwiseToken, forKey: Self.readwiseTokenKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.readwiseTokenKey)
        }
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

    /// Create (or re-open) a note from a health activity. Workouts grow Body,
    /// mindful sessions grow Spirit, nutrition grows Gut. Idempotent by sample id.
    func createNote(from item: HealthItem) -> UUID? {
        let (folder, category, axis): (String, String, String)
        switch item.kind {
        case .workout:   (folder, category, axis) = ("health/workouts", "Fitness", "body")
        case .mindful:   (folder, category, axis) = ("health/mindful", "Mindfulness", "spirit")
        case .nutrition: (folder, category, axis) = ("health/nutrition", "Nutrition", "gut")
        }

        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        let name = "\(item.title) · \(Self.shortDate(item.start))"
        let body: String
        if item.kind == .nutrition {
            body = "\(Self.shortDate(item.start))\n🍽 \(item.detail ?? "")"
        } else {
            body = "\(df.string(from: item.start))\n⏱ \(max(1, Int(item.duration / 60))) min"
        }

        let imported = ImportedItem(
            folder: folder, name: name, body: body, date: item.start,
            origin: NoteOrigin(source: "healthkit", externalID: item.id),
            folderCategory: category, folderAxisID: axis, isDormant: false
        )
        ingest([imported])
        return notes.first { $0.origin?.source == "healthkit" && $0.origin?.externalID == item.id }?.id
    }

    private static func shortDate(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: date)
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
        folders[i].axisIDs = nil     // single-axis
        persist()
    }

    /// Add or remove an axis from a folder's growth set (a folder can grow several
    /// axes; each note's growth is split evenly among them). Keeps `axisID` synced
    /// to the primary for color/display.
    func toggleFolderAxis(_ axisID: String, forFolder name: String) {
        let id = Folder.normalize(name)
        guard let i = folders.firstIndex(where: { $0.id == id }) else {
            upsertFolder(name: name, category: name.capitalized, axisID: axisID)
            return
        }
        var set = folders[i].growthAxes
        if let idx = set.firstIndex(of: axisID) { set.remove(at: idx) } else { set.append(axisID) }
        folders[i].axisIDs = set.isEmpty ? nil : set
        folders[i].axisID = set.first
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
        storage.save(StoredData(notes: notes, folders: folders, axes: axes,
                                schemaVersion: Self.schemaVersion, reflections: reflectionLog,
                                followUps: followUps))
    }

    // MARK: - Follow-ups (the CRM loop: set a reminder → do it → grow)

    /// Reminders set from notes; completing one in iOS rewards the follow-through.
    @Published private(set) var followUps: [FollowUp] = []

    /// Record a follow-up reminder so we can reward it once completed.
    func recordFollowUp(reminderID: String, noteTitle: String, title: String, due: Date) {
        followUps.append(FollowUp(reminderID: reminderID, noteTitle: noteTitle, title: title, due: due))
        persist()
    }

    /// Ask iOS which pending follow-ups have been completed, and reward each.
    func checkFollowUps() async {
        let pending = followUps.filter { !$0.rewarded }
        guard !pending.isEmpty else { return }
        let done = await ReminderService.completed(of: pending.map(\.reminderID))
        for fu in pending where done.contains(fu.reminderID) { rewardFollowUp(fu) }
    }

    /// You did the thing you meant to → a verified "reconnected" note that grows
    /// Heart and links the person, and the avatar celebrates.
    private func rewardFollowUp(_ fu: FollowUp) {
        guard let idx = followUps.firstIndex(where: { $0.reminderID == fu.reminderID }) else { return }
        followUps[idx].rewarded = true
        let personName = fu.noteTitle.split(separator: "/").last.map(String.init) ?? fu.noteTitle
        ingest([ImportedItem(
            folder: "notes/reconnections",
            name: "Reconnected with \(personName) · \(Self.shortDate(Date()))",
            body: "[[\(fu.noteTitle)]]\nFollowed up ✓ — you set a reminder and did it.",
            date: Date(),
            origin: NoteOrigin(source: "followup", externalID: fu.reminderID),
            folderCategory: "Connections", folderAxisID: "heart", isDormant: false
        )])
        spark = ConnectionSpark(id: UUID(), axisID: "heart")   // companion cheers
        persist()
    }

    // MARK: - Reflections (the app noticing things about your web)

    /// Log of reflections already surfaced — drives variation + continuity.
    @Published private(set) var reflectionLog: [ReflectionRecord] = []
    private let reflectionEngine = ReflectionEngine()
    /// Don't repeat the same observation within this window.
    private static let reflectionCooldown: TimeInterval = 6 * 24 * 3600

    /// The reflection to show right now, if any: the most resonant grounded
    /// observation not surfaced within the cooldown, phrased warmly. Returns nil
    /// when there's nothing new worth saying (the app stays quiet rather than
    /// repeating itself).
    func currentReflection(now: Date = Date()) -> ReflectionRecord? {
        let recent = Set(reflectionLog
            .filter { now.timeIntervalSince($0.date) < Self.reflectionCooldown }
            .map(\.signature))
        let observations = reflectionEngine.observe(notes: notes, folders: folders, axes: axes, result: score)
        guard let pick = observations.first(where: { !recent.contains($0.signature) }) else { return nil }
        let text = ReflectionPhrasing.text(for: pick, axes: axes, notes: notes, history: reflectionLog)
        return ReflectionRecord(signature: pick.signature, text: text, date: now)
    }

    /// Mark a reflection as seen so the next one can surface next time.
    func acknowledgeReflection(_ record: ReflectionRecord) {
        reflectionLog.append(record)
        if reflectionLog.count > 50 { reflectionLog.removeFirst(reflectionLog.count - 50) }
        persist()
    }

    /// Edit a note's markdown body. Engaging a dormant/imported note (writing
    /// about it, adding [[links]]) activates it so it starts growing you.
    func updateBody(_ id: UUID, body: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        let oldTargets = Set(notes[i].linkTargets.map { Self.norm($0) })
        notes[i].body = body
        // Editing a note engages it — except a Readwise book, which counts only
        // once you mark it finished (adding links to highlights mustn't do it).
        if notes[i].origin?.source != "readwise" { notes[i].isStub = false }
        // A new connection just formed → spark the matching axis: a person beats
        // the heart, a book/idea lights the mind.
        let added = Set(notes[i].linkTargets.map { Self.norm($0) }).subtracting(oldTargets)
        if !added.isEmpty {
            let noteIsPerson = Folder.normalize(notes[i].folderName) == "people"
            let addedAxes = added.compactMap { target -> String? in
                folders.first { $0.id == Self.targetFolder(target) }?.axisID
            }
            var sparkAxis = addedAxes.first { $0 == "heart" } ?? addedAxes.first { $0 == "mind" }
            if sparkAxis == nil, noteIsPerson { sparkAxis = "heart" }
            if let sparkAxis { spark = ConnectionSpark(id: UUID(), axisID: sparkAxis) }
        }
        for target in notes[i].linkTargets where !noteExists(titled: target) {
            notes.append(Note(title: target, date: notes[i].date, isStub: true))
        }
        persist()
    }

    /// Create a fresh diary entry auto-titled with the current date & time, filed
    /// under `notes/diary` (Journal → Spirit), and return its id so the UI can open
    /// it straight into writing. Titles are made unique if two land in one minute.
    func createDiaryEntry() -> UUID {
        if folder(named: "notes/diary") == nil {
            folders.append(Folder(name: "notes/diary", category: "Journal", axisID: "spirit", defaultIntensity: 4))
        }
        let base = "notes/diary/" + Self.dateTimeStamp()
        var title = base, n = 2
        while notes.contains(where: { Self.norm($0.title) == Self.norm(title) }) { title = "\(base) (\(n))"; n += 1 }
        let note = Note(title: title, date: Date(), intensity: defaultIntensity(forFolderNamed: "notes/diary"))
        notes.append(note)
        persist()
        return note.id
    }

    private static func dateTimeStamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date())
    }

    // MARK: - Capture (dictate/type → auto-linked note)

    /// Suggested wikilinks for free text — the names of notes you already have.
    func autolinkSuggestions(in text: String) -> [AutoLinker.Suggestion] {
        AutoLinker().suggest(in: text, candidates: notes.map { (name: $0.displayName, target: $0.title) })
    }

    /// Create a note from captured (spoken or typed) text, titled from its opening
    /// words and filed under `notes`. Links inside the body grow you as usual.
    @discardableResult
    func createCapturedNote(body: String) -> UUID {
        let firstLine = body.split(separator: "\n").first.map(String.init) ?? body
        let words = firstLine.split(separator: " ").prefix(6).joined(separator: " ")
        let cleaned = words.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let base = "notes/" + (cleaned.isEmpty ? "Note " + Self.dateTimeStamp() : cleaned)
        var title = base, n = 2
        while notes.contains(where: { Self.norm($0.title) == Self.norm(title) }) { title = "\(base) (\(n))"; n += 1 }
        let note = Note(title: title, date: Date(), body: body, intensity: 3)
        save(note)   // also creates stubs for any [[links]]
        return note.id
    }

    /// The folder segment of a `[[folder/Name]]` link target ("" if unqualified).
    private static func targetFolder(_ normedTarget: String) -> String {
        let parts = normedTarget.split(separator: "/")
        return parts.count >= 2 ? String(parts[0]) : ""
    }

    /// Fires each time a fresh connection is made, carrying which axis it touched
    /// so the UI can play the matching flourish (heart beat, mind's light, …).
    @Published private(set) var spark: ConnectionSpark?

    /// Mark a book finished (or un-finish it). A finished book leaves dormancy and
    /// starts counting — base credit plus any cross-axis links in its highlights.
    func setFinished(_ id: UUID, _ finished: Bool) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].isStub = !finished
        persist()
    }

    private static func norm(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
