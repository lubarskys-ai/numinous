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
    /// A request to open the avatar/connectome spotlighting node(s) — a note or a whole folder
    /// (set from a note/folder, consumed by the avatar view, cleared when it closes).
    @Published var avatarFocus: AvatarFocus?

    /// Graph-node ids for notes filed under a folder (and its subfolders) that actually appear
    /// in the connectome — for spotlighting a whole folder, including notes linked to nothing.
    func nodeIDs(inFolder folderPath: String) -> [UUID] {
        let p = Folder.normalize(folderPath)
        return notes.compactMap { n in
            let f = Folder.normalize(n.folderName)
            guard (f == p || f.hasPrefix(p + "/")), axis(for: n) != nil else { return nil }
            return n.id
        }
    }

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
    static let maturityFullPerAxis = 480.0

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
        self.manualFolders = Set(loaded?.manualFolders ?? [])
        self.readwiseToken = UserDefaults.standard.string(forKey: Self.readwiseTokenKey)
        self.homeLocation = UserDefaults.standard.data(forKey: Self.homeKey)
            .flatMap { try? JSONDecoder().decode(Place.self, from: $0) }
        self.score = ScoreEngine().score(notes: n, folders: f, axes: a)
        recomputeLookupIndexes()
        recomputeLastTended()
        recomputeCabinetGroups()
        recomputeBacklinkIndex()          // before places — pin labels resolve via backlinks
        recomputeMappablePlaces()
        if loaded == nil || didMigrate || version < Self.schemaVersion {
            storage.save(StoredData(notes: n, folders: f, axes: a, schemaVersion: Self.schemaVersion,
                                    reflections: reflectionLog, followUps: followUps,
                                    linkLearning: linkLearning, manualFolders: Array(manualFolders)))
        }
        // Reward any follow-ups you've since completed in iOS Reminders.
        Task { await checkFollowUps() }
        // Silently refresh already-connected sources (contacts, Readwise).
        Task { await autoSync() }
        // Show the auto-backup folder name in Settings, and write a fresh backup on launch.
        if let bm = UserDefaults.standard.data(forKey: Self.autoBackupKey) {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: bm, bookmarkDataIsStale: &stale) {
                autoBackupFolderName = u.lastPathComponent
            }
            runAutoBackup(force: true)
        }
    }

    /// Refresh already-connected import sources on launch/foreground. Idempotent
    /// (matched by id, so no duplicates) and never prompts: contacts sync only when
    /// access is already granted; Readwise only when a token is stored.
    private var lastAutoSync = Date.distantPast

    func autoSync() async {
        // Re-importing every contact and all of Readwise on EVERY foreground caused a hitch
        // each time you returned to the app. These sources barely change — sync at most every
        // 10 minutes. (Manual "Sync contacts" / "Sync Readwise now" bypass this.)
        if Date().timeIntervalSince(lastAutoSync) < 600 { return }
        lastAutoSync = Date()
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

    // O(1) lookup indexes (id/title → array index, folder id → array index), rebuilt whenever
    // the data changes. Linear `notes.first {…}` / `folders.first {…}` scans per lookup are a
    // real cost at scale — these are called per row while scrolling and all through persist().
    // The cached index is validated on use, so a lookup made mid-mutation (before the next
    // recompute) safely falls back to a scan instead of returning a stale/out-of-range hit.
    private var noteIndexByID: [UUID: Int] = [:]
    private var noteIndexByTitle: [String: Int] = [:]
    private var folderIndexByID: [String: Int] = [:]

    private func recomputeLookupIndexes() {
        noteIndexByID.removeAll(keepingCapacity: true)
        noteIndexByTitle.removeAll(keepingCapacity: true)
        folderIndexByID.removeAll(keepingCapacity: true)
        for (i, n) in notes.enumerated() {
            noteIndexByID[n.id] = i
            noteIndexByTitle[Self.norm(n.title)] = i
        }
        for (i, f) in folders.enumerated() { folderIndexByID[f.id] = i }
    }

    func note(id: UUID) -> Note? {
        if let i = noteIndexByID[id], notes.indices.contains(i), notes[i].id == id { return notes[i] }
        return notes.first { $0.id == id }
    }

    func note(titled title: String) -> Note? {
        let key = Self.norm(title)
        if let i = noteIndexByTitle[key], notes.indices.contains(i), Self.norm(notes[i].title) == key { return notes[i] }
        return notes.first { Self.norm($0.title) == key }
    }

    func folder(named name: String) -> Folder? {
        let key = Folder.normalize(name)
        if let i = folderIndexByID[key], folders.indices.contains(i), folders[i].id == key { return folders[i] }
        return folders.first { $0.id == key }
    }

    /// Re-case `path` so each segment matches an existing folder of the same name
    /// (case-insensitively) — drawn from folder records AND existing note paths — so we
    /// never spawn "Medical" beside "medical". Segments with no existing match keep the
    /// casing given. This is the guard that stops case-variant folders being created.
    func canonicalFolderCasing(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return trimmed }
        var known: [String: String] = [:]   // norm(prefix) -> the casing already in use
        func register(_ p: String) {
            var acc = ""
            for seg in p.split(separator: "/").map(String.init) {
                acc = acc.isEmpty ? seg : acc + "/" + seg
                let key = Self.norm(acc)
                if known[key] == nil { known[key] = acc }
            }
        }
        for f in folders { register(f.name) }
        for note in notes {
            let comps = note.title.split(separator: "/").map(String.init)
            if comps.count > 1 { register(comps.dropLast().joined(separator: "/")) }
        }
        var acc = "", result = ""
        for seg in trimmed.split(separator: "/").map(String.init) {
            acc = acc.isEmpty ? seg : acc + "/" + seg
            if let canon = known[Self.norm(acc)] {
                result = canon                                   // adopt the established casing
            } else {
                result = result.isEmpty ? seg : result + "/" + seg
            }
        }
        return result
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

    /// One top-level cabinet: a category name and the notes under it (and its subfolders).
    struct CabinetGroup: Identifiable, Equatable {
        let id: String              // top-level folder name, e.g. "books"
        let notes: [Note]
    }

    /// Cached grouping of notes into top-level cabinets, recomputed only when notes change
    /// (in `persist`/`init`) — NOT on every view render. The Folders tab re-renders on many
    /// signals (selection, opening a drawer, any @Published change); regrouping every note
    /// each time was the post-import slowdown. Reading this cache is O(1).
    @Published private(set) var cabinetGroups: [CabinetGroup] = []

    private func recomputeCabinetGroups() {
        var groups: [String: [Note]] = [:]
        for note in notes {
            let top = note.folderName.split(separator: "/").first.map(String.init) ?? ""
            guard !top.isEmpty else { continue }
            groups[top, default: []].append(note)
        }
        // Show user-created top-level folders even when they hold no notes yet, so a folder
        // you made to organize into actually appears (and can be a drop target).
        for f in folders {
            let top = f.name.split(separator: "/").first.map(String.init) ?? ""
            guard !top.isEmpty, groups[top] == nil,
                  manualFolders.contains(Folder.normalize(top)) else { continue }
            groups[top] = []
        }
        cabinetGroups = groups.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { key in CabinetGroup(id: key, notes: (groups[key] ?? []).sorted { $0.date > $1.date }) }
    }

    /// A note's place with real coordinates, ready to plot — precomputed so the Map tab
    /// never rescans every note (which was O(notes) × several times per render).
    struct MappablePlace: Identifiable, Equatable {
        let id: String            // noteID|placename, stable across renders
        let noteID: UUID
        let title: String         // the note's name (for reference)
        let placeName: String     // the location's name
        let label: String         // what the map pin is actually labeled with (person/venue, not raw geography)
        let folderName: String
        let date: Date
        let axisID: String?
        let latitude: Double
        let longitude: Double
    }

    /// Cached list of every coordinate-bearing, plausibly-real place. Recomputed only when
    /// notes change (persist/init), not on every Map render. Almost all notes have no place,
    /// so this list stays small and the Map filters it cheaply.
    @Published private(set) var mappablePlaces: [MappablePlace] = []

    private func recomputeMappablePlaces() {
        var out: [MappablePlace] = []
        for n in notes {
            for p in n.allPlaces where p.hasCoordinate && LocationService.looksLikePlace(p.name) {
                out.append(MappablePlace(id: "\(n.id.uuidString)|\(p.name.lowercased())",
                                         noteID: n.id, title: n.displayName, placeName: p.name,
                                         label: mapLabel(for: n, place: p),
                                         folderName: n.folderName,
                                         date: n.date, axisID: folder(named: n.folderName)?.axisID,
                                         latitude: p.latitude!, longitude: p.longitude!))
            }
        }
        mappablePlaces = out
    }

    /// What a map pin should read — the meaningful thing at that spot, not raw geography.
    /// - A diary entry (named by a date) shows WHERE it happened.
    /// - A bare "location hub" note (a place-folder note whose title is just the place, e.g.
    ///   `location/Switzerland`) is the coordinate carrier for whatever links to it. If exactly
    ///   one real note (a person/event, not another place) references it, show THAT — so the pin
    ///   reads "Neal Kutner", not "Switzerland". If several reference it, keep the shared place
    ///   name. If nothing does, it's a place you logged for its own sake — show the place.
    /// - A named venue note (title differs from the place) shows the clean venue name.
    /// - Everyone/everything else shows its own name, never a geocoded city or region.
    private func mapLabel(for n: Note, place p: Place) -> String {
        if Self.isDateTitled(n.displayName) { return p.name.isEmpty ? n.displayName : p.name }
        guard Self.isPlaceLikeFolder(n.folderName) else { return n.displayName }
        let isBareHub = Self.norm(n.displayName) == Self.norm(p.name)
        if isBareHub {
            // Only a real entity — a person/idea (not a place, not a stub, not a dated diary
            // entry) — overrides the geographic name. A diary entry that merely happened at a
            // venue must NOT rename the venue to its date; that's why Blue Bottle stays "Blue
            // Bottle" while Switzerland (linked only from Neal's note) reads "Neal Kutner".
            let referrers = backlinks(to: n).filter {
                !$0.isStub && !Self.isPlaceLikeFolder($0.folderName) && !Self.isDateTitled($0.displayName)
            }
            if referrers.count == 1 { return referrers[0].displayName }
        }
        return (!p.name.isEmpty && !p.name.contains(",")) ? p.name : n.displayName
    }

    // Cached avatar connectome graph (every note as a node + its engaged/concierge links).
    // Building it scans all notes with string work — it was running on EVERY avatar render
    // and zoom (25–56ms at ~4k notes), hitching the page. Now built lazily once after each
    // data change and reused.
    private var cachedAvatarNodes: [GraphNode] = []
    private var cachedAvatarLinks: [GraphEdge] = []
    private var avatarGraphDirty = true

    func avatarGraph() -> (nodes: [GraphNode], links: [GraphEdge]) {
        if avatarGraphDirty { recomputeAvatarGraph(); avatarGraphDirty = false }
        return (cachedAvatarNodes, cachedAvatarLinks)
    }

    private func recomputeAvatarGraph() {
        let graphNodes: [GraphNode] = notes.compactMap { note in
            guard let axis = axis(for: note) else { return nil }
            return GraphNode(id: note.id, axis: axis.id, label: note.displayName)
        }
        let axisOf = Dictionary(graphNodes.map { ($0.id, $0.axis) }, uniquingKeysWith: { a, _ in a })
        let idByTitle = Dictionary(notes.map { (Self.norm($0.title), $0.id) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>(); var edges: [GraphEdge] = []
        func add(_ a: UUID, _ b: UUID) {
            guard a != b, axisOf[a] != nil, axisOf[b] != nil else { return }
            let key = [a.uuidString, b.uuidString].sorted().joined(separator: "~")
            guard seen.insert(key).inserted else { return }
            edges.append(GraphEdge(a: a, b: b, cross: axisOf[a] != axisOf[b]))
        }
        for l in score.links where l.isCounted { add(l.a, l.b) }
        for note in notes where axisOf[note.id] != nil {
            for target in note.linkTargets where target.lowercased().hasPrefix("concierge/") {
                if let other = idByTitle[Self.norm(target)] { add(note.id, other) }
            }
        }
        cachedAvatarNodes = graphNodes
        cachedAvatarLinks = edges
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

    /// Reverse link index: normalized note title → ids of notes whose body links to it.
    /// Built once per data change (in persist/init) so `backlinks` is an O(1) lookup
    /// instead of re-parsing every note's `[[links]]` with regex on every render — which,
    /// with a large imported vault, made viewing/typing in a note sticky.
    private var backlinkIndex: [String: [UUID]] = [:]

    private func recomputeBacklinkIndex() {
        var index: [String: [UUID]] = [:]
        for n in notes {
            for target in n.linkTargets {   // the one place we pay the regex cost, once per note
                index[Self.norm(target), default: []].append(n.id)
            }
        }
        backlinkIndex = index
    }

    /// Notes that link *to* the given note (Obsidian-style backlinks) — from the cached index.
    func backlinks(to note: Note) -> [Note] {
        let ids = Set(backlinkIndex[Self.norm(note.title)] ?? [])
        guard !ids.isEmpty else { return [] }
        return notes.filter { $0.id != note.id && ids.contains($0.id) }
    }

    // MARK: - Mutations

    /// Insert or update a note; auto-create untyped stubs for any missing links.
    func save(_ note: Note) {
        if let i = notes.firstIndex(where: { $0.id == note.id }) { notes[i] = note }
        else { notes.append(note) }
        var placeLinksToLocate: [UUID] = []
        for target in note.linkTargets {
            if !noteExists(titled: target) {
                // Give the linked folder an axis so this connection counts toward growth.
                ensureCategoryFolder(Self.folderPart(of: target))
                let stub = Note(title: target, date: note.date, isStub: true)
                notes.append(stub)
                if Self.isPlaceLikeFolder(Self.folderPart(of: target)) { placeLinksToLocate.append(stub.id) }
            } else if Self.isPlaceLikeFolder(Self.folderPart(of: target)),
                      let existing = self.note(titled: target),
                      !existing.allPlaces.contains(where: { $0.hasCoordinate }) {
                // A place you LINKED that still has no GPS → geocode it from its name too.
                placeLinksToLocate.append(existing.id)
            }
        }
        persist()
        // Auto-geocode place-type links (e.g. [[location/Eiffel Tower]]) from their name, so
        // they land on the map without you setting a location by hand. Never fall back to your
        // current location for a linked place — it could be anywhere.
        for id in placeLinksToLocate { Task { await autoLocatePlaceNote(id, allowGPSFallback: false) } }
        // …and the note itself, when it's a place note (travel/, location/, restaurants/…)
        // that doesn't have coordinates yet — so any note about a place lands on the map.
        if Self.isPlaceLikeFolder(note.folderName), note.allPlaces.isEmpty {
            let nid = note.id
            Task { await autoLocatePlaceNote(nid) }
        }
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
    /// Rewrite an imported body's `[[links]]` to point at a note you may have MOVED: if a
    /// target no longer exists but a note with the same leaf name does, redirect to it — so a
    /// re-import (autoSync on launch) can't resurrect the target's OLD folder after you moved
    /// it. This is what stopped moved authors/links reverting when the app relaunched.
    private func redirectImportedLinks(_ body: String) -> String {
        guard body.contains("[[") else { return body }
        return WikilinkParser.rewrite(in: body) { target in
            if noteExists(titled: target) { return target }
            let leaf = Self.norm(Self.leafName(target))
            if let moved = notes.first(where: { Self.norm(Self.leafName($0.title)) == leaf }) {
                return moved.title
            }
            return target
        }
    }

    func ingest(_ items: [ImportedItem]) -> (added: Int, updated: Int) {
        var added = 0, updated = 0
        for item in items {
            if folder(named: item.folder) == nil {
                folders.append(Folder(name: item.folder, category: item.folderCategory, axisID: item.folderAxisID))
            }
            let title = item.folder + "/" + item.name
            let body = redirectImportedLinks(item.body)
            if let i = notes.firstIndex(where: { $0.origin == item.origin }) {
                // Don't revert a folder you moved this note into: only refresh its title while
                // it's still in the source folder.
                if Self.norm(Self.folderPart(of: notes[i].title)) == Self.norm(item.folder) {
                    notes[i].title = title
                }
                notes[i].details = Self.mergeDetails(notes[i].details, item.details)
                if let loc = item.location, notes[i].location?.isEmpty != false { notes[i].location = loc }
                if notes[i].body.isEmpty {
                    notes[i].body = body
                    // Still un-engaged (no body of its own) → keep it dormant.
                    if item.isDormant { notes[i].isStub = true }
                } else if item.mergeBody {
                    // Bring in new highlights without discarding your edits/links.
                    notes[i].body = Self.mergeBodies(existing: notes[i].body, incoming: body)
                }
                updated += 1
            } else if let i = notes.firstIndex(where: {
                Self.norm($0.title) == Self.norm(title) && $0.origin?.source != item.origin.source
            }) {
                // Adopt an existing same-title note from a DIFFERENT source (a hand-made note,
                // or the same book imported earlier from the Obsidian vault) instead of
                // creating a duplicate — this is what stopped merged books re-doubling on the
                // next Readwise sync.
                notes[i].origin = item.origin
                notes[i].details = Self.mergeDetails(notes[i].details, item.details)
                if item.mergeBody { notes[i].body = Self.mergeBodies(existing: notes[i].body, incoming: body) }
                updated += 1
            } else {
                // Disambiguate if a *different* origin already holds this title.
                var uniqueTitle = title, n = 2
                while notes.contains(where: { Self.norm($0.title) == Self.norm(uniqueTitle) }) {
                    uniqueTitle = "\(title) (\(n))"; n += 1
                }
                notes.append(Note(title: uniqueTitle, date: item.date, body: body,
                                  intensity: item.intensity, location: item.location, details: item.details,
                                  origin: item.origin, isStub: item.isDormant))
                added += 1
            }
        }
        // Auto-create stub notes for any [[links]] inside the imported bodies (e.g.
        // links you wrote in Readwise highlights), so their folders/files appear —
        // exactly as saving a note by hand does. Redirect first so a moved target isn't
        // re-created in its old folder.
        for item in items {
            for target in WikilinkParser.extract(from: redirectImportedLinks(item.body)) where !noteExists(titled: target) {
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
            // Group by concierge dollar tier: e.g. a contact with $5000 gets [[concierge/$5000]].
            for tier in contact.conciergeTiers { lines.append("[[concierge/\(tier)]]") }
            return ImportedItem(folder: "contacts", name: name, body: lines.joined(separator: "\n"),
                                origin: NoteOrigin(source: "contacts", externalID: contact.id),
                                folderCategory: "Contacts", folderAxisID: "heart",
                                location: contact.place,
                                isDormant: true)
        }
        let result = ingest(items)
        ensureConciergeLinks(contacts)
        return result
    }

    /// One-time import of an Obsidian vault — a folder of markdown files. Each file
    /// becomes a note whose folder mirrors its vault subfolder, and its `[[wikilinks]]`
    /// resolve as usual. Idempotent by the file's path within the vault (re-running
    /// updates rather than duplicates), and — per the safe default — it never
    /// overwrites a Numinous note that already has a body you wrote: an empty note is
    /// filled, but your own edits are left untouched.
    ///
    /// Imported folders arrive with no growth axis, so the notes float in the graph
    /// until you map their folder to an axis in the Folders tab — keeping growth
    /// tied to engagement, not to bulk-importing a vault.
    @discardableResult
    func importObsidianVault(at folderURL: URL) async -> (added: Int, updated: Int, files: Int) {
        // Reading a whole vault — potentially thousands of files, some not yet
        // downloaded from iCloud — must NOT run on the main actor, or the UI freezes
        // until it finishes. Parse off-main, then ingest (a model mutation) back here.
        let scoped = folderURL.startAccessingSecurityScopedResource()
        let parsed = await Task.detached(priority: .userInitiated) {
            ObsidianMarkdownImporter.parse(vaultAt: folderURL)
        }.value
        if scoped { folderURL.stopAccessingSecurityScopedResource() }

        let items: [ImportedItem] = parsed.compactMap { note in
            let name = note.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            let folder = note.folder.isEmpty ? "notes" : note.folder
            return ImportedItem(
                folder: folder,
                name: name,
                body: note.body,
                details: note.details,
                date: note.date ?? Date(),
                origin: NoteOrigin(source: "obsidian", externalID: note.relativePath),
                folderCategory: "Obsidian",
                folderAxisID: guessAxis(forFolderPath: folder),
                // Start dormant: a big import brings your whole vault in as linkable,
                // searchable notes but grants zero growth until you actually engage.
                // Opening a note and editing its body un-dormants it (see updateBody),
                // so the avatar grows from what you return to, not from bulk volume.
                isDormant: true
            )
        }
        let result = ingest(items)
        return (result.added, result.updated, parsed.count)
    }

    /// Best-guess growth axis for a freshly-imported folder, from its name (e.g.
    /// `People/` → Heart, `Books/` → Mind). Only *new* folders take this guess —
    /// ingest never re-maps a folder you've already set — and a folder that matches
    /// nothing stays axis-less until you map it by hand. First match wins, so the
    /// order below is the priority when a name could fit two axes.
    private func guessAxis(forFolderPath path: String) -> String? {
        let table: [(axis: String, words: [String])] = [
            ("influences", ["author", "mentor", "inspiration", "quote", "influence", "hero", "teacher"]),
            ("heart",      ["people", "contact", "friend", "family", "relationship", "love", "partner"]),
            ("body",       ["workout", "fitness", "health", "exercise", "run", "gym", "training", "body", "sport"]),
            ("gut",        ["food", "meal", "diet", "nutrition", "recipe", "cook", "eat", "restaurant"]),
            ("spirit",     ["spirit", "faith", "medit", "prayer", "gratitude", "mindful", "religion", "soul"]),
            ("mind",       ["book", "read", "idea", "learn", "study", "knowledge", "thought", "note", "research", "concept"]),
            ("meaning",    ["travel", "trip", "place", "work", "career", "project", "goal", "purpose", "journal", "diary", "mission"]),
        ]
        let components = path.lowercased().split(separator: "/").map(String.init)
        guard !components.isEmpty else { return nil }
        for (axis, words) in table where axes.contains(where: { $0.id == axis }) {
            if components.contains(where: { comp in words.contains(where: comp.contains) }) {
                return axis
            }
        }
        return nil
    }

    /// Guarantee each contact with a detected dollar tier actually carries its
    /// `[[concierge/$X]]` link — even on a re-sync, where ingest preserves an already-imported
    /// contact's body (so the link would otherwise never land, leaving the tier notes with no
    /// backlinks). Idempotent: only appends a link that isn't already there.
    private func ensureConciergeLinks(_ contacts: [ImportedContact]) {
        var changed = false
        // Give concierge its OWN axis + folder so its links actually appear in the avatar as
        // a distinct cluster — an axis-less note is drawn nowhere in the connectome, so this
        // is what makes the tiers show up (its own axis keeps it out of your LIFE axes).
        if contacts.contains(where: { !$0.conciergeTiers.isEmpty }) {
            if !axes.contains(where: { $0.id == "concierge" }) {
                axes.append(Axis(id: "concierge", name: "Concierge", colorHex: "#C9A227"))
                changed = true
            }
            if let fi = folders.firstIndex(where: { $0.id == Folder.normalize("concierge") }) {
                if folders[fi].axisID != "concierge" {
                    folders[fi].axisID = "concierge"; folders[fi].axisIDs = ["concierge"]; changed = true
                }
            } else {
                folders.append(Folder(name: "concierge", category: "Concierge", axisID: "concierge"))
                changed = true
            }
        }
        for contact in contacts where !contact.conciergeTiers.isEmpty {
            guard let i = notes.firstIndex(where: {
                $0.origin?.source == "contacts" && $0.origin?.externalID == contact.id
            }) else { continue }
            for tier in contact.conciergeTiers {
                let title = "concierge/\(tier)"
                if !notes[i].body.contains("[[\(title)]]") {
                    notes[i].body += (notes[i].body.isEmpty ? "" : "\n") + "[[\(title)]]"
                    changed = true
                }
                if !noteExists(titled: title) {
                    notes.append(Note(title: title, date: notes[i].date, isStub: true))
                    changed = true
                }
            }
        }
        if changed { persist() }
    }

    // MARK: - Reconnect (location-based reconnection)

    /// A nudge to reach out to someone because you're near them (now or on a trip).
    struct ReconnectPrompt: Identifiable, Equatable {
        let id: UUID       // the person's note id
        let name: String
        let place: String  // the place that matched
        let reason: String // "You're here now" / "Trip · Sep 3"
        var lastContact: Date = .distantPast   // when you last engaged them — drives staleness
    }

    /// A person, the lowercased text to match places against (their note's location + body),
    /// and when you last engaged them (their note or the newest note that links them).
    struct PersonPlaces: Identifiable { let id: UUID; let name: String; let text: String; let lastContact: Date }

    /// A person with a real coordinate, for GPS-distance reconnection.
    struct PersonLocation: Identifiable { let id: UUID; let name: String; let latitude: Double; let longitude: Double; let lastContact: Date }

    /// People who have a real coordinate — from a place on their OWN note, or a place they
    /// link to (e.g. `[[places/Austin]]`). This is what makes distance-based "near me" work.
    func peopleWithCoordinates() -> [PersonLocation] {
        // Resolve place-note titles → coordinate, so a person's [[places/X]] link supplies one.
        var placeCoord: [String: (Double, Double)] = [:]
        for n in notes {
            if let p = n.allPlaces.first(where: { $0.hasCoordinate }) {
                placeCoord[Self.norm(n.title)] = (p.latitude!, p.longitude!)
            }
        }
        var out: [PersonLocation] = []
        for n in notes {
            let f = Folder.normalize(n.folderName)
            guard f == "people" || f == "contacts" else { continue }
            var coord = n.allPlaces.first(where: { $0.hasCoordinate }).map { ($0.latitude!, $0.longitude!) }
            if coord == nil { for t in n.linkTargets { if let c = placeCoord[Self.norm(t)] { coord = c; break } } }
            guard let c = coord else { continue }
            let lastContact = max(n.date, backlinks(to: n).map(\.date).max() ?? .distantPast)
            out.append(PersonLocation(id: n.id, name: n.displayName, latitude: c.0, longitude: c.1, lastContact: lastContact))
        }
        return out
    }

    /// People within `km` of a coordinate, labeled with the actual distance, most-overdue first.
    func peopleNear(latitude: Double, longitude: Double, withinKm km: Double = 40) -> [ReconnectPrompt] {
        peopleWithCoordinates().compactMap { person -> ReconnectPrompt? in
            let d = Self.distanceKm(latitude, longitude, person.latitude, person.longitude)
            guard d <= km else { return nil }
            let miles = d * 0.621371
            let label = miles < 1 ? "Right here" : "\(Int(miles.rounded())) mi away"
            return ReconnectPrompt(id: person.id, name: person.name, place: "", reason: label, lastContact: person.lastContact)
        }
        .sorted { $0.lastContact < $1.lastContact }
    }

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
            // Last time you were "in touch": their note's own date, or the newest note that
            // links them (a diary entry, a call log, a reconnection) — whichever is later.
            let lastLink = backlinks(to: n).map(\.date).max()
            let lastContact = max(n.date, lastLink ?? .distantPast)
            out.append(PersonPlaces(id: n.id, name: n.displayName, text: text, lastContact: lastContact))
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
                cityHits.append(ReconnectPrompt(id: person.id, name: person.name, place: place, reason: cityReason, lastContact: person.lastContact))
            } else if (stateFull != nil && t.contains(stateFull!)) || (codeRe?.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil) {
                stateHits.append(ReconnectPrompt(id: person.id, name: person.name, place: place, reason: stateReason, lastContact: person.lastContact))
            } else if let rawNeedle, t.contains(rawNeedle) {
                cityHits.append(ReconnectPrompt(id: person.id, name: person.name, place: place, reason: cityReason, lastContact: person.lastContact))
            }
        }
        // Most OVERDUE first (oldest contact) — the whole point is "near you AND out of touch".
        let byStaleness: (ReconnectPrompt, ReconnectPrompt) -> Bool = { $0.lastContact < $1.lastContact }
        return cityHits.sorted(by: byStaleness) + stateHits.sorted(by: byStaleness)
    }

    private var lastNudgeCheck = Date.distantPast
    private static let nudgeDatesKey = "reconnect_nudge_dates"

    /// The most overdue friend near you right now — for a gentle nudge on the Notes tab (never
    /// a background push; that would fight the app's quiet ethos). nil unless location is
    /// granted, you're somewhere that matches a person's note, they're 45+ days out of touch,
    /// and they weren't nudged in the last few days. GPS-throttled to ~once every 3 hours so
    /// it doesn't hit location on every view appearance.
    func nearbyOverduePrompt() async -> ReconnectPrompt? {
        guard Date().timeIntervalSince(lastNudgeCheck) > 3 * 3600 else { return nil }
        guard autoLocator.isAuthorized, let c = await autoLocator.currentCoordinate() else { return nil }
        lastNudgeCheck = Date()
        let matches = peopleNear(latitude: c.latitude, longitude: c.longitude)   // real GPS distance
        let cal = Calendar.current
        let overdueCutoff = cal.date(byAdding: .day, value: -45, to: Date()) ?? .distantPast
        let nudged = (UserDefaults.standard.dictionary(forKey: Self.nudgeDatesKey) as? [String: Date]) ?? [:]
        let quietUntil = cal.date(byAdding: .day, value: -4, to: Date()) ?? .distantPast
        return matches.first {   // already sorted most-overdue first
            $0.lastContact < overdueCutoff && (nudged[$0.id.uuidString] ?? .distantPast) < quietUntil
        }
    }

    /// "6mo/2y out of touch" — nil until it's genuinely been a while (45+ days), so a
    /// recently-seen person isn't flagged as overdue. Shared by the Reconnect list + nudge.
    static func outOfTouchLabel(_ date: Date) -> String? {
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        guard days >= 45 else { return nil }
        if days >= 365 { return "\(days / 365)y out of touch" }
        return "\(days / 30)mo out of touch"
    }

    /// Remember we nudged (or you dismissed) this person, so we don't nag again for a few days.
    func recordNudged(_ id: UUID) {
        var dates = (UserDefaults.standard.dictionary(forKey: Self.nudgeDatesKey) as? [String: Date]) ?? [:]
        dates[id.uuidString] = Date()
        UserDefaults.standard.set(dates, forKey: Self.nudgeDatesKey)
    }

    // MARK: - Weekly review (a quiet, once-a-week look at what you tended and who's drifting)

    struct WeeklyDigest {
        struct Person: Identifiable { let id: UUID; let name: String; let lastContact: Date }
        let tendedAxisIDs: [String]   // life areas you touched in the last 7 days
        let quietAxisIDs: [String]    // areas that went untended
        let drifting: [Person]        // people you've most fallen out of touch with
        let reflection: String?       // the app's current grounded observation, if any
        var isEmpty: Bool { tendedAxisIDs.isEmpty && quietAxisIDs.isEmpty && drifting.isEmpty && reflection == nil }
    }

    /// People (not stubs) you've fallen out of touch with, most-overdue first — for the review.
    func peopleByStaleness(overdueDays: Int = 45, limit: Int = 4) -> [WeeklyDigest.Person] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -overdueDays, to: Date()) ?? .distantPast
        var out: [WeeklyDigest.Person] = []
        for n in notes {
            let f = Folder.normalize(n.folderName)
            guard (f == "people" || f == "contacts"), !n.isStub else { continue }
            let last = max(n.date, backlinks(to: n).map(\.date).max() ?? .distantPast)
            if last < cutoff { out.append(WeeklyDigest.Person(id: n.id, name: n.displayName, lastContact: last)) }
        }
        return Array(out.sorted { $0.lastContact < $1.lastContact }.prefix(limit))
    }

    /// A gentle weekly digest: which life areas you tended, which went quiet, who you've
    /// drifted from, and one grounded observation — built entirely from signals you already
    /// have (last-tended dates, staleness, the reflection engine).
    func weeklyDigest() -> WeeklyDigest {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        var tended: [String] = [], quiet: [String] = []
        for a in axes {
            if let last = lastTendedByAxis[a.id], last >= weekAgo { tended.append(a.id) } else { quiet.append(a.id) }
        }
        return WeeklyDigest(tendedAxisIDs: tended, quietAxisIDs: quiet,
                            drifting: peopleByStaleness(), reflection: currentReflection()?.text)
    }

    // Once-a-week gating for the review card, by ISO week.
    private static let lastReviewWeekKey = "weekly_review_week"

    /// True when a new week has begun since the review was last surfaced (so the card shows
    /// at most once a week). Reading it doesn't consume it — call `markReviewSeen()` for that.
    var weeklyReviewDue: Bool {
        let cal = Calendar(identifier: .iso8601)
        let now = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        let key = "\(now.yearForWeekOfYear ?? 0)-\(now.weekOfYear ?? 0)"
        return UserDefaults.standard.string(forKey: Self.lastReviewWeekKey) != key
    }

    func markReviewSeen() {
        let cal = Calendar(identifier: .iso8601)
        let now = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        UserDefaults.standard.set("\(now.yearForWeekOfYear ?? 0)-\(now.weekOfYear ?? 0)", forKey: Self.lastReviewWeekKey)
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
    /// Look up genres for Kindle/Readwise books from Google Books and link each to a
    /// `books/genre/<Genre>` note, so your library groups by genre. Skips books already
    /// tagged; throttled to be polite; applies all results in one save. Returns how many
    /// were tagged.
    /// Strip Obsidian link artifacts from a name — a trailing ".md" and any "#heading" /
    /// "#^block" reference — so "Hamnet.md#tr-nj9gce2d2" reads as "Hamnet".
    static func cleanObsidianName(_ name: String) -> String {
        var s = name
        if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
        if s.lowercased().hasSuffix(".md") { s = String(s.dropLast(3)) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Fix note names mangled by an Obsidian import — a trailing ".md" or a "#…" block/heading
    /// reference in the title (e.g. "Hamnet.md#tr-nj9gce2d2" → "Hamnet"). Renames them; links
    /// follow and collisions merge. Returns how many were fixed.
    @discardableResult
    func cleanupObsidianTitles() -> Int {
        var pairs: [(old: String, new: String)] = []
        for n in notes {
            let cleaned = Self.cleanObsidianName(n.displayName)
            guard cleaned != n.displayName, !cleaned.isEmpty else { continue }
            let folder = n.folderName
            let newTitle = folder.isEmpty ? cleaned : folder + "/" + cleaned
            guard Self.norm(newTitle) != Self.norm(n.title) else { continue }
            pairs.append((n.title, newTitle))
        }
        guard !pairs.isEmpty else { return 0 }
        retitle(pairs)
        return pairs.count
    }

    /// How many notes have Obsidian-artifact names to fix (for the confirmation prompt).
    func obsidianArtifactCount() -> Int {
        notes.filter { Self.cleanObsidianName($0.displayName) != $0.displayName }.count
    }

    func backfillBookGenres(limit: Int = 120) async -> Int {
        // Any note filed under books/ (except the genre sub-notes themselves), regardless of
        // how it got there — direct Readwise sync (origin "readwise") OR the Obsidian vault
        // import (origin "obsidian"). Skips ones already tagged.
        let books = notes.filter {
            let f = Folder.normalize($0.folderName)
            return (f == "books" || f.hasPrefix("books/")) && !f.hasPrefix("books/genre")
                && !$0.linkTargets.contains(where: { $0.lowercased().hasPrefix("books/genre/") })
        }
        var results: [(id: UUID, genre: String)] = []
        for book in books.prefix(limit) {
            let author = book.details.first { $0.key.caseInsensitiveCompare("Author") == .orderedSame }?.value
            // Query with a cleaned title so a mangled "Hamnet.md#…" still matches "Hamnet".
            if let genre = await GoogleBooksService.genre(title: Self.cleanObsidianName(book.displayName), author: author) {
                results.append((book.id, genre))
            }
            try? await Task.sleep(nanoseconds: 250_000_000)   // ~4/sec, gentle on the API
        }
        applyBookGenres(results)
        return results.count
    }

    private func applyBookGenres(_ pairs: [(id: UUID, genre: String)]) {
        guard !pairs.isEmpty else { return }
        var newStubs: [String] = []
        for (id, genre) in pairs {
            guard let i = notes.firstIndex(where: { $0.id == id }) else { continue }
            let target = "books/genre/\(genre)"
            guard !notes[i].linkTargets.contains(where: { Self.norm($0) == Self.norm(target) }) else { continue }
            let sep = notes[i].body.isEmpty || notes[i].body.hasSuffix("\n") ? "" : "\n"
            notes[i].body += sep + "[[\(target)]]"
            if !noteExists(titled: target), !newStubs.contains(where: { Self.norm($0) == Self.norm(target) }) {
                newStubs.append(target)
            }
        }
        for target in newStubs {
            ensureCategoryFolder(Self.folderPart(of: target))
            notes.append(Note(title: target, isStub: true))
        }
        persist()
    }

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

    /// Folders whose notes are things you *evaluate* — so a 1–5 star rating makes sense.
    /// Matched against any component of the folder path (so `travel/restaurant` counts).
    /// Folders where a 1–5 star rating doesn't belong — journals, people, and activity
    /// logs. Everything else (books, wine, golf clubs, gear, restaurants, whatever you
    /// collect or evaluate) shows stars, so you're never blocked by a hardcoded list.
    static let nonRateableFolders: Set<String> = [
        "notes", "diary", "journal", "people", "contacts", "health", "workouts",
        "calendar", "concierge",
    ]

    /// True when a note's folder can carry a star rating — i.e. it isn't a journal, a
    /// person, or an activity log. Judged by the top-level folder.
    static func isRateableFolder(_ folderName: String) -> Bool {
        let top = folderName.lowercased().split(separator: "/").first.map(String.init) ?? ""
        return !top.isEmpty && !nonRateableFolders.contains(top)
    }

    /// True when a note is a book (under books/, but not a genre grouping note).
    static func isBookFolder(_ folderName: String) -> Bool {
        let f = Folder.normalize(folderName)
        return (f == "books" || f.hasPrefix("books/")) && !f.hasPrefix("books/genre")
    }

    /// Genre names already in use (the books/genre/* notes), for the picker.
    func existingGenres() -> [String] {
        notes.filter { Folder.normalize($0.folderName) == "books/genre" }
            .map { $0.displayName }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// A book's current genre, from its `[[books/genre/…]]` link (nil if none).
    func genre(of note: Note) -> String? {
        for t in note.linkTargets where t.lowercased().hasPrefix("books/genre/") {
            return String(t.dropFirst("books/genre/".count))
        }
        return nil
    }

    /// Set (or clear, with nil) a book's genre — swaps its `[[books/genre/…]]` link and the
    /// "Genre" detail, creating the genre note if needed.
    func setBookGenre(_ id: UUID, to genre: String?) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        // Drop any existing genre-link line and Genre detail.
        let kept = notes[i].body.components(separatedBy: "\n").filter { line in
            let t = line.trimmingCharacters(in: .whitespaces).lowercased()
            return !(t.hasPrefix("[[books/genre/") && t.hasSuffix("]]"))
        }
        var body = kept.joined(separator: "\n")
        notes[i].details.removeAll { $0.key.caseInsensitiveCompare("Genre") == .orderedSame }
        if let genre = genre?.trimmingCharacters(in: .whitespaces), !genre.isEmpty {
            let sep = body.isEmpty || body.hasSuffix("\n") ? "" : "\n"
            body += sep + "[[books/genre/\(genre)]]"
            notes[i].details.append(NoteDetail(key: "Genre", value: genre))
            let target = "books/genre/\(genre)"
            if !noteExists(titled: target) {
                ensureCategoryFolder("books/genre")
                notes.append(Note(title: target, isStub: true))
            }
        }
        notes[i].body = body
        persist()
    }

    /// Set (or clear, with nil) a note's 1–5 star rating.
    func setRating(_ id: UUID, to rating: Int?) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        let clamped = rating.map { min(5, max(1, $0)) }
        guard notes[i].rating != clamped else { return }
        notes[i].rating = clamped
        persist()
    }

    /// True when a note's name begins with a date (`2026-08-15 …`) — i.e. a diary/journal
    /// entry that's titled by its date rather than a person or place.
    static func isDateTitled(_ name: String) -> Bool {
        name.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil
    }

    /// Change a note's date — the value the Notes stream and Calendar order by — so a
    /// backdated entry sorts under the day it happened, not the day you wrote it. For a
    /// date-titled diary/journal entry the title stamp is regenerated to match (and any
    /// links to it follow), and it re-checks trip auto-linking for its new date.
    func setNoteDate(_ id: UUID, to newDate: Date) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].date != newDate else { return }
        notes[i].date = newDate
        addTripLinkIfNeeded(i)   // a trip may now (or no longer) cover this date

        if Self.isDateTitled(notes[i].displayName) {
            let folder = notes[i].folderName
            let newTitle = (folder.isEmpty ? "" : folder + "/") + Self.dateTimeStamp(newDate)
            if Self.norm(newTitle) != Self.norm(notes[i].title),
               !notes.contains(where: { $0.id != id && Self.norm($0.title) == Self.norm(newTitle) }) {
                retitle([(notes[i].title, newTitle)])   // moves the note + rewrites links, then persists
                return
            }
        }
        persist()
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
        // MKLocalSearch first (finds businesses/restaurants), then the address geocoder.
        if let hit = await LocationService.searchPlace(name, near: near),
           let i = notes.firstIndex(where: { $0.id == id }) {
            commitPlaces([Place(name: hit.name, latitude: hit.latitude, longitude: hit.longitude)], to: i)
        } else if let c = await LocationService.coordinate(for: name, near: near),
                  let i = notes.firstIndex(where: { $0.id == id }) {
            commitPlaces([Place(name: name, latitude: c.latitude, longitude: c.longitude)], to: i)
        }
    }

    /// Rename or move a folder path (e.g. `entertainment/restaurant` →
    /// `travel/restaurant`): every note under it (and its subfolders) moves, its
    /// links are rewritten, and the folder's settings carry over to the new path.
    func renameFolder(from oldPathRaw: String, to newPathRaw: String) {
        let oldPath = oldPathRaw.trimmingCharacters(in: .whitespaces)
        let newPath = newPathRaw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Exact (case-SENSITIVE) compare: renaming "Medical" → "medical" must be allowed, so
        // two folders differing only in case can be merged. A norm() compare treated them as
        // the same folder and silently no-op'd the merge/move.
        guard !oldPath.isEmpty, !newPath.isEmpty, oldPath != newPath else { return }

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

    /// Move a whole folder (and its subtree) so it becomes a subfolder of `targetRaw` —
    /// e.g. drag the "food" drawer onto "meals" to get "meals/food". Every note retitles and
    /// all links rewrite (via renameFolder). No-ops if it would move a folder into itself,
    /// into its own subtree, or where it already lives. Returns whether anything moved.
    @discardableResult
    func moveFolder(_ pathRaw: String, into targetRaw: String) -> Bool {
        let path = pathRaw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let target = targetRaw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty, !target.isEmpty else { return false }
        let l = path.lowercased(), t = target.lowercased()
        // Not into itself, and not into its own descendant (would orphan/cycle).
        guard l != t, !t.hasPrefix(l + "/") else { return false }
        let leaf = path.split(separator: "/").last.map(String.init) ?? path
        let newPath = target + "/" + leaf
        guard newPath.lowercased() != l else { return false }   // already a child of target
        renameFolder(from: path, to: newPath)
        return true
    }

    /// Move a single note into `folderPath` (e.g. drag-and-drop onto a folder). Retitles
    /// it to `folderPath/name`, rewrites every `[[link]]` to it, seeds the destination
    /// folder's metadata if it's brand-new, and merges if a same-named note already lives
    /// there. Returns false if the note is missing or already in that folder.
    @discardableResult
    func moveNote(_ id: UUID, toFolder folderPath: String) -> Bool {
        guard let note = notes.first(where: { $0.id == id }) else { return false }
        // Re-case the destination to an existing folder's casing so moving into "Travel"
        // when "travel" exists lands in the SAME folder, not a case-variant twin.
        let dest = canonicalFolderCasing(folderPath.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        let newTitle = dest.isEmpty ? note.displayName : dest + "/" + note.displayName
        // Exact compare so a note can move between folders that differ only in case
        // ("Medical" → "medical"); a norm() compare skipped it as "already here".
        guard newTitle != note.title else { return false }
        ensureFolderExists(for: newTitle, like: note.title)
        retitle([(old: note.title, new: newTitle)])
        return true
    }

    /// Move several notes into `folderPath` in one reflow (one save, one rescore) —
    /// for multi-select. No-op for any note already there.
    func moveNotes(_ ids: [UUID], toFolder folderPath: String) {
        let dest = canonicalFolderCasing(folderPath.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var pairs: [(old: String, new: String)] = []
        for id in ids {
            guard let note = notes.first(where: { $0.id == id }) else { continue }
            let newTitle = dest.isEmpty ? note.displayName : dest + "/" + note.displayName
            guard newTitle != note.title else { continue }
            ensureFolderExists(for: newTitle, like: note.title)
            pairs.append((old: note.title, new: newTitle))
        }
        guard !pairs.isEmpty else { return }
        retitle(pairs)
    }

    /// Notes in `folderPath` (and its subfolders) that are completely unlinked — no
    /// `[[links]]` in their own body AND not the target of a link from any other note.
    /// These are the isolated imports (a contact you never wrote about, a book nothing
    /// references) — the ones worth pruning to keep only connected notes.
    func unlinkedNotes(inFolder folderPath: String) -> [Note] {
        let p = folderPath.lowercased()
        func within(_ n: Note) -> Bool { let f = n.folderName.lowercased(); return f == p || f.hasPrefix(p + "/") }
        var linkedTargets = Set<String>()
        for n in notes { for t in n.linkTargets { linkedTargets.insert(Self.norm(t)) } }
        return notes.filter { within($0) && $0.linkTargets.isEmpty && !linkedTargets.contains(Self.norm($0.title)) }
    }

    /// (duplicate note, the title of the original it duplicates) for notes named "X (2)",
    /// "X (3)"… whose base "X" exists in the same folder — the accidental re-import copies.
    private func duplicatePairs(inFolder folderPath: String?) -> [(dup: Note, baseTitle: String)] {
        let existing = Set(notes.map { Self.norm($0.title) })
        let regex = try? NSRegularExpression(pattern: #"^(.+) \(\d+\)$"#)
        var out: [(dup: Note, baseTitle: String)] = []
        for n in notes {
            if let folderPath {
                let f = n.folderName.lowercased(), p = folderPath.lowercased()
                guard f == p || f.hasPrefix(p + "/") else { continue }
            }
            let name = n.displayName as NSString
            guard let m = regex?.firstMatch(in: n.displayName, range: NSRange(location: 0, length: name.length)),
                  m.numberOfRanges >= 2 else { continue }
            let base = name.substring(with: m.range(at: 1))
            let baseTitle = n.folderName.isEmpty ? base : n.folderName + "/" + base
            guard existing.contains(Self.norm(baseTitle)) else { continue }   // original must still exist
            out.append((n, baseTitle))
        }
        return out
    }

    /// Notes that are disambiguated duplicates ("Sam Davey (2)") of an existing original.
    func duplicateNotes(inFolder folderPath: String? = nil) -> [Note] {
        duplicatePairs(inFolder: folderPath).map(\.dup)
    }

    /// Merge folders that differ only in case ("travel"/"Travel", "books"/"Books") into a
    /// single canonical casing, and merge any notes that then share a title (via the same
    /// lossless dedupe). Returns how many duplicate notes were merged away.
    @discardableResult
    func mergeFolderCaseVariants() -> Int {
        // Canonical casing per normalized folder prefix: prefer a folder record's casing,
        // else the most-common casing across notes.
        var votes: [String: [String: Int]] = [:]
        func tally(_ path: String, weight: Int) {
            var acc = ""
            for seg in path.split(separator: "/").map(String.init) {
                acc = acc.isEmpty ? seg : acc + "/" + seg
                votes[Self.norm(acc), default: [:]][acc, default: 0] += weight
            }
        }
        for f in folders { tally(f.name, weight: 100) }
        for n in notes where !n.folderName.isEmpty { tally(n.folderName, weight: 1) }
        var canon: [String: String] = [:]
        for (k, m) in votes { canon[k] = m.max { $0.value < $1.value }!.key }

        func canonFolder(_ path: String) -> String {
            var acc = "", out = ""
            for seg in path.split(separator: "/").map(String.init) {
                acc = acc.isEmpty ? seg : acc + "/" + seg
                let c = canon[Self.norm(acc)] ?? acc
                let last = c.split(separator: "/").last.map(String.init) ?? seg
                out = out.isEmpty ? last : out + "/" + last
            }
            return out
        }

        var pairs: [(old: String, new: String)] = []
        for n in notes where !n.folderName.isEmpty {
            let newFolder = canonFolder(n.folderName)
            if newFolder != n.folderName { pairs.append((n.title, newFolder + "/" + n.displayName)) }
        }
        for i in folders.indices {
            let c = canonFolder(folders[i].name)
            if c != folders[i].name { folders[i].name = c }
        }
        let before = notes.count
        if !pairs.isEmpty { retitle(pairs) }   // re-case + rewrite links + globally dedupe same-title notes
        else { dedupeByTitle(); persist() }    // still merge any exact same-title duplicates
        return before - notes.count
    }

    /// Merge each "X (2)" duplicate INTO the original "X" — combining body, details, places
    /// and photos, repointing any `[[links]]` that pointed at the copy — then remove the
    /// copy. Nothing unique to the duplicate is lost. Returns how many were merged.
    @discardableResult
    func mergeDuplicates(inFolder folderPath: String? = nil) -> Int {
        let pairs = duplicatePairs(inFolder: folderPath)
        guard !pairs.isEmpty else { return 0 }
        var toDelete = Set<UUID>()
        var linkMap: [String: String] = [:]   // norm(duplicate title) → original title
        for (dup, baseTitle) in pairs {
            guard let bi = notes.firstIndex(where: { Self.norm($0.title) == Self.norm(baseTitle) }) else { continue }
            notes[bi].body = Self.mergeBodies(existing: notes[bi].body, incoming: dup.body)
            notes[bi].details = Self.mergeDetails(notes[bi].details, dup.details)
            var places = notes[bi].allPlaces
            for p in dup.allPlaces where !places.contains(where: { $0.name.caseInsensitiveCompare(p.name) == .orderedSame }) {
                places.append(p)
            }
            if !places.isEmpty {
                notes[bi].places = places
                if notes[bi].location?.isEmpty != false { notes[bi].location = places.first?.name }
            }
            if let dupPhotos = dup.photos, !dupPhotos.isEmpty {
                var photos = notes[bi].photos ?? []
                for ph in dupPhotos where !photos.contains(ph) { photos.append(ph) }
                notes[bi].photos = photos
            }
            if notes[bi].isStub && !dup.isStub { notes[bi].isStub = false }   // engaged copy wins
            linkMap[Self.norm(dup.title)] = baseTitle
            toDelete.insert(dup.id)
        }
        guard !toDelete.isEmpty else { return 0 }
        notes.removeAll { toDelete.contains($0.id) }
        for i in notes.indices where notes[i].body.contains("[[") {
            let rewritten = WikilinkParser.rewrite(in: notes[i].body) { linkMap[Self.norm($0)] ?? $0 }
            if rewritten != notes[i].body { notes[i].body = rewritten }
        }
        persist()
        return toDelete.count
    }

    /// Merge duplicates robustly: fold "X (2)" copies into "X" AND collapse any notes that
    /// simply share the same title (e.g. a book re-created by a Readwise sync sitting next to
    /// the merged original). Lossless — bodies/details/places/photos/rating are combined.
    /// Returns how many notes were removed. Global (title collisions aren't folder-scoped),
    /// but callers trigger it from a folder's menu.
    @discardableResult
    func mergeDuplicatesAndDedupe(inFolder folderPath: String? = nil) -> Int {
        let before = notes.count
        mergeDuplicates(inFolder: folderPath)   // "X (2)" → "X" (persists)
        dedupeByTitle()                         // exact same-title collisions anywhere
        pruneEmptyFolders()
        persist()
        return before - notes.count
    }

    /// How many notes would `mergeDuplicatesAndDedupe` remove — the "(2)" copies plus any
    /// exact same-title collisions. Drives the folder menu's count/label.
    func mergeableDuplicateCount(inFolder folderPath: String? = nil) -> Int {
        var seen = Set<String>(), extra = 0
        for n in notes {
            if !seen.insert(Self.norm(n.title)).inserted { extra += 1 }
        }
        return duplicatePairs(inFolder: folderPath).count + extra
    }

    /// Delete several folders (and everything filed under them) in one save.
    func deleteFolders(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        for path in paths {
            let p = path.lowercased()
            notes.removeAll { let l = $0.folderName.lowercased(); return l == p || l.hasPrefix(p + "/") }
            folders.removeAll { let l = $0.name.lowercased(); return l == p || l.hasPrefix(p + "/") }
            let pn = Folder.normalize(path)
            manualFolders = manualFolders.filter { $0 != pn && !$0.hasPrefix(pn + "/") }
        }
        persist()
    }

    /// Drop folder records that no longer have any note filed under them (after a move or
    /// merge empties a category). Otherwise an emptied folder lingers — and its stale casing
    /// could re-impose itself (via canonicalFolderCasing) on the next note you file there.
    private func pruneEmptyFolders() {
        var used = Set<String>()
        for note in notes {
            let comps = note.title.split(separator: "/").map(String.init)
            guard comps.count > 1 else { continue }
            var acc = ""
            for seg in comps.dropLast() {
                acc = acc.isEmpty ? seg : acc + "/" + seg
                used.insert(Folder.normalize(acc))
            }
        }
        // Keep folders the user made on purpose (may be empty) — only prune truly stale ones.
        folders.removeAll { !used.contains($0.id) && !manualFolders.contains($0.id) }
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
        pruneEmptyFolders()
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
            // Two notes now share a title (e.g. after merging folders). Keep the richer one
            // but MERGE the other's content into it first, so nothing is lost.
            let winner: Int, loser: Int
            if Self.richer(notes[i], than: notes[kept]) { winner = i; loser = kept; keptIndexByTitle[key] = i }
            else { winner = kept; loser = i }
            mergeContent(from: notes[loser], into: winner)
            dropIDs.append(notes[loser].id)
        }
        if !dropIDs.isEmpty {
            let drop = Set(dropIDs)
            notes.removeAll { drop.contains($0.id) }
        }
    }

    /// Fold one note's content (body lines, details, places, photos) into another at index
    /// `into`, without duplicating. Used when two notes collapse to the same title.
    private func mergeContent(from other: Note, into i: Int) {
        guard notes.indices.contains(i) else { return }
        notes[i].body = Self.mergeBodies(existing: notes[i].body, incoming: other.body)
        notes[i].details = Self.mergeDetails(notes[i].details, other.details)
        var places = notes[i].allPlaces
        for p in other.allPlaces where !places.contains(where: { $0.name.caseInsensitiveCompare(p.name) == .orderedSame }) {
            places.append(p)
        }
        if !places.isEmpty { notes[i].places = places }
        if let otherPhotos = other.photos, !otherPhotos.isEmpty {
            var photos = notes[i].photos ?? []
            for ph in otherPhotos where !photos.contains(ph) { photos.append(ph) }
            notes[i].photos = photos
        }
        if notes[i].isStub && !other.isStub { notes[i].isStub = false }
        if notes[i].rating == nil { notes[i].rating = other.rating }
        // Keep a re-syncing origin (Readwise) so a later sync UPDATES this surviving note
        // instead of re-creating the duplicate we're merging away.
        if notes[i].origin?.source != "readwise", other.origin?.source == "readwise" {
            notes[i].origin = other.origin
        } else if notes[i].origin == nil {
            notes[i].origin = other.origin
        }
    }

    private static func richer(_ a: Note, than b: Note) -> Bool {
        if a.isStub != b.isStub { return !a.isStub }   // prefer an engaged note
        return a.body.count > b.body.count
    }

    // MARK: - Internals

    private func persist() {
        let t0 = CFAbsoluteTimeGetCurrent()
        recomputeLookupIndexes()          // O(1) note/folder lookups for everything below (+ views)
        avatarGraphDirty = true           // avatar connectome rebuilds lazily on next view
        score = engine.score(notes: notes, folders: folders, axes: axes)
        let t1 = CFAbsoluteTimeGetCurrent()
        recomputeLastTended()
        let t2 = CFAbsoluteTimeGetCurrent()
        recomputeCabinetGroups()          // cache the Folders-tab grouping once, not per render
        recomputeBacklinkIndex()          // cache backlinks once (before places — pin labels use them)
        recomputeMappablePlaces()         // cache the Map's plottable places once, not per render
        let t3 = CFAbsoluteTimeGetCurrent()
        storage.save(currentSnapshot())   // encodes + writes on a background queue
        runAutoBackup()
        let total = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        if total > 150 {   // only flag a genuinely slow persist; ~25ms is fine and shouldn't spam
            print(String(format: "⏱️[perf] persist %.0fms (score %.0f · tended %.0f · cabinets %.0f) notes=%d links=%d",
                         total, (t1 - t0) * 1000, (t2 - t1) * 1000, (t3 - t2) * 1000, notes.count, score.links.count))
        }
    }

    // MARK: - Automatic backup (survives deleting the app)

    private static let autoBackupKey = "auto_backup_folder_bookmark"
    /// The name of the folder auto-backups are written to (nil = off), for display in Settings.
    @Published private(set) var autoBackupFolderName: String?
    private var lastAutoBackup = Date.distantPast

    var isAutoBackupOn: Bool { UserDefaults.standard.data(forKey: Self.autoBackupKey) != nil }

    /// Turn on auto-backup: remember a user-chosen folder (ideally in iCloud Drive) and write
    /// a copy of the data there now and on every change. A security-scoped bookmark keeps
    /// access across launches — no iCloud entitlement needed.
    @discardableResult
    func enableAutoBackup(folder url: URL) -> Bool {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? url.bookmarkData() else { return false }
        UserDefaults.standard.set(bookmark, forKey: Self.autoBackupKey)
        autoBackupFolderName = url.lastPathComponent
        runAutoBackup(force: true)
        return true
    }

    func disableAutoBackup() {
        UserDefaults.standard.removeObject(forKey: Self.autoBackupKey)
        autoBackupFolderName = nil
    }

    /// Write the current store into the auto-backup folder (throttled), as both a
    /// per-day file and a "latest" file. No-op when auto-backup is off.
    func runAutoBackup(force: Bool = false) {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.autoBackupKey) else { return }
        if !force, Date().timeIntervalSince(lastAutoBackup) < 20 { return }   // don't hammer iCloud
        lastAutoBackup = Date()
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        // Encode + write happen on a background queue (see Storage.backup) so a big store
        // being copied to iCloud never freezes the UI.
        storage.backup(currentSnapshot(), resolving: bookmark,
                       filenames: ["Numinous-backup-\(df.string(from: Date())).json", "Numinous-latest.json"]) { refreshed in
            UserDefaults.standard.set(refreshed, forKey: Self.autoBackupKey)
        }
    }

    /// Force a synchronous write of the store now — call when the app backgrounds so a
    /// just-made change can't be lost to an in-flight async save.
    func flush() { storage.saveSync(currentSnapshot()) }

    /// An immutable snapshot of everything persisted — safe to hand to a background queue.
    private func currentSnapshot() -> StoredData {
        StoredData(notes: notes, folders: folders, axes: axes,
                   schemaVersion: Self.schemaVersion, reflections: reflectionLog,
                   followUps: followUps, linkLearning: linkLearning, manualFolders: Array(manualFolders))
    }

    // MARK: - Find-links learning (suggestions get better with your decisions)

    /// What Find-links has learned. Persisted; consulted on every scan.
    @Published private(set) var linkLearning = LinkLearning()

    /// Folder paths (normalized ids) the user created explicitly — kept even when empty,
    /// so a folder you make to organize into doesn't vanish before you file anything in it.
    @Published private(set) var manualFolders: Set<String> = []

    /// Create an empty folder now (no note required). It persists and survives the
    /// empty-folder prune until you file notes in it. Returns false if the name is blank.
    @discardableResult
    func createFolder(_ name: String, category: String = "Notes", axisID: String? = nil) -> Bool {
        let path = name.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
            .trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return false }
        let canonical = canonicalFolderCasing(path)
        manualFolders.insert(Folder.normalize(canonical))
        if folder(named: canonical) == nil {
            folders.append(Folder(name: canonical, category: category, axisID: axisID))
        }
        persist()
        return true
    }

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
                                followUps: followUps, linkLearning: linkLearning, manualFolders: Array(manualFolders)))
    }

    // MARK: - Vitality (gentle decay of untended areas — never subtracts real growth)

    private var lastTendedByAxis: [String: Date] = [:]

    private func recomputeLastTended() {
        // Index titles once so resolving each link target is O(1). Previously this did a
        // linear `note(titled:)` scan per link — O(n²) on every save, a real hitch once a
        // vault import made the note count large.
        let byTitle = Dictionary(notes.map { (Self.norm($0.title), $0) }, uniquingKeysWith: { a, _ in a })
        var map: [String: Date] = [:]
        func bump(_ axis: String, _ date: Date) {
            if let existing = map[axis] { if date > existing { map[axis] = date } } else { map[axis] = date }
        }
        for n in notes where !n.isStub {
            for a in folder(named: n.folderName)?.growthAxes ?? [] { bump(a, n.date) }
            for t in n.linkTargets {
                if let other = byTitle[Self.norm(t)], let a = axis(for: other)?.id { bump(a, n.date) }
            }
        }
        lastTendedByAxis = map
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
        // Encode the current state straight to the export file, rather than copying
        // store.json — the on-disk file is now written asynchronously, so copying it
        // could grab a slightly stale version.
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd-HHmm"
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("Numinous-backup-\(df.string(from: Date())).json")
        try? FileManager.default.removeItem(at: dest)
        return storage.writeSnapshot(currentSnapshot(), to: dest) ? dest : nil
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
    /// Apply several geocoded coordinates in ONE save — used by the Map's background
    /// backfill so it doesn't persist (and re-render the whole map) once per place, which
    /// made the map sticky right after opening it.
    func addPlaces(_ items: [(id: UUID, name: String, latitude: Double, longitude: Double)]) {
        var changed = false
        for item in items {
            guard let i = notes.firstIndex(where: { $0.id == item.id }) else { continue }
            let n = item.name.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { continue }
            var places = notes[i].allPlaces
            if let j = places.firstIndex(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) {
                places[j].latitude = item.latitude; places[j].longitude = item.longitude
            } else {
                places.append(Place(name: n, latitude: item.latitude, longitude: item.longitude))
            }
            let newPlaces = places.isEmpty ? nil : places
            if notes[i].places != newPlaces {
                notes[i].places = newPlaces
                notes[i].location = places.first?.name
                applyTravelValue(i)
                changed = true
            }
        }
        if changed { persist() }
    }

    /// Create a note for a place you searched on the map (name + coordinate), filed under
    /// `places`. Returns its id so the caller can open it.
    @discardableResult
    func createPlaceNote(name: String, latitude: Double, longitude: Double) -> UUID {
        let leaf = name.trimmingCharacters(in: .whitespaces)
        let folderName = preferredPlaceFolder()
        if folder(named: folderName) == nil {
            folders.append(Folder(name: folderName, category: "Places", axisID: "meaning"))
        }
        var title = folderName + "/" + leaf, k = 2
        while noteExists(titled: title) { title = "\(folderName)/\(leaf) (\(k))"; k += 1 }
        let note = Note(title: title, date: Date(),
                        location: leaf,
                        places: [Place(name: leaf, latitude: latitude, longitude: longitude)])
        notes.append(note)
        persist()
        return note.id
    }

    // MARK: - Enter a place once (name ↔ GPS ↔ note text ↔ graph)

    /// Ensure a `places/<Name>` note exists at these coordinates — a single place that's both
    /// a map pin and a connectable graph node. Returns its title (`places/<Name>`) so callers
    /// can link to it. Reuses an existing place note of the same name (filling in coordinates).
    /// The folder to file GPS/typed places under — reuse a place folder you ALREADY have
    /// (your built-in "location") instead of spawning a parallel "places". Defaults to
    /// "location" so places land in a natural, single home.
    func preferredPlaceFolder() -> String {
        for name in ["location", "locations", "places"] {
            if folder(named: name) != nil || notes.contains(where: { Folder.normalize($0.folderName) == name }) {
                return canonicalFolderCasing(name)
            }
        }
        return "location"
    }

    @discardableResult
    func ensurePlaceNote(name: String, latitude: Double, longitude: Double) -> String {
        let leaf = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        guard !leaf.isEmpty else { return "" }
        let folderName = preferredPlaceFolder()
        // Fold any stray, auto-created "places" notes into your place folder (links rewrite).
        if Folder.normalize(folderName) != "places" {
            let stray = notes.filter { Folder.normalize($0.folderName) == "places" }.map(\.id)
            if !stray.isEmpty { moveNotes(stray, toFolder: folderName) }
        }
        let title = folderName + "/" + leaf
        if let i = notes.firstIndex(where: { Self.norm($0.title) == Self.norm(title) }) {
            addPlace(notes[i].id, name: leaf, latitude: latitude, longitude: longitude)   // fills coords, persists
        } else {
            if folder(named: folderName) == nil {
                folders.append(Folder(name: folderName, category: "Places", axisID: "meaning"))
            }
            notes.append(Note(title: title, date: Date(), location: leaf,
                              places: [Place(name: leaf, latitude: latitude, longitude: longitude)]))
            persist()
        }
        return title
    }

    /// Append a `📍 [[places/…]]` link to a note's body (once), so a place is written into
    /// what you wrote — and becomes a real connection.
    func linkPlace(_ placeTitle: String, into noteID: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == noteID }),
              !placeTitle.isEmpty,
              !notes[i].linkTargets.contains(where: { Self.norm($0) == Self.norm(placeTitle) }) else { return }
        let sep = notes[i].body.isEmpty || notes[i].body.hasSuffix("\n") ? "" : "\n"
        updateBody(noteID, body: notes[i].body + sep + "📍 [[\(placeTitle)]]")
    }

    /// GPS → note: capture where you are, make it a place note + pin, and link it into the note.
    func captureCurrentPlace(into noteID: UUID) async {
        guard let p = await autoLocator.currentPlaceStructured(),
              let lat = p.latitude, let lng = p.longitude else { return }
        linkPlace(ensurePlaceNote(name: p.name, latitude: lat, longitude: lng), into: noteID)
    }

    /// Typed name → note: geocode it, make it a place note + pin, and link it into the note.
    func attachPlaceByName(_ name: String, into noteID: UUID) async {
        let near = autoLocator.isAuthorized ? await autoLocator.currentCoordinate() : nil
        if let hit = await LocationService.searchPlace(name, near: near) {
            linkPlace(ensurePlaceNote(name: hit.name, latitude: hit.latitude, longitude: hit.longitude), into: noteID)
        } else if let c = await LocationService.coordinate(for: name, near: near) {
            linkPlace(ensurePlaceNote(name: name, latitude: c.latitude, longitude: c.longitude), into: noteID)
        }
    }

    /// For the composer (a note that isn't saved yet): resolve a place to a `[[places/…]]`
    /// link string to weave into the text — GPS when `name` is nil, else the typed name.
    func placeLink(forName name: String?) async -> String? {
        let near = autoLocator.isAuthorized ? await autoLocator.currentCoordinate() : nil
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            if let hit = await LocationService.searchPlace(name, near: near) {
                return "[[\(ensurePlaceNote(name: hit.name, latitude: hit.latitude, longitude: hit.longitude))]]"
            }
            if let c = await LocationService.coordinate(for: name, near: near) {
                return "[[\(ensurePlaceNote(name: name, latitude: c.latitude, longitude: c.longitude))]]"
            }
            return nil
        }
        guard let p = await autoLocator.currentPlaceStructured(), let lat = p.latitude, let lng = p.longitude else { return nil }
        return "[[\(ensurePlaceNote(name: p.name, latitude: lat, longitude: lng))]]"
    }

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
    /// Give a place-type note coordinates from its NAME so it lands on the map — used both
    /// for a place note you write and for a `[[place link]]` that has no GPS yet. Skips notes
    /// that already have a coordinate. `allowGPSFallback` stamps your CURRENT location when the
    /// name can't be geocoded — right for a place you're at, wrong for a place merely linked
    /// (which could be anywhere), so callers linking places pass false.
    func autoLocatePlaceNote(_ id: UUID, allowGPSFallback: Bool = true) async {
        guard let note = note(id: id),
              Self.isPlaceLikeFolder(note.folderName),
              !note.allPlaces.contains(where: { $0.hasCoordinate }) else { return }
        let near = autoLocator.isAuthorized ? await autoLocator.currentCoordinate() : nil
        // Prefer MKLocalSearch — it resolves restaurants/cafés/shops by name (e.g.
        // "travel/restaurant/Blue Bottle"); the address geocoder is the fallback for
        // plain places, and your current location the last resort.
        if let hit = await LocationService.searchPlace(note.displayName, near: near) {
            addPlace(id, name: hit.name, latitude: hit.latitude, longitude: hit.longitude)
        } else if let c = await LocationService.coordinate(for: note.displayName, near: near) {
            addPlace(id, name: note.displayName, latitude: c.latitude, longitude: c.longitude)
        } else if allowGPSFallback, autoLocator.isAuthorized, let c = await autoLocator.currentCoordinate() {
            addPlace(id, name: note.displayName, latitude: c.latitude, longitude: c.longitude)
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
    func appendToTodayDiary(_ line: String) -> UUID { appendToDiary(on: Date(), line) }

    /// Append a line to the diary entry for a SPECIFIC day (creating that day's entry if
    /// there isn't one yet), dated to that day so it sorts chronologically. Used by the
    /// Calendar tab to file an event into the diary of its own date, not just today.
    @discardableResult
    func appendToDiary(on day: Date, _ line: String) -> UUID {
        let id = openDiary(on: day)   // the most recent entry for that day, or a fresh one
        if let note = self.note(id: id) {
            let sep = note.body.isEmpty ? "" : "\n"
            updateBody(id, body: note.body + sep + line)
        }
        return id
    }

    /// Delete a folder and every note filed under it (and its subfolders).
    func deleteFolder(_ path: String) {
        let p = path.lowercased()
        func under(_ s: String) -> Bool { let l = s.lowercased(); return l == p || l.hasPrefix(p + "/") }
        notes.removeAll { under($0.folderName) }
        folders.removeAll { under($0.name) }
        let pn = Folder.normalize(path)
        manualFolders = manualFolders.filter { $0 != pn && !$0.hasPrefix(pn + "/") }
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
        let raw = folder.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        let category = canonicalFolderCasing(raw.isEmpty ? "notes" : raw)
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
        // Auto-location for a place note is handled by save() above.
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
