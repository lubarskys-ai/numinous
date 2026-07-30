import Foundation
import Combine
import NuminousCore

/// The app's single source of truth: the notes, the categories, the axes, and
/// the derived growth. Everything the UI shows flows from here.
///
/// Mutations recompute the whole score from scratch — which is exactly how the
/// engine is meant to be used (it's a pure function), and it's what makes
/// remapping a category's axis reflow all history for free.
@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var notes: [Note] = []
    @Published private(set) var categories: [Category] = []
    @Published private(set) var axes: [Axis] = Axis.defaultSet
    @Published private(set) var score: ScoreResult

    private let engine = ScoreEngine()
    private let storage = Storage()
    private let classifier = AxisClassifier()

    init() {
        let loaded = storage.load()
        let seededCategories = loaded.categories.isEmpty ? SampleData.categories : loaded.categories
        let seededNotes = loaded.notes.isEmpty ? SampleData.notes : loaded.notes
        let seededAxes = loaded.axes.isEmpty ? Axis.defaultSet : loaded.axes

        self.axes = seededAxes
        self.categories = seededCategories
        self.notes = seededNotes
        self.score = ScoreEngine().score(notes: seededNotes, categories: seededCategories, axes: seededAxes)

        if loaded.notes.isEmpty && loaded.categories.isEmpty {
            storage.save(notes: seededNotes, categories: seededCategories, axes: seededAxes)
        }
    }

    // MARK: - Derived views

    /// Notes shown to the user, newest first, with pure untyped stubs pushed to
    /// the bottom (they're prompts to categorize, not finished entries).
    var sortedNotes: [Note] {
        notes.sorted { a, b in
            if a.date != b.date { return a.date > b.date }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    func category(_ id: String?) -> Category? {
        guard let id else { return nil }
        return categories.first { $0.id == id }
    }

    func axis(forCategory categoryID: String?) -> Axis? {
        guard let axisID = category(categoryID)?.axisID else { return nil }
        return axes.first { $0.id == axisID }
    }

    func axis(_ id: String?) -> Axis? {
        guard let id else { return nil }
        return axes.first { $0.id == id }
    }

    /// Whether a linked title already resolves to an existing note.
    func noteExists(titled title: String) -> Bool {
        let key = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.contains { $0.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == key }
    }

    // MARK: - Mutations

    /// Insert or update a note. Any `[[link]]` to a title that doesn't exist yet
    /// auto-creates an untyped stub, so capture stays frictionless.
    func save(_ note: Note) {
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = note
        } else {
            notes.append(note)
        }
        createStubs(for: note)
        persistAndRecompute()
    }

    func delete(_ toDelete: [Note]) {
        let ids = Set(toDelete.map(\.id))
        notes.removeAll { ids.contains($0.id) }
        persistAndRecompute()
    }

    @discardableResult
    func addCategory(name: String, axisID: String) -> Category {
        let id = Category.slug(name)
        if let existing = categories.first(where: { $0.id == id }) {
            return existing
        }
        let category = Category(id: id, name: name, axisID: axisID)
        categories.append(category)
        persistAndRecompute()
        return category
    }

    func setAxis(_ axisID: String, forCategory categoryID: String) {
        guard let index = categories.firstIndex(where: { $0.id == categoryID }) else { return }
        categories[index].axisID = axisID
        persistAndRecompute()
    }

    func renameAxis(_ axisID: String, name: String) {
        guard let index = axes.firstIndex(where: { $0.id == axisID }) else { return }
        axes[index].name = name
        persistAndRecompute()
    }

    func setAxisColor(_ axisID: String, hex: String) {
        guard let index = axes.firstIndex(where: { $0.id == axisID }) else { return }
        axes[index].colorHex = hex
        persistAndRecompute()
    }

    func resetAxes() {
        axes = Axis.defaultSet
        persistAndRecompute()
    }

    /// A pre-filled, overridable axis suggestion for a brand-new category.
    func suggestAxis(forNewCategoryNamed name: String) -> AxisClassifier.Suggestion {
        classifier.suggestAxis(forNewCategoryNamed: name, existingCategories: categories, axes: axes)
    }

    // MARK: - Internals

    private func createStubs(for note: Note) {
        for target in note.linkTargets where !noteExists(titled: target) {
            notes.append(Note(title: target, categoryID: nil, date: note.date, isStub: true))
        }
    }

    private func persistAndRecompute() {
        score = engine.score(notes: notes, categories: categories, axes: axes)
        storage.save(notes: notes, categories: categories, axes: axes)
    }
}
