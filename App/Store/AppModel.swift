import Foundation
import Combine
import NuminousCore

/// A folder's notes, for grouped display. A struct (not a tuple) so it's
/// `Identifiable` and usable directly in `ForEach`.
struct FolderGroup: Identifiable {
    let id: String       // folder path ("" = Unfiled)
    let notes: [Note]
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
        let f = loaded?.folders.isEmpty == false ? loaded!.folders : SampleData.folders
        let n = loaded?.notes.isEmpty == false ? loaded!.notes : SampleData.notes
        let a = (loaded?.axes.isEmpty == false) ? loaded!.axes : Axis.defaultSet
        self.folders = f
        self.notes = n
        self.axes = a
        self.score = ScoreEngine().score(notes: n, folders: f, axes: a)
        if loaded == nil { storage.save(StoredData(notes: n, folders: f, axes: a)) }
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
    /// Ensures the People folder exists. Returns how many were newly added.
    @discardableResult
    func importPeople(names: [String]) -> Int {
        if folder(named: "people") == nil {
            folders.append(Folder(name: "people", category: "Relationships", axisID: "heart"))
        }
        var added = 0
        for name in names {
            let title = "people/" + name
            if notes.contains(where: { Self.norm($0.title) == Self.norm(title) }) { continue }
            notes.append(Note(title: title))
            added += 1
        }
        if added > 0 { persist() }
        return added
    }

    func setFolderAxis(_ axisID: String, forFolder folderID: String) {
        guard let i = folders.firstIndex(where: { $0.id == folderID }) else { return }
        folders[i].axisID = axisID
        persist()
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
        storage.save(StoredData(notes: notes, folders: folders, axes: axes))
    }

    private static func norm(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
