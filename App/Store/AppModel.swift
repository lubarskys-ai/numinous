import Foundation
import Combine
import NuminousCore

/// A folder's notes, for grouped display. A struct (not a tuple) so it's
/// `Identifiable` and usable directly in `ForEach`.
struct FolderGroup: Identifiable {
    let id: String       // folder path ("" = Unfiled)
    let notes: [Note]
}

/// A capture-time link suggestion. `target` is the wikilink target (e.g.
/// `people/Shawna Flanagan`); `surface` is the exact words in the note to replace;
/// `isNew` is true when tapping it will create a brand-new note in that folder.
struct LinkSuggestion: Identifiable, Equatable {
    let id = UUID()
    let name: String       // display name, e.g. "Shawna Flanagan"
    let target: String     // wikilink target, e.g. "people/Shawna Flanagan"
    let surface: String    // exact words in the note to replace ("" if unknown)
    let isNew: Bool         // true → creates a new note on save
    /// Folder path portion of the target ("people", "entertainment/restaurant", …).
    var folderLabel: String {
        guard let slash = target.lastIndex(of: "/") else { return "" }
        return String(target[..<slash])
    }
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
    /// A readable place for this item (e.g. a contact's "City, State") — used for
    /// location-based reconnection.
    var location: String? = nil
    /// On re-import of an existing note, append incoming body lines that aren't already
    /// there (new Readwise highlights) instead of leaving the body untouched — without
    /// clobbering edits/links you've added. Off = keep the old body-if-non-empty behavior.
    var mergeBody: Bool = false
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
    /// Counted connections touching one axis needed for that body region to fully
    /// form. Deliberately high — the avatar should spend a long time as stardust and
    /// only become a solid human form after a *lot* of connection.
    static let maturityFullPerAxis = 350.0

    /// Per-axis maturity 0→1 — how *formed* that body region is, from the counted
    /// connections touching it. Regions grow independently: a neglected axis stays
    /// ethereal (graph-like) while a rich one solidifies.
    func axisMaturity(_ axisID: String) -> Double {
        let n = score.links.filter { $0.isCounted && ($0.axisA == axisID || $0.axisB == axisID) }.count
        return min(1, Double(n) / Self.maturityFullPerAxis)
    }

    /// Overall maturity — the average across axes, so the avatar as a whole forms
    /// slowly and only once growth is *broad* (drives staging + the companion).
    var maturity: Double {
        guard !axes.isEmpty else { return 0 }
        return axes.map { axisMaturity($0.id) }.reduce(0, +) / Double(axes.count)
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
        if version < 5, Self.backfillLinkStubs(&n) { didMigrate = true }
        if version < 6, Self.backfillFolderAxes(n, &f) { didMigrate = true }
        if version < 7, Self.sanitizeAllLinks(&n) { didMigrate = true }
        if version < 8, Self.migrateAddInfluencesAxis(&a) { didMigrate = true }
        if version < 8, Self.migrateAuthorsToLinks(&n, &f) { didMigrate = true }

        self.folders = f
        self.notes = n
        self.axes = a
        self.reflectionLog = loaded?.reflections ?? []
        self.followUps = loaded?.followUps ?? []
        self.linkLearning = loaded?.linkLearning ?? LinkLearning()
        self.readwiseToken = UserDefaults.standard.string(forKey: Self.readwiseTokenKey)
        self.homeLocation = UserDefaults.standard.data(forKey: Self.homeKey)
            .flatMap { try? JSONDecoder().decode(Place.self, from: $0) }
        self.score = ScoreEngine().score(notes: n, folders: f, axes: a)
        recomputeLastTended()
        if loaded == nil || didMigrate || version < Self.schemaVersion {
            storage.save(StoredData(notes: n, folders: f, axes: a, schemaVersion: Self.schemaVersion,
                                    reflections: reflectionLog, followUps: followUps,
                                    linkLearning: linkLearning))
        }
        // Reward any follow-ups you've since completed in iOS Reminders.
        Task { await checkFollowUps() }
        // Silently refresh already-connected sources (contacts, Readwise).
        Task { await autoSync() }
    }

    /// Refresh already-connected import sources on launch/foreground. Idempotent
    /// (matched by id, so no duplicates) and never prompts: contacts sync only when
    /// access is already granted; Readwise only when a token is stored.
    func autoSync() async {
        if ContactsImporter.isAuthorized, let contacts = try? await ContactsImporter.fetchContacts() {
            importContacts(contacts)
        }
        guard let token = readwiseToken else { return }
        do {
            let books = try await ReadwiseService.fetch(token: token)
            let (a, u) = importReadwise(books)
            readwiseStatus = "Last sync: \(a) new, \(u) updated."
        } catch {
            // Don't hide it — a silent failure is exactly why it "wasn't updating".
            readwiseStatus = "Last sync failed — \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    /// Last Readwise sync outcome (or error) — surfaced so a failure isn't invisible.
    @Published private(set) var readwiseStatus: String?

    /// Manually pull Readwise now and return a human-readable result or the real error.
    func syncReadwiseNow() async -> String {
        guard let token = readwiseToken, !token.isEmpty else {
            return "Connect Readwise first — paste your token via Import from Readwise."
        }
        do {
            let books = try await ReadwiseService.fetch(token: token)
            let (a, u) = importReadwise(books)
            readwiseStatus = "Last sync: \(a) new, \(u) updated."
            return "Readwise: \(a) new, \(u) updated — \(books.count) item\(books.count == 1 ? "" : "s") pulled."
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            readwiseStatus = "Last sync failed — \(msg)"
            return "Readwise sync failed: \(msg)"
        }
    }

    static let schemaVersion = 8

    /// One-time (v7): repair any malformed/nested `[[links]]` already in the store.
    private static func sanitizeAllLinks(_ notes: inout [Note]) -> Bool {
        var changed = false
        for i in notes.indices {
            let clean = WikilinkParser.sanitize(notes[i].body)
            if clean != notes[i].body { notes[i].body = clean; changed = true }
        }
        return changed
    }

    /// One-time repair: give existing axis-less folders a sensible default axis, and
    /// create a Folder (with an axis) for any note-folder path that never had one —
    /// so all those imported/linked connections finally count toward growth.
    private static func backfillFolderAxes(_ notes: [Note], _ folders: inout [Folder]) -> Bool {
        var changed = false
        for i in folders.indices where folders[i].axisID == nil && (folders[i].axisIDs?.isEmpty ?? true) {
            if let a = defaultAxis(forFolderNamed: folders[i].name) { folders[i].axisID = a; changed = true }
        }
        var existing = Set(folders.map { $0.id })
        for note in notes {
            let fn = note.folderName
            guard !fn.isEmpty, existing.insert(Folder.normalize(fn)).inserted else { continue }
            folders.append(Folder(name: fn, category: fn.capitalized, axisID: defaultAxis(forFolderNamed: fn)))
            changed = true
        }
        return changed
    }

    /// One-time repair: create a stub note for every `[[link]]` in any body that has
    /// no matching note yet — so links written elsewhere (e.g. Kindle notes synced
    /// via Readwise) populate their folders/files, just like saving does.
    private static func backfillLinkStubs(_ notes: inout [Note]) -> Bool {
        var existing = Set(notes.map { norm($0.title) })
        var toAdd: [(title: String, date: Date)] = []
        for note in notes {
            for target in WikilinkParser.extract(from: note.body) where existing.insert(norm(target)).inserted {
                toAdd.append((target, note.date))
            }
        }
        for item in toAdd { notes.append(Note(title: item.title, date: item.date, isStub: true)) }
        return !toAdd.isEmpty
    }

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

    /// One-time (v8): add the `influences` axis — people who shape you through their
    /// work (book authors, and later podcast hosts, etc.). Placed just before `heart`,
    /// bridging Mind (their ideas) and Heart (them, as people).
    private static func migrateAddInfluencesAxis(_ axes: inout [Axis]) -> Bool {
        guard !axes.contains(where: { $0.id == "influences" }) else { return false }
        if let heartIndex = axes.firstIndex(where: { $0.id == "heart" }) {
            axes.insert(.influences, at: heartIndex)
        } else {
            axes.append(.influences)
        }
        return true
    }

    /// One-time (v8): turn the `Author` metadata on already-imported books into real
    /// `[[authors/Name]]` links in the body, create the author stub notes, and ensure
    /// the `authors` folder feeds the Influences axis. This retroactively connects your
    /// existing library — every book now bridges to its author as a graph node.
    private static func migrateAuthorsToLinks(_ notes: inout [Note], _ folders: inout [Folder]) -> Bool {
        var changed = false
        var existing = Set(notes.map { norm($0.title) })
        var newStubs: [Note] = []
        for i in notes.indices {
            // Books only — article/podcast author fields are noisier (publications,
            // odd formats) and would create junk author nodes.
            guard Folder.normalize(notes[i].folderName) == "books" else { continue }
            guard let authorRaw = notes[i].details.first(where: { $0.key == "Author" })?.value else { continue }
            let targets = authorLinkTargets(from: authorRaw)
            guard !targets.isEmpty else { continue }
            let alreadyLinked = Set(WikilinkParser.extract(from: notes[i].body).map(norm))
            let missing = targets.filter { !alreadyLinked.contains(norm($0)) }
            guard !missing.isEmpty else { continue }
            notes[i].body = prependingAuthorLinks(missing, to: notes[i].body)
            for target in missing where existing.insert(norm(target)).inserted {
                newStubs.append(Note(title: target, date: notes[i].date, isStub: true))
            }
            changed = true
        }
        notes.append(contentsOf: newStubs)
        if changed { ensureAuthorsFolder(&folders) }
        return changed
    }

    /// Ensure the `authors` folder exists and feeds the Influences axis, so author
    /// notes count (once engaged) and render with the right color.
    private static func ensureAuthorsFolder(_ folders: inout [Folder]) {
        guard !folders.contains(where: { $0.id == Folder.normalize("authors") }) else { return }
        folders.append(Folder(name: "authors", category: "Authors", axisID: "influences"))
    }

    /// Split an author string into one target path per author. Only splits on clear
    /// multi-author separators (`;`, `&`, ` and `) — never on commas, which are too
    /// often "Last, First" and would mangle single names. Each name is sanitized into
    /// an `authors/Name` path.
    static func authorLinkTargets(from raw: String) -> [String] {
        let separators = [";", " & ", " and "]
        var parts = [raw]
        for sep in separators {
            parts = parts.flatMap { $0.components(separatedBy: sep) }
        }
        return parts
            .map { $0.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 2 }
            .map { "authors/" + $0 }
    }

    /// Put the author link(s) at the top of a book body as a byline, keeping the rest
    /// of the body (summary + highlights) intact beneath.
    private static func prependingAuthorLinks(_ targets: [String], to body: String) -> String {
        let byline = targets.map { "[[\($0)]]" }.joined(separator: ", ")
        return body.isEmpty ? byline : byline + "\n" + body
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
            // Give the linked folder an axis so this connection counts toward growth.
            ensureCategoryFolder(Self.folderPart(of: target))
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
                if let loc = item.location, notes[i].location?.isEmpty != false { notes[i].location = loc }
                if notes[i].body.isEmpty {
                    notes[i].body = item.body
                    // Still un-engaged (no body of its own) → keep it dormant.
                    if item.isDormant { notes[i].isStub = true }
                } else if item.mergeBody {
                    // Bring in new highlights without discarding your edits/links.
                    notes[i].body = Self.mergeBodies(existing: notes[i].body, incoming: item.body)
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
                                  intensity: item.intensity, location: item.location, details: item.details,
                                  origin: item.origin, isStub: item.isDormant))
                added += 1
            }
        }
        // Auto-create stub notes for any [[links]] inside the imported bodies (e.g.
        // links you wrote in Readwise highlights), so their folders/files appear —
        // exactly as saving a note by hand does.
        for item in items {
            for target in WikilinkParser.extract(from: item.body) where !noteExists(titled: target) {
                notes.append(Note(title: target, date: item.date, isStub: true))
            }
        }
        if added + updated > 0 { persist() }
        return (added, updated)
    }

    /// Import contacts into the `contacts` folder (idempotent by contact identifier).
    /// Kept distinct from `people` — contacts are your address book (met, have their
    /// number); `people` is reserved for names you mention, read, or talk about.
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
            if let place = contact.place { lines.append("📍 \(place)") }
            return ImportedItem(folder: "contacts", name: name, body: lines.joined(separator: "\n"),
                                origin: NoteOrigin(source: "contacts", externalID: contact.id),
                                folderCategory: "Contacts", folderAxisID: "heart",
                                location: contact.place,
                                isDormant: true)
        }
        return ingest(items)
    }

    // MARK: - Reconnect (location-based reconnection)

    /// A nudge to reach out to someone because you're near them (now or on a trip).
    struct ReconnectPrompt: Identifiable, Equatable {
        let id: UUID       // the person's note id
        let name: String
        let place: String  // the place that matched
        let reason: String // "You're here now" / "Trip · Sep 3"
    }

    /// A person and the lowercased text to match places against (their note's location +
    /// body, plus the location of any note that links them).
    struct PersonPlaces: Identifiable { let id: UUID; let name: String; let text: String }

    /// Build the person→place-text index ONCE. A person matches a place only by their OWN
    /// note — its body and its location (so "South Carolina" written anywhere in Jay's own
    /// note is found). We deliberately do NOT pull in the location of other notes that link
    /// them: a diary entry written at some place (where *you* were) must not make the people
    /// it mentions look like they're there too.
    func peopleWithPlaces() -> [PersonPlaces] {
        var out: [PersonPlaces] = []
        for n in notes {
            let f = Folder.normalize(n.folderName)
            guard f == "people" || f == "contacts" else { continue }
            let placeNames = n.allPlaces.map(\.name).joined(separator: " ")
            let text = (n.body + " " + placeNames).lowercased()
            out.append(PersonPlaces(id: n.id, name: n.displayName, text: text))
        }
        return out
    }

    /// Match a place against a prebuilt index — fast enough to run on every keystroke.
    /// A same-city hit ranks above a same-state hit (each labeled with its own reason).
    static func matchPeople(_ index: [PersonPlaces], place: String,
                            cityReason: String, stateReason: String) -> [ReconnectPrompt] {
        let q = place.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 3 else { return [] }
        let (city, code) = splitPlace(place)
        let cityNeedle = city.count >= 3 ? city : nil
        let stateFull = codeToName[code]
        let codeRe = code.count == 2 ? try? NSRegularExpression(pattern: "\\b\(code)\\b") : nil
        let rawNeedle = (q.count >= 4 && q != city) ? q : nil
        var cityHits: [ReconnectPrompt] = [], stateHits: [ReconnectPrompt] = []
        for person in index {
            let t = person.text
            if let cityNeedle, t.contains(cityNeedle) {
                cityHits.append(ReconnectPrompt(id: person.id, name: person.name, place: place, reason: cityReason))
            } else if (stateFull != nil && t.contains(stateFull!)) || (codeRe?.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil) {
                stateHits.append(ReconnectPrompt(id: person.id, name: person.name, place: place, reason: stateReason))
            } else if let rawNeedle, t.contains(rawNeedle) {
                cityHits.append(ReconnectPrompt(id: person.id, name: person.name, place: place, reason: cityReason))
            }
        }
        let byName: (ReconnectPrompt, ReconnectPrompt) -> Bool = { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return cityHits.sorted(by: byName) + stateHits.sorted(by: byName)
    }

    /// From upcoming calendar events with a location, who you know there.
    func tripPrompts(from events: [CalendarEvent]) -> [ReconnectPrompt] {
        let index = peopleWithPlaces()
        let now = Date()
        var out: [ReconnectPrompt] = []
        var seen = Set<UUID>()
        for e in events.filter({ $0.start > now }).sorted(by: { $0.start < $1.start }) {
            guard let loc = e.location, loc.count >= 3 else { continue }
            let d = Self.shortDate(e.start)
            for p in Self.matchPeople(index, place: loc, cityReason: "Trip · \(d)", stateReason: "Trip · \(d) · same state") {
                if seen.insert(p.id).inserted { out.append(p) }
            }
        }
        return out
    }

    /// Split a place string into (city, normalized-state). Handles "City, State", a bare
    /// "State", and a venue address ("123 Main St, Charleston, SC") — last comma part is
    /// the state, the one before it the city.
    static func splitPlace(_ s: String) -> (city: String, state: String) {
        let comps = s.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !comps.isEmpty else { return ("", "") }
        let state = normalizeState(comps[comps.count - 1])
        let city = comps.count >= 2 ? comps[comps.count - 2] : ""
        return (city, state)
    }

    /// Canonicalize a US state to its 2-letter code so "South Carolina" == "SC".
    static func normalizeState(_ s: String) -> String {
        let k = s.trimmingCharacters(in: .whitespaces).lowercased()
        if k.count == 2, Self.stateCodes.contains(k) { return k }
        return Self.stateNameToCode[k] ?? k
    }
    private static let stateNameToCode: [String: String] = [
        "alabama":"al","alaska":"ak","arizona":"az","arkansas":"ar","california":"ca","colorado":"co",
        "connecticut":"ct","delaware":"de","florida":"fl","georgia":"ga","hawaii":"hi","idaho":"id",
        "illinois":"il","indiana":"in","iowa":"ia","kansas":"ks","kentucky":"ky","louisiana":"la",
        "maine":"me","maryland":"md","massachusetts":"ma","michigan":"mi","minnesota":"mn","mississippi":"ms",
        "missouri":"mo","montana":"mt","nebraska":"ne","nevada":"nv","new hampshire":"nh","new jersey":"nj",
        "new mexico":"nm","new york":"ny","north carolina":"nc","north dakota":"nd","ohio":"oh","oklahoma":"ok",
        "oregon":"or","pennsylvania":"pa","rhode island":"ri","south carolina":"sc","south dakota":"sd",
        "tennessee":"tn","texas":"tx","utah":"ut","vermont":"vt","virginia":"va","washington":"wa",
        "west virginia":"wv","wisconsin":"wi","wyoming":"wy","district of columbia":"dc",
    ]
    private static let stateCodes = Set(stateNameToCode.values)
    private static let codeToName: [String: String] = Dictionary(uniqueKeysWithValues: stateNameToCode.map { ($1, $0) })

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
            var authorTargets: [String] = []
            if let author = book.author?.trimmingCharacters(in: .whitespaces), !author.isEmpty {
                details.append(NoteDetail(key: "Author", value: author))
                // Books only: the author becomes a real [[authors/Name]] connection
                // (Influences axis), so each book bridges to its author as a graph node.
                if folder == "books" { authorTargets = Self.authorLinkTargets(from: author) }
            }
            if let cover = book.coverImageUrl?.trimmingCharacters(in: .whitespaces), !cover.isEmpty {
                details.append(NoteDetail(key: "Cover", value: cover))
            }
            let byline = authorTargets.isEmpty ? "" :
                authorTargets.map { "[[\($0)]]" }.joined(separator: ", ") + "\n"
            return ImportedItem(
                folder: folder, name: title, body: byline + Self.readwiseBody(book),
                details: details,
                date: Self.readwiseDate(book),
                intensity: ReadwiseService.intensity(for: book),
                origin: NoteOrigin(source: "readwise", externalID: String(book.userBookId)),
                folderCategory: "Ideas", folderAxisID: "mind",
                mergeBody: true,   // re-sync brings in newly-added highlights
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
        // Author links spawned `authors/…` stub notes via ingest — make sure that
        // folder carries the Influences axis (otherwise it'd land uncategorized).
        if folder(named: "authors") == nil, notes.contains(where: { Folder.normalize($0.folderName) == "authors" }) {
            folders.append(Folder(name: "authors", category: "Authors", axisID: "influences"))
            persist()
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

        // Longer effort grows you more: a workout's / mindful session's intensity scales
        // with its duration (nutrition has no meaningful duration → stays neutral).
        let intensity = item.kind == .nutrition ? 3 : Self.intensityForDuration(item.duration)

        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        let name = "\(item.title) · \(Self.shortDate(item.start))"
        let body: String
        if item.kind == .nutrition {
            body = "\(Self.shortDate(item.start))\n🍽 \(item.detail ?? "")"
        } else {
            let mins = max(1, Int(item.duration / 60))
            body = "\(df.string(from: item.start))\n⏱ \(mins) min · \(Self.intensityLabel(intensity)) effort"
        }

        let imported = ImportedItem(
            folder: folder, name: name, body: body, date: item.start, intensity: intensity,
            origin: NoteOrigin(source: "healthkit", externalID: item.id),
            folderCategory: category, folderAxisID: axis, isDormant: false
        )
        ingest([imported])
        return notes.first { $0.origin?.source == "healthkit" && $0.origin?.externalID == item.id }?.id
    }

    /// Map an activity's duration to a 2…5 growth intensity — the longer you were at it,
    /// the more it counts. Tunable thresholds (minutes): <10 light · 10–29 present ·
    /// 30–59 vivid · 60+ profound. A short token effort still grows you, just gently.
    static func intensityForDuration(_ seconds: TimeInterval) -> Int {
        switch seconds / 60 {
        case ..<10:  return 2
        case ..<30:  return 3
        case ..<60:  return 4
        default:     return 5
        }
    }

    /// Human word for an intensity level (matches the composer's scale).
    static func intensityLabel(_ i: Int) -> String {
        switch i {
        case ...1: return "faint"
        case 2:    return "light"
        case 3:    return "present"
        case 4:    return "vivid"
        default:   return "profound"
        }
    }

    private static func shortDate(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    /// Append incoming lines that aren't already in `existing` (case/space-insensitive),
    /// preserving the existing body verbatim — so a Readwise re-sync adds new highlights
    /// without touching the ones you've annotated or linked.
    static func mergeBodies(existing: String, incoming: String) -> String {
        let have = Set(existing.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        var out = existing
        for raw in incoming.split(separator: "\n", omittingEmptySubsequences: false) {
            let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty, !have.contains(key) else { continue }
            out += (out.hasSuffix("\n") || out.isEmpty ? "" : "\n") + raw
        }
        return out
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

    // MARK: - Rename / move (keeps every link pointing at the note)

    /// Rename or move a single note to `newTitleRaw` (e.g. `travel/restaurant/Dunkin`).
    /// Every `[[link]]` that pointed at the old title is rewritten, and if a note
    /// already lives at the new title the two are merged — no orphan left behind.
    func renameNote(_ id: UUID, to newTitleRaw: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        let old = notes[i].title
        let new = newTitleRaw.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, Self.norm(new) != Self.norm(old) else { return }
        ensureFolderExists(for: new, like: old)
        retitle([(old, new)])
        // Named into a place folder (e.g. travel/restaurant/Dunkin) → make the pin match
        // the new name, overriding any earlier auto-GPS guess (explicit naming wins).
        if let note = note(id: id), Self.isPlaceLikeFolder(note.folderName) {
            Task { await setPlaceFromName(id) }
        }
    }

    /// Set a place note's pin from its NAME (geocoded, biased to nearby), replacing an
    /// existing auto-derived location — so renaming a note to a place moves its pin to
    /// match. No-op if the name doesn't resolve to a real place (keeps what's there).
    func setPlaceFromName(_ id: UUID) async {
        guard let note = note(id: id), Self.isPlaceLikeFolder(note.folderName) else { return }
        let name = note.displayName
        // Already matches the name → nothing to do.
        if note.allPlaces.first?.name.caseInsensitiveCompare(name) == .orderedSame,
           note.allPlaces.first?.hasCoordinate == true { return }
        let near = autoLocator.isAuthorized ? await autoLocator.currentCoordinate() : nil
        guard let c = await LocationService.coordinate(for: name, near: near),
              let i = notes.firstIndex(where: { $0.id == id }) else { return }
        commitPlaces([Place(name: name, latitude: c.latitude, longitude: c.longitude)], to: i)
    }

    /// Rename or move a folder path (e.g. `entertainment/restaurant` →
    /// `travel/restaurant`): every note under it (and its subfolders) moves, its
    /// links are rewritten, and the folder's settings carry over to the new path.
    func renameFolder(from oldPathRaw: String, to newPathRaw: String) {
        let oldPath = oldPathRaw.trimmingCharacters(in: .whitespaces)
        let newPath = newPathRaw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !oldPath.isEmpty, !newPath.isEmpty, Self.norm(oldPath) != Self.norm(newPath) else { return }

        let prefix = oldPath + "/"
        let pairs: [(String, String)] = notes.compactMap { note in
            guard Self.norm(note.title) == Self.norm(oldPath) || note.title.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
            let suffix = note.title.count >= oldPath.count ? String(note.title.dropFirst(oldPath.count)) : ""
            return (note.title, newPath + suffix)
        }
        guard !pairs.isEmpty else { return }

        // Carry the folder's settings to the new path (category, axes, intensity).
        if let f = folder(named: oldPath) {
            if folder(named: newPath) == nil {
                folders.append(Folder(id: Folder.normalize(newPath), name: newPath,
                                      category: f.category, axisID: f.axisID,
                                      axisIDs: f.axisIDs, defaultIntensity: f.defaultIntensity))
            }
            folders.removeAll { $0.id == f.id }
        }
        retitle(pairs)
    }

    /// Move a single note into `folderPath` (e.g. drag-and-drop onto a folder). Retitles
    /// it to `folderPath/name`, rewrites every `[[link]]` to it, seeds the destination
    /// folder's metadata if it's brand-new, and merges if a same-named note already lives
    /// there. Returns false if the note is missing or already in that folder.
    @discardableResult
    func moveNote(_ id: UUID, toFolder folderPath: String) -> Bool {
        guard let note = notes.first(where: { $0.id == id }) else { return false }
        let dest = folderPath.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let newTitle = dest.isEmpty ? note.displayName : dest + "/" + note.displayName
        guard Self.norm(newTitle) != Self.norm(note.title) else { return false }
        ensureFolderExists(for: newTitle, like: note.title)
        retitle([(old: note.title, new: newTitle)])
        return true
    }

    /// Apply a set of title changes, rewrite all links, then merge any collisions.
    private func retitle(_ pairs: [(old: String, new: String)]) {
        var map: [String: String] = [:]          // normalized old → new
        for p in pairs { map[Self.norm(p.old)] = p.new }
        for i in notes.indices {
            if let new = map[Self.norm(notes[i].title)] { notes[i].title = new }
        }
        for i in notes.indices where notes[i].body.contains("[[") {
            let rewritten = WikilinkParser.rewrite(in: notes[i].body) { map[Self.norm($0)] ?? $0 }
            if rewritten != notes[i].body { notes[i].body = rewritten }
        }
        dedupeByTitle()
        persist()
    }

    /// If moving a note into a folder that has no metadata yet, seed it from the
    /// old folder so the note keeps its category/axis instead of going "uncategorized".
    private func ensureFolderExists(for newTitle: String, like oldTitle: String) {
        let newFolder = Self.folderPart(of: newTitle)
        guard !newFolder.isEmpty, folder(named: newFolder) == nil else { return }
        if let src = folder(named: Self.folderPart(of: oldTitle)) {
            folders.append(Folder(id: Folder.normalize(newFolder), name: newFolder,
                                  category: src.category, axisID: src.axisID,
                                  axisIDs: src.axisIDs, defaultIntensity: src.defaultIntensity))
        }
    }

    /// The folder path portion of a note title (`travel/restaurant/Dunkin` → `travel/restaurant`).
    private static func folderPart(of title: String) -> String {
        guard let slash = title.lastIndex(of: "/") else { return "" }
        return String(title[..<slash])
    }

    /// Merge notes that now share a title (after a move collided with an existing
    /// note): keep the richer one (engaged/non-stub, then longer body).
    private func dedupeByTitle() {
        var keptIndexByTitle: [String: Int] = [:]
        var dropIDs: [UUID] = []
        for i in notes.indices {
            let key = Self.norm(notes[i].title)
            guard let kept = keptIndexByTitle[key] else { keptIndexByTitle[key] = i; continue }
            if Self.richer(notes[i], than: notes[kept]) {
                dropIDs.append(notes[kept].id); keptIndexByTitle[key] = i
            } else {
                dropIDs.append(notes[i].id)
            }
        }
        if !dropIDs.isEmpty {
            let drop = Set(dropIDs)
            notes.removeAll { drop.contains($0.id) }
        }
    }

    private static func richer(_ a: Note, than b: Note) -> Bool {
        if a.isStub != b.isStub { return !a.isStub }   // prefer an engaged note
        return a.body.count > b.body.count
    }

    // MARK: - Internals

    private func persist() {
        score = engine.score(notes: notes, folders: folders, axes: axes)
        recomputeLastTended()
        storage.save(StoredData(notes: notes, folders: folders, axes: axes,
                                schemaVersion: Self.schemaVersion, reflections: reflectionLog,
                                followUps: followUps, linkLearning: linkLearning))
    }

    // MARK: - Find-links learning (suggestions get better with your decisions)

    /// What Find-links has learned. Persisted; consulted on every scan.
    @Published private(set) var linkLearning = LinkLearning()

    private static func learnKey(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func folderOf(_ target: String) -> String {
        guard let slash = target.lastIndex(of: "/") else { return "" }
        return String(target[..<slash])
    }

    /// You added (or edited-then-added) a suggested link. Remember the alias so this
    /// surface auto-links next time, and the folder you chose for this name. Clears any
    /// earlier skip of the same thing (you changed your mind).
    func recordLinkConfirmed(name: String, surface: String, target: String) {
        let aliasKey = Self.learnKey(surface.isEmpty ? name : surface)
        if aliasKey.count >= 2 { linkLearning.aliases[aliasKey] = target }
        let nameKey = Self.learnKey(name)
        let folder = Self.folderOf(target)
        if nameKey.count >= 2, !folder.isEmpty { linkLearning.folderForName[nameKey] = folder }
        linkLearning.skips.removeAll { $0 == aliasKey || $0 == nameKey }
        persistLearning()
    }

    /// You skipped a proposed new note — don't offer it again.
    func recordLinkSkipped(name: String, surface: String) {
        for key in [Self.learnKey(name), Self.learnKey(surface)] where key.count >= 2 {
            if !linkLearning.skips.contains(key) { linkLearning.skips.append(key) }
        }
        persistLearning()
    }

    /// Forget everything Find-links has learned (a fresh start).
    func resetLinkLearning() { linkLearning = LinkLearning(); persistLearning() }

    /// Save just the learning without recomputing the whole score.
    private func persistLearning() {
        storage.save(StoredData(notes: notes, folders: folders, axes: axes,
                                schemaVersion: Self.schemaVersion, reflections: reflectionLog,
                                followUps: followUps, linkLearning: linkLearning))
    }

    // MARK: - Vitality (gentle decay of untended areas — never subtracts real growth)

    private var lastTendedByAxis: [String: Date] = [:]

    private func recomputeLastTended() {
        var map: [String: Date] = [:]
        for n in notes where !n.isStub {
            for a in axesTended(by: n) where map[a] == nil || n.date > map[a]! {
                map[a] = n.date
            }
        }
        lastTendedByAxis = map
    }

    /// The axes a note tends: its folder's growth axes plus the axes of what it links to.
    private func axesTended(by n: Note) -> Set<String> {
        var out = Set(folder(named: n.folderName)?.growthAxes ?? [])
        for t in n.linkTargets {
            if let other = note(titled: t), let a = axis(for: other)?.id { out.insert(a) }
        }
        return out
    }

    /// How alive an axis feels right now: 1 when recently tended, fading toward a
    /// floor as it goes untended (half-life ~2 weeks). This dims the avatar only —
    /// real growth is never subtracted, and tending the area restores it at once.
    func axisVitality(_ axisID: String) -> Double {
        guard let last = lastTendedByAxis[axisID] else { return 1 }
        let days = max(0, Date().timeIntervalSince(last) / 86_400)
        let floor = 0.35, halfLife = 14.0
        return max(floor, floor + (1 - floor) * pow(0.5, days / halfLife))
    }

    // MARK: - Backup / restore (your whole life-graph, as one file)

    /// Write current data to a shareable, dated file and return its URL.
    func exportBackup() -> URL? {
        persist()
        let src = storage.fileURL
        guard FileManager.default.fileExists(atPath: src.path) else { return nil }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd-HHmm"
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("Numinous-backup-\(df.string(from: Date())).json")
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.copyItem(at: src, to: dest); return dest } catch { return nil }
    }

    /// Replace all data with a backup file's contents. Returns whether it worked.
    @discardableResult
    func importBackup(from url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(StoredData.self, from: data),
              !decoded.notes.isEmpty || !decoded.folders.isEmpty
        else { return false }
        notes = decoded.notes
        folders = decoded.folders
        if !decoded.axes.isEmpty { axes = decoded.axes }
        reflectionLog = decoded.reflections ?? []
        followUps = decoded.followUps ?? []
        persist()
        return true
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
    /// Set (or clear) a note's PRIMARY location (the first place) as free text. Kept for
    /// the single-location composer; edits the first place and leaves any others intact.
    func updateLocation(_ id: UUID, location: String?) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = location?.trimmingCharacters(in: .whitespaces)
        let name = (trimmed?.isEmpty == false) ? trimmed! : nil
        var places = notes[i].allPlaces
        if let name {
            if places.isEmpty { places = [Place(name: name)] }
            else if places[0].name != name { places[0] = Place(name: name) }  // renamed → drop stale coords
        } else if !places.isEmpty {
            places.removeFirst()
        }
        commitPlaces(places, to: i)
    }

    /// Add a place to a note (with coordinates when known — e.g. from GPS). De-duplicates
    /// by name; if the name already exists, fills in coordinates we didn't have before.
    func addPlace(_ id: UUID, name: String, latitude: Double? = nil, longitude: Double? = nil) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        var places = notes[i].allPlaces
        if let j = places.firstIndex(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) {
            if latitude != nil, longitude != nil { places[j].latitude = latitude; places[j].longitude = longitude }
        } else {
            places.append(Place(name: n, latitude: latitude, longitude: longitude))
        }
        commitPlaces(places, to: i)
    }

    /// Correct a place — replace the one matched by its current name with a new name
    /// and/or coordinate, keeping its position in the list. Used by the pin editor to fix
    /// a wrong geocode.
    func updatePlace(_ id: UUID, original: String, name: String, latitude: Double?, longitude: Double?) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        let newName = name.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty else { return }
        var places = notes[i].allPlaces
        let replacement = Place(name: newName, latitude: latitude, longitude: longitude)
        if let j = places.firstIndex(where: { $0.name.caseInsensitiveCompare(original) == .orderedSame }) {
            places[j] = replacement
        } else {
            places.append(replacement)
        }
        commitPlaces(places, to: i)
    }

    /// Remove a place from a note by name.
    func removePlace(_ id: UUID, name: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        var places = notes[i].allPlaces
        places.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        commitPlaces(places, to: i)
    }

    /// Store the places list (nil when empty) and mirror the first name into the legacy
    /// `location` field so back-compat readers and serialization keep working. Persists
    /// only when something actually changed.
    private func commitPlaces(_ places: [Place], to i: Int) {
        let newPlaces = places.isEmpty ? nil : places
        let newLocation = places.first?.name
        guard notes[i].places != newPlaces || notes[i].location != newLocation else { return }
        notes[i].places = newPlaces
        notes[i].location = newLocation
        applyTravelValue(i)   // a place note's distance from home now feeds its growth
        persist()
    }

    // MARK: - Home & travel value

    /// Where you live — the origin for "how far did you travel". Persisted in UserDefaults.
    @Published private(set) var homeLocation: Place?
    private static let homeKey = "home_location"

    /// Set (or clear) home, persist it, and re-derive every place note's travel value so the
    /// whole map re-weights against the new home.
    func setHome(_ place: Place?) {
        homeLocation = place
        if let place, let data = try? JSONEncoder().encode(place) {
            UserDefaults.standard.set(data, forKey: Self.homeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.homeKey)
        }
        for i in notes.indices { applyTravelValue(i) }
        persist()
    }

    /// Folders whose notes are "places" — where a location and travel value make sense.
    static func isPlaceLikeFolder(_ folderName: String) -> Bool {
        let top = folderName.lowercased().split(separator: "/").first.map(String.init) ?? folderName.lowercased()
        return ["travel", "trips", "trip", "location", "locations", "places", "restaurants"].contains(top)
    }

    /// Re-derive a place note's intensity from how far it is from home and how long the trip
    /// lasted — farther + longer grows Meaning more. No-op unless home is set and the note is
    /// a place note with a coordinate. Mutates only; the caller persists.
    private func applyTravelValue(_ i: Int) {
        guard notes.indices.contains(i),
              Self.isPlaceLikeFolder(notes[i].folderName),
              let home = homeLocation, let hlat = home.latitude, let hlon = home.longitude,
              let place = notes[i].allPlaces.first(where: { $0.hasCoordinate }),
              let plat = place.latitude, let plon = place.longitude else { return }
        let km = Self.distanceKm(hlat, hlon, plat, plon)
        let days = Self.tripDays(from: notes[i].details)
        notes[i].intensity = Self.travelIntensity(distanceKm: km, days: days)
    }

    /// Map distance-from-home and trip length to a 1–5 intensity (the same growth dial
    /// everything else uses): base 3, +0…2 for distance (log-tiered so it saturates — a
    /// nearby trip and a far one both count, far more so), +0…1 for a multi-day trip.
    static func travelIntensity(distanceKm: Double, days: Int) -> Int {
        var score = 3.0
        switch distanceKm {
        case ..<50:    score += 0     // around town
        case ..<800:   score += 1     // regional
        default:       score += 2     // far afield
        }
        if days >= 7 { score += 1 } else if days >= 3 { score += 0.5 }
        return min(5, max(1, Int(score.rounded())))
    }

    /// Trip length in days from a note's Trip start/end details (inclusive); 1 if none.
    private static func tripDays(from details: [NoteDetail]) -> Int {
        guard let (s, e) = tripRange(from: details) else { return 1 }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: s),
                                                   to: Calendar.current.startOfDay(for: e)).day ?? 0
        return max(1, days + 1)
    }

    /// Great-circle distance between two lat/long points, in kilometres (haversine).
    static func distanceKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180, dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return r * 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
    }

    // MARK: - Auto-location for place notes

    private lazy var autoLocator = LocationService()

    /// Give a place-type note a location on its own. The note's NAME is the place, so
    /// geocode that first (`location/Eiffel Tower` → the Eiffel Tower), biased to where you
    /// are so a chain resolves to the nearby branch. Only when the name isn't a real place
    /// (e.g. a note auto-titled by date) fall back to your current location. Skips notes
    /// that already have a place. Correctable afterwards via the pin editor.
    func autoLocatePlaceNote(_ id: UUID) async {
        guard let note = note(id: id),
              Self.isPlaceLikeFolder(note.folderName),
              note.allPlaces.isEmpty else { return }
        let near = autoLocator.isAuthorized ? await autoLocator.currentCoordinate() : nil
        if let c = await LocationService.coordinate(for: note.displayName, near: near) {
            addPlace(id, name: note.displayName, latitude: c.latitude, longitude: c.longitude)
        } else if autoLocator.isAuthorized, let p = await autoLocator.currentPlaceStructured() {
            addPlace(id, name: p.name, latitude: p.latitude, longitude: p.longitude)
        }
    }

    func updateBody(_ id: UUID, body: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        let body = WikilinkParser.sanitize(body)   // repair any malformed/nested links
        let oldTargetsList = notes[i].linkTargets
        let oldTargets = Set(oldTargetsList.map { Self.norm($0) })
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

        // In-body MOVE: if exactly one link changed folder while keeping the same
        // name (e.g. entertainment/… → travel/…), treat it as a move of that note —
        // rename it everywhere so nothing is orphaned. Restricted to same-name moves
        // so editing a link to a *different* note stays a re-point, not a rename.
        let newList = notes[i].linkTargets
        let removed = oldTargetsList.filter { o in !newList.contains { Self.norm($0) == Self.norm(o) } }
        let addedList = newList.filter { n in !oldTargetsList.contains { Self.norm($0) == Self.norm(n) } }
        if removed.count == 1, addedList.count == 1,
           Self.leafName(removed[0]).caseInsensitiveCompare(Self.leafName(addedList[0])) == .orderedSame,
           Self.norm(Self.folderPart(of: removed[0])) != Self.norm(Self.folderPart(of: addedList[0])),
           let target = notes.first(where: { Self.norm($0.title) == Self.norm(removed[0]) && $0.id != id }) {
            renameNote(target.id, to: addedList[0])   // propagates + merges + persists
            return
        }

        for target in notes[i].linkTargets where !noteExists(titled: target) {
            notes.append(Note(title: target, date: notes[i].date, isStub: true))
        }
        // A diary entry dated within a trip auto-links that trip.
        addTripLinkIfNeeded(i)
        persist()
    }

    /// The leaf (display) name of a title (`travel/restaurant/Dunkin` → `Dunkin`).
    private static func leafName(_ title: String) -> String {
        guard let slash = title.lastIndex(of: "/") else { return title }
        return String(title[title.index(after: slash)...])
    }

    /// Create a fresh diary entry auto-titled with the current date & time, filed
    /// under `notes/diary` (Journal → Spirit), and return its id so the UI can open
    /// it straight into writing. Titles are made unique if two land in one minute.
    func createDiaryEntry(on day: Date = Date()) -> UUID {
        if folder(named: "notes/diary") == nil {
            folders.append(Folder(name: "notes/diary", category: "Journal", axisID: "spirit", defaultIntensity: 4))
        }
        let base = "notes/diary/" + Self.dateTimeStamp(day)
        var title = base, n = 2
        while notes.contains(where: { Self.norm($0.title) == Self.norm(title) }) { title = "\(base) (\(n))"; n += 1 }
        let note = Note(title: title, date: day, intensity: defaultIntensity(forFolderNamed: "notes/diary"))
        notes.append(note)
        addTripLinkIfNeeded(notes.count - 1)   // if today falls within a trip, link it
        persist()
        return note.id
    }

    // MARK: - Trips (a travel note with a start–end date range)

    /// A travel note with a date range. A diary entry dated within it auto-links here.
    struct Trip: Identifiable { let id: UUID; let title: String; let start: Date; let end: Date }

    private static let tripDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func tripDayString(_ d: Date) -> String { tripDayFormatter.string(from: d) }
    private static func tripDay(_ s: String) -> Date? { tripDayFormatter.date(from: s) }

    /// Is this note a trip candidate — a note filed under the top-level `travel` folder?
    static func isTravelNote(_ folderName: String) -> Bool {
        let f = folderName.lowercased()
        return f == "travel" || f.hasPrefix("travel/")
    }

    /// Every travel note that has both a start and end date set.
    func trips() -> [Trip] {
        notes.compactMap { n in
            guard Self.isTravelNote(n.folderName) else { return nil }
            guard let (s, e) = Self.tripRange(from: n.details) else { return nil }
            return Trip(id: n.id, title: n.title, start: s, end: e)
        }
    }

    /// The saved date range on a note, if any (normalized so start ≤ end).
    func tripRange(_ id: UUID) -> (start: Date, end: Date)? {
        note(id: id).flatMap { Self.tripRange(from: $0.details) }
    }

    private static func tripRange(from details: [NoteDetail]) -> (Date, Date)? {
        let start = details.first { norm($0.key) == "trip start" }.flatMap { tripDay($0.value) }
        let end = details.first { norm($0.key) == "trip end" }.flatMap { tripDay($0.value) }
        guard let s = start, let e = end else { return nil }
        return (min(s, e), max(s, e))
    }

    /// The trip whose range covers `date`, if any (by calendar day, inclusive).
    func trip(coveringDate date: Date) -> Trip? {
        let cal = Calendar.current
        let day = cal.startOfDay(for: date)
        return trips().first {
            day >= cal.startOfDay(for: $0.start) && day <= cal.startOfDay(for: $0.end)
        }
    }

    /// Set (or clear, when either is nil) a travel note's trip date range, then backfill:
    /// any existing diary entry dated within the new range gets the trip link.
    func setTripRange(_ id: UUID, start: Date?, end: Date?) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        setDetail(&notes[i], key: "Trip start", value: start.map(Self.tripDayString))
        setDetail(&notes[i], key: "Trip end", value: end.map(Self.tripDayString))
        if start != nil, end != nil {
            for j in notes.indices { addTripLinkIfNeeded(j) }
        }
        applyTravelValue(i)   // longer trips grow you more
        persist()
    }

    private func setDetail(_ n: inout Note, key: String, value: String?) {
        n.details.removeAll { Self.norm($0.key) == Self.norm(key) }
        if let value { n.details.append(NoteDetail(key: key, value: value)) }
    }

    /// If notes[i] is a diary entry dated within a trip and isn't already linked to it,
    /// append the trip link to its body. Idempotent; does not persist (caller persists).
    private func addTripLinkIfNeeded(_ i: Int) {
        guard notes.indices.contains(i),
              Folder.normalize(notes[i].folderName).contains("diary"),
              let trip = trip(coveringDate: notes[i].date),
              trip.id != notes[i].id,
              !notes[i].linkTargets.contains(where: { Self.norm($0) == Self.norm(trip.title) })
        else { return }
        let sep = notes[i].body.isEmpty ? "" : "\n"
        notes[i].body += sep + "[[\(trip.title)]]"
    }

    /// The most recent diary note dated to `day`, if one exists yet (does NOT create
    /// one). `day` defaults to today.
    func diaryID(on day: Date = Date()) -> UUID? {
        let cal = Calendar.current
        guard let i = notes.indices
            .filter({ Folder.normalize(notes[$0].folderName).contains("diary") && cal.isDate(notes[$0].date, inSameDayAs: day) })
            .max(by: { notes[$0].date < notes[$1].date }) else { return nil }
        return notes[i].id
    }

    /// Today's most recent diary note, if one exists yet (does NOT create one). Lets the
    /// composer pull today's entry forward for continued writing.
    func todaysDiaryID() -> UUID? { diaryID(on: Date()) }

    /// The diary note to keep writing in for `day` (default today): the most recent one
    /// dated that day, or a fresh one filed under notes/diary if there isn't one yet.
    func openDiary(on day: Date = Date()) -> UUID { diaryID(on: day) ?? createDiaryEntry(on: day) }

    /// The diary note to keep writing in today: the most recent one dated today, or a
    /// fresh one if there isn't one yet.
    func openTodayDiary() -> UUID { openDiary(on: Date()) }

    /// Create the activity's note (so it's tracked & grows the right axis) and drop a
    /// link to it into the diary for `day` — connecting the workout into that day.
    /// `day` defaults to today; pass the activity's own date to file it retroactively.
    @discardableResult
    func linkHealthItemToDiary(_ item: HealthItem, on day: Date = Date()) -> UUID? {
        guard let id = createNote(from: item), let note = self.note(id: id) else { return nil }
        let diaryID = openDiary(on: day)
        if let diary = self.note(id: diaryID) {
            let sep = diary.body.isEmpty ? "" : "\n"
            updateBody(diaryID, body: diary.body + sep + "[[\(note.title)]]")
        }
        return id
    }

    /// Append a line to today's most recent diary entry (creating one if there isn't
    /// one yet). Any `[[links]]` in the line become real connections, as usual.
    @discardableResult
    func appendToTodayDiary(_ line: String) -> UUID {
        let cal = Calendar.current
        if let i = notes.indices
            .filter({ Folder.normalize(notes[$0].folderName).contains("diary") && cal.isDateInToday(notes[$0].date) })
            .max(by: { notes[$0].date < notes[$1].date }) {
            let sep = notes[i].body.isEmpty ? "" : "\n"
            updateBody(notes[i].id, body: notes[i].body + sep + line)
            return notes[i].id
        }
        return createCapturedNote(body: line, folder: "notes/diary")
    }

    /// Delete a folder and every note filed under it (and its subfolders).
    func deleteFolder(_ path: String) {
        let p = path.lowercased()
        func under(_ s: String) -> Bool { let l = s.lowercased(); return l == p || l.hasPrefix(p + "/") }
        notes.removeAll { under($0.folderName) }
        folders.removeAll { under($0.name) }
        persist()
    }

    private static func dateTimeStamp(_ date: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    // MARK: - Capture (dictate/type → auto-linked note)

    /// Suggested wikilinks for free text — the names of notes you already have.
    func autolinkSuggestions(in text: String) -> [AutoLinker.Suggestion] {
        AutoLinker().suggest(in: text, candidates: notes.map { (name: $0.displayName, target: $0.title) })
    }

    /// nil when on-device AI is powering entity detection; otherwise a short reason
    /// it isn't (wrong hardware, Apple Intelligence off, still downloading, old iOS).
    var onDeviceAIHint: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return SmartLinker.unavailableReason }
        return "On-device AI needs iOS 26 — only exact name matches will link."
        #else
        return "On-device AI isn't available in this build — only exact name matches will link."
        #endif
    }

    /// Smarter suggestions for captured text: the deterministic matches to notes you
    /// already have, plus — on iOS 26+ Apple-Intelligence devices — the on-device
    /// LLM's read of every person, place, restaurant, and thing named. Each of those
    /// either resolves to an existing note (catching pronouns and fuzzy phrasing) or
    /// is offered as a brand-new note to create in the right folder. Falls back to
    /// the deterministic set anywhere the model isn't available.
    func smartLinkSuggestions(in text: String) async -> [LinkSuggestion] {
        var out: [LinkSuggestion] = []
        var seen = Set<String>()   // lowercased targets already offered
        // Never re-offer something the note already links. Without this, pressing "Find
        // links" again kept re-wrapping/duplicating text that was already a link.
        for t in WikilinkParser.extract(from: text) { seen.insert(t.lowercased()) }

        // 0. Learned aliases — surfaces you've confirmed before auto-link silently, and
        // deterministically (no model needed). This is how Find-links gets better with use.
        for (surface, target) in linkLearning.aliases {
            guard let r = AutoLinker.flexibleRange(of: surface, in: text) else { continue }
            guard seen.insert(target.lowercased()).inserted else { continue }
            let exists = notes.contains { Self.norm($0.title) == Self.norm(target) }
            out.append(LinkSuggestion(name: Self.leafName(target), target: target,
                                      surface: String(text[r]), isNew: !exists))
        }

        // 1. Deterministic exact matches to existing notes.
        for s in autolinkSuggestions(in: text) where seen.insert(s.target.lowercased()).inserted {
            out.append(LinkSuggestion(name: s.name, target: s.target, surface: s.name, isNew: false))
        }

        // 2. On-device LLM: resolve fuzzy references and surface new entities.
        var llmSurfacedNew = false
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SmartLinker.isAvailable {
            let candidates = notes.map { (name: $0.displayName, target: $0.title) }
            let folderNames = folders.map(\.name)
            for e in await SmartLinker.extract(from: text, folders: folderNames) {
                if let match = Self.bestNoteMatch(e.name, in: candidates) {
                    if seen.insert(match.target.lowercased()).inserted {
                        out.append(LinkSuggestion(name: match.name, target: match.target, surface: e.surface, isNew: false))
                    }
                } else {
                    let name = e.name.trimmingCharacters(in: .whitespaces)
                    guard name.count >= 2, !Self.isGenericEntity(name) else { continue }
                    let nameKey = Self.learnKey(name)
                    // Respect an earlier "Skip" — don't re-propose what you rejected.
                    if linkLearning.skips.contains(nameKey) { continue }
                    // Prefer the folder you've filed this name under before.
                    let folder = linkLearning.folderForName[nameKey]
                        ?? SmartLinker.cleanFolder(e.folder, existing: folderNames)
                    let target = folder + "/" + name
                    if seen.insert(target.lowercased()).inserted {
                        out.append(LinkSuggestion(name: name, target: target, surface: e.surface, isNew: true))
                        llmSurfacedNew = true
                    }
                }
            }
        }
        #endif

        // 3. Fallback: when the on-device model didn't surface any new entities (it's
        // unavailable, or found nothing), infer proposals from sentence patterns —
        // "with <person>", "at <place>", "in <city>". Works on lowercase dictation too.
        if !llmSurfacedNew {
            for s in heuristicNewEntities(in: text) where seen.insert(s.target.lowercased()).inserted {
                out.append(s)
            }
        }
        return out
    }

    /// Words that end a name phrase (prepositions, conjunctions, pronouns, articles,
    /// auxiliaries) — used to know where a "with <name>" phrase stops.
    private static let nameBoundary: Set<String> = [
        "at","in","on","to","for","and","but","then","with","near","by","from","of","about",
        "we","i","the","a","an","was","were","is","are","am","be","been","had","have","has",
        "that","this","these","those","today","yesterday","tomorrow","last","next","who","which",
        "my","our","your","their","his","her","its","it","he","she","they","them","us","me",
        "when","while","after","before","during","because","so","or","nor","yet"
    ]

    /// Sentence-pattern triggers → the folder a following name likely belongs in.
    private static let nameTriggers: [String: String] = [
        "with": "people", "met": "people", "meet": "people", "meeting": "people",
        "saw": "people", "see": "people", "seeing": "people", "call": "people",
        "called": "people", "calling": "people", "texted": "people", "texting": "people",
        "emailed": "people", "from": "people",
        "at": "notes", "visited": "location", "visiting": "location", "in": "location",
    ]

    /// A lightweight, model-free entity guesser for when Apple's on-device model isn't
    /// available (or finds nothing). It reads simple patterns — "with <person>", "at
    /// <place>", "in <city>" — and proposes a new note for each, folder guessed from
    /// the trigger word. Deliberately shallow: the user reviews (Add/Edit/Skip) every
    /// one, and their choices are remembered by the learning layer.
    func heuristicNewEntities(in text: String) -> [LinkSuggestion] {
        let ns = text as NSString
        var tokens: [(word: String, range: NSRange)] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { sub, r, _, _ in
            if let sub { tokens.append((sub, r)) }
        }
        var out: [LinkSuggestion] = []
        var seenLocal = Set<String>()
        var i = 0
        while i < tokens.count {
            let w = tokens[i].word.lowercased()
            guard let folder0 = Self.nameTriggers[w] else { i += 1; continue }
            var nameTokens: [(String, NSRange)] = []
            var j = i + 1
            while j < tokens.count, nameTokens.count < 3 {
                let t = tokens[j].word, tl = t.lowercased()
                if t.count < 2 || Self.nameBoundary.contains(tl) || Self.nameTriggers[tl] != nil { break }
                nameTokens.append((t, tokens[j].range)); j += 1
            }
            defer { i = max(i + 1, j) }
            guard !nameTokens.isEmpty else { continue }
            let startLoc = nameTokens.first!.1.location
            let endLoc = nameTokens.last!.1.location + nameTokens.last!.1.length
            let surface = ns.substring(with: NSRange(location: startLoc, length: endLoc - startLoc))
            let name = nameTokens.map { $0.0.prefix(1).uppercased() + $0.0.dropFirst() }.joined(separator: " ")
            let key = name.lowercased()
            guard key.count >= 3, !Self.isGenericEntity(name),
                  !linkLearning.skips.contains(key), seenLocal.insert(key).inserted else { continue }
            // Don't propose something you already have a note for.
            if notes.contains(where: { $0.displayName.lowercased() == key }) { continue }
            let folder = linkLearning.folderForName[key] ?? folder0
            out.append(LinkSuggestion(name: name, target: folder + "/" + name, surface: surface, isNew: true))
        }
        return out
    }

    /// Common activity / filler words that shouldn't become their own linked notes
    /// (so "golf", "dinner", "gym" don't spawn `[[notes/golf]]`). Only single generic
    /// words are blocked — a named place like "Golf Club of Austin" still proposes.
    private static let genericEntityWords: Set<String> = [
        "golf", "tennis", "dinner", "lunch", "breakfast", "brunch", "coffee", "drinks",
        "gym", "run", "running", "walk", "walking", "hike", "hiking", "swim", "swimming",
        "yoga", "meeting", "call", "game", "party", "class", "practice", "workout", "ride",
        "bike", "biking", "work", "office", "home", "today", "tomorrow", "yesterday",
        "stuff", "thing", "things", "everyone", "everything", "someone",
    ]

    static func isGenericEntity(_ name: String) -> Bool {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        return !n.contains(" ") && genericEntityWords.contains(n)
    }

    /// Loose match of an LLM-extracted name to an existing note (either contains the
    /// other, case-insensitively). Deliberately conservative — 3+ chars — so a bare
    /// "the" or initial never links.
    private static func bestNoteMatch(_ name: String, in candidates: [(name: String, target: String)]) -> (name: String, target: String)? {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard n.count >= 3 else { return nil }
        return candidates.first { c in
            let cn = c.name.lowercased()
            // Confident matches only: an exact name, or the text names the FULL contact
            // (multi-word). A bare first name / city token must NOT grab a longer contact
            // (so "Austin" the city won't link to "Austin Shaver"). Fuzzy first-name
            // resolution is left to the learning layer, which remembers what you confirm.
            if cn == n { return true }
            if cn.contains(" "), n.contains(cn) { return true }
            return false
        }
    }

    /// Create a note from captured (spoken or typed) text, titled by date and filed
    /// under the chosen category folder (creating it if new). Links inside the body
    /// grow you as usual.
    @discardableResult
    func createCapturedNote(body: String, folder: String = "notes",
                            intensity: Int? = nil, location: String? = nil) -> UUID {
        let category = folder.trimmingCharacters(in: CharacterSet(charactersIn: " /")).isEmpty ? "notes" : folder
        ensureCategoryFolder(category)
        let base = category + "/" + Self.dateTimeStamp()
        var title = base, n = 2
        while notes.contains(where: { Self.norm($0.title) == Self.norm(title) }) { title = "\(base) (\(n))"; n += 1 }
        let loc = location?.trimmingCharacters(in: .whitespaces)
        let note = Note(title: title, date: Date(), body: WikilinkParser.sanitize(body),
                        intensity: intensity ?? defaultIntensity(forFolderNamed: category),
                        location: (loc?.isEmpty == false) ? loc : nil)
        save(note)   // also creates stubs for any [[links]]
        // A new diary entry within a trip auto-links it (no-op for other folders).
        if let i = notes.firstIndex(where: { $0.id == note.id }) {
            addTripLinkIfNeeded(i)
            if notes[i].body != note.body { persist() }
        }
        // A place-type note with no location yet gets one on its own (GPS or geocode).
        if loc == nil || loc?.isEmpty == true {
            Task { await autoLocatePlaceNote(note.id) }
        }
        return note.id
    }

    /// Ensure a category folder exists so captured notes there grow an axis; a brand
    /// new one gets a suggested axis (diary → Journal/Spirit, matching the app's
    /// existing diary default).
    private func ensureCategoryFolder(_ name: String) {
        let n = name.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        guard !n.isEmpty, folder(named: n) == nil else { return }
        if Folder.normalize(n).contains("diary") {
            folders.append(Folder(name: n, category: "Journal", axisID: "spirit", defaultIntensity: 4))
            return
        }
        // A recognizable folder gets a sensible axis so its connections COUNT toward
        // growth; otherwise fall back to the similarity classifier.
        let axis = Self.defaultAxis(forFolderNamed: n)
            ?? { if case let .suggest(id, _) = suggestAxis(forNewFolderNamed: n) { return id }; return nil }()
        folders.append(Folder(name: n, category: n.capitalized, axisID: axis))
    }

    /// A sensible default growth axis for common folder names, so their links count
    /// (a link only counts when both ends' folders have an axis). Overridable by the
    /// user via "Grows…". Returns nil for folders we can't confidently place.
    static func defaultAxis(forFolderNamed name: String) -> String? {
        let base = name.lowercased().split(separator: "/").first.map(String.init) ?? name.lowercased()
        switch base {
        case "people", "person", "friends", "family", "relationships", "contacts", "colleagues":
            return "heart"
        case "work", "career", "job", "projects", "school", "study", "notes", "ideas":
            return "mind"
        case "books", "reading", "learning", "articles", "podcasts":
            return "mind"
        case "authors", "author", "influences":
            return "influences"
        case "health", "fitness", "exercise", "workouts", "sports", "golf clubs", "body":
            return "body"
        case "food", "nutrition", "diet", "meals", "cooking", "restaurants":
            return "gut"
        case "spirit", "faith", "meditation", "gratitude", "journal", "diary", "prayer":
            return "spirit"
        case "location", "locations", "places", "travel", "home", "entertainment", "movies", "music", "hobbies", "experiences":
            return "meaning"
        default:
            return nil
        }
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
