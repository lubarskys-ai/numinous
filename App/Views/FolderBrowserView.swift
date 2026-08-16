import SwiftUI
import UniformTypeIdentifiers
import NuminousCore

/// Hierarchical browser for a folder: its immediate **subfolders** first (tap to drill
/// in), then the **notes** filed directly here. Search spans the whole subtree, flat and
/// A–Z, so a huge folder (thousands of contacts) still stays fast and easy to parse.
struct FolderBrowserView: View {
    @EnvironmentObject var model: AppModel
    let category: String            // full folder path, e.g. "health" or "health/workouts"
    @State private var search = ""
    @State private var dropHighlight: String?
    @State private var moveID: UUID?
    @State private var renameID: UUID?
    @State private var renameDraft = ""
    @State private var deleteID: UUID?

    /// The long-press menu shared by every note row here (and matching the Folders grid).
    @ViewBuilder private func rowMenu(_ note: Note) -> some View {
        noteActionButtons(
            open: nil,
            rename: { renameDraft = note.displayName; renameID = note.id },
            move: { moveID = note.id },
            delete: { deleteID = note.id }
        )
    }

    /// Move any dropped note ids into `folder`. Returns true if at least one moved.
    private func handleNoteDrop(_ providers: [NSItemProvider], into folder: String) -> Bool {
        let usable = providers.filter { $0.canLoadObject(ofClass: NSString.self) }
        guard !usable.isEmpty else { return false }
        for p in usable {
            _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                guard let raw = obj as? String else { return }
                let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let id = UUID(uuidString: s) else { return }
                Task { @MainActor in model.moveNote(id, toFolder: folder) }
            }
        }
        return true
    }

    private var prefix: String { category.lowercased() + "/" }

    /// Immediate subfolder paths (one level deeper than `category`).
    private var subfolders: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for n in model.notes {
            let fn = n.folderName.lowercased()
            guard fn.hasPrefix(prefix) else { continue }
            let rest = n.folderName.dropFirst(category.count + 1)     // after "category/"
            guard let seg = rest.split(separator: "/").first.map(String.init), !seg.isEmpty else { continue }
            let path = category + "/" + seg
            if seen.insert(path.lowercased()).inserted { out.append(path) }
        }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Notes filed directly in this folder (not in a subfolder).
    private var directNotes: [Note] {
        model.notes.filter { $0.folderName.lowercased() == category.lowercased() }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Every note anywhere under this folder — used for search and counts.
    private var descendants: [Note] {
        model.notes.filter { let fn = $0.folderName.lowercased(); return fn == category.lowercased() || fn.hasPrefix(prefix) }
    }

    private func leaf(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
    private func count(under path: String) -> Int {
        let p = path.lowercased()
        return model.notes.filter { let fn = $0.folderName.lowercased(); return fn == p || fn.hasPrefix(p + "/") }.count
    }

    var body: some View {
        List {
            if !search.isEmpty {
                searchSections
            } else {
                if subfolders.isEmpty && directNotes.isEmpty {
                    Text("Nothing here yet.").foregroundStyle(.secondary)
                }
                if !subfolders.isEmpty {
                    Section("Folders") {
                        ForEach(subfolders, id: \.self) { path in
                            NavigationLink(value: path) {
                                HStack(spacing: 10) {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(model.axis(id: model.folder(named: path)?.axisID ?? "")?.color ?? .secondary)
                                    Text(leaf(path))
                                    Spacer()
                                    Text("\(count(under: path))").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .listRowBackground(dropHighlight == path ? Color.accentColor.opacity(0.15) : nil)
                            .onDrop(of: [.text], isTargeted: Binding(
                                get: { dropHighlight == path },
                                set: { dropHighlight = $0 ? path : (dropHighlight == path ? nil : dropHighlight) }
                            )) { providers in
                                handleNoteDrop(providers, into: path)
                            }
                        }
                    }
                }
                if !directNotes.isEmpty {
                    Section("Notes") {
                        ForEach(directNotes) { note in
                            NavigationLink(value: note.id) { NoteRow(note: note) }
                                .onDrag { NSItemProvider(object: note.id.uuidString as NSString) }
                                .contextMenu { rowMenu(note) }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, prompt: "Search \(leaf(category)) (\(descendants.count))")
        .navigationTitle(leaf(category))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(get: { moveID.map { NoteID(id: $0) } },
                             set: { moveID = $0?.id })) { box in
            MoveNotePicker(noteID: box.id) { destination in
                model.moveNote(box.id, toFolder: destination)
                moveID = nil
            }
        }
        .alert("Rename note", isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) {
            TextField("Name", text: $renameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let id = renameID, let n = model.note(id: id) {
                    let leaf = renameDraft.trimmingCharacters(in: .whitespaces)
                    if !leaf.isEmpty {
                        model.renameNote(id, to: n.folderName.isEmpty ? leaf : n.folderName + "/" + leaf)
                    }
                }
            }
        }
        .confirmationDialog("Delete this note?",
                            isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = deleteID, let n = model.note(id: id) { model.delete([n]) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the note. It can't be undone.")
        }
    }

    /// Flat A–Z search across the whole subtree.
    @ViewBuilder private var searchSections: some View {
        let q = search.lowercased().trimmingCharacters(in: .whitespaces)
        let hits = descendants.filter { $0.displayName.lowercased().contains(q) || $0.body.lowercased().contains(q) }
        let grouped = Dictionary(grouping: hits) { note -> String in
            let f = note.displayName.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "#"
            return f.range(of: "^[A-Z]$", options: .regularExpression) != nil ? f : "#"
        }
        if hits.isEmpty {
            Text("No matches in \(leaf(category)).").foregroundStyle(.secondary)
        } else {
            ForEach(grouped.keys.sorted(), id: \.self) { key in
                Section(key) {
                    ForEach(grouped[key]!.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }) { note in
                        NavigationLink(value: note.id) { NoteRow(note: note) }
                            .draggable(note.id.uuidString)
                            .contextMenu { rowMenu(note) }
                    }
                }
            }
        }
    }
}

/// Wraps a note id so it can drive a `.sheet(item:)`.
struct NoteID: Identifiable { let id: UUID }

/// The note action-menu items shared by every note card and row — so a long-press
/// (or the visible ⋯ button) offers the same Rename · Move · Delete everywhere.
/// `open` is optional: rows that already open on tap pass nil to omit it.
@ViewBuilder
func noteActionButtons(open: (() -> Void)?,
                       rename: @escaping () -> Void,
                       move: @escaping () -> Void,
                       delete: @escaping () -> Void) -> some View {
    if let open { Button { open() } label: { Label("Open", systemImage: "doc.text") } }
    Button { rename() } label: { Label("Rename…", systemImage: "pencil") }
    Button { move() } label: { Label("Move to folder…", systemImage: "folder") }
    Divider()
    Button(role: .destructive) { delete() } label: { Label("Delete", systemImage: "trash") }
}
