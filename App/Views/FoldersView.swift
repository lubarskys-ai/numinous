import SwiftUI
import NuminousCore
import UniformTypeIdentifiers

/// A node in the folder tree: either a folder (with children) or a note (leaf).
final class FolderNode: Identifiable {
    let id: String
    let path: String?      // folder path (nil for note nodes); "" renders as "Unfiled"
    let note: Note?
    var subfolders: [FolderNode] = []
    var noteNodes: [FolderNode] = []

    init(folder path: String) { self.id = "f:" + path; self.path = path; self.note = nil }
    init(note: Note) { self.id = "n:" + note.id.uuidString; self.path = nil; self.note = note }

    var children: [FolderNode]? { note != nil ? nil : (subfolders + noteNodes) }

    var displayName: String {
        if let path {
            if path.isEmpty { return "Unfiled" }
            if let slash = path.lastIndex(of: "/") { return String(path[path.index(after: slash)...]) }
            return path
        }
        return note?.displayName ?? ""
    }
}

/// The Folders tab: the single home for all notes, as a collapsible tree with
/// subfolders. Each folder maps to an axis and can carry a default intensity.
struct FoldersView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false
    @State private var compose: ComposeRequest?
    @State private var folderSheet: FolderSheet?
    @State private var renameFolderPath: String?
    @State private var folderNameDraft = ""
    @State private var deleteFolderPath: String?
    @State private var renameNoteID: UUID?
    @State private var noteNameDraft = ""
    @State private var deleteNoteID: UUID?
    @State private var dropHighlight: String?
    @State private var showReadwise = false
    @State private var importMessage: String?
    @State private var path = NavigationPath()
    @State private var searchText = ""
    @State private var selection = FolderSelection()
    @State private var showBulkMove = false
    @State private var bulkDeleteConfirm = false
    @State private var debouncedQuery = ""
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var showFixNames = false
    @AppStorage("foldersCabinetMode") private var cabinetMode = true

    @ViewBuilder private var folderContent: some View {
        if !searchText.isEmpty {
            searchResults(debouncedQuery)
        } else if cabinetMode {
            CabinetView(onOpenNote: { path.append($0) },
                        onEditAxes: { folderSheet = .axes($0) },
                        onBrowseFolder: { path.append($0) },
                        onDeleteFolder: { deleteFolderPath = $0 },
                        onRenameFolder: { renameFolderPath = $0; folderNameDraft = $0 },
                        onMergeFolder: { folderSheet = .merge($0) },
                        onMoveNote: { folderSheet = .moveNote($0) },
                        selection: $selection)
        } else {
            List {
                OutlineGroup(buildTree(), children: \.children) { node in row(node) }
                    .listRowSeparatorTint(Color.secondary.opacity(0.12))
            }
            .listStyle(.insetGrouped)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            folderContent
            .safeAreaInset(edge: .bottom) { bulkActionBar }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: "Search notes & links")
            .autocorrectionDisabled()
            // Debounce: searching 5,000+ notes is too slow to run on every keystroke. Wait
            // for a brief pause in typing, so the keyboard stays smooth. `.task(id:)`
            // cancels the pending run each time the text changes.
            .task(id: searchText) {
                if searchText.isEmpty { debouncedQuery = ""; return }
                try? await Task.sleep(nanoseconds: 220_000_000)
                if !Task.isCancelled { debouncedQuery = searchText }
            }
            .navigationTitle("Folders")
            .navigationDestination(for: UUID.self) { id in NoteDetailView(noteID: id) }
            .navigationDestination(for: String.self) { category in FolderBrowserView(category: category) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Customize axes")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation(.easeInOut) { cabinetMode.toggle() }
                    } label: {
                        Image(systemName: cabinetMode ? "list.bullet" : "archivebox")
                    }
                    .accessibilityLabel(cabinetMode ? "Show list" : "Show cabinet")
                }
                if cabinetMode && searchText.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(selection.active ? "Done" : "Select") {
                            withAnimation(.easeInOut) {
                                selection.active.toggle()
                                if !selection.active { selection.clear() }
                            }
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu { addMenuContent } label: { Image(systemName: "plus") }
                }
            }
            // One sheet driven by an enum — stacking several `.sheet(item:)` on one view
            // let some (like Merge) silently fail to present.
            .sheet(item: $folderSheet) { sheet in
                switch sheet {
                case .axes(let p):
                    FolderAxisPicker(path: p)
                case .merge(let p):
                    MergeFolderPicker(source: p) { destination in
                        model.renameFolder(from: p, to: destination)
                        folderSheet = nil
                    }
                case .moveNote(let id):
                    MoveNotePicker(noteID: id) { destination in
                        model.moveNote(id, toFolder: destination)
                        folderSheet = nil
                    }
                }
            }
            .alert("Rename or move folder", isPresented: Binding(get: { renameFolderPath != nil }, set: { if !$0 { renameFolderPath = nil } })) {
                TextField("folder path", text: $folderNameDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Save") { if let p = renameFolderPath { model.renameFolder(from: p, to: folderNameDraft) } }
            } message: {
                Text("Moves every note in this folder. All links update automatically.")
            }
            .confirmationDialog("Delete this folder?", isPresented: Binding(get: { deleteFolderPath != nil }, set: { if !$0 { deleteFolderPath = nil } }), presenting: deleteFolderPath) { folder in
                Button("Delete “\(folder)” and its notes", role: .destructive) { model.deleteFolder(folder) }
                Button("Cancel", role: .cancel) {}
            } message: { folder in
                let n = model.notes.filter { $0.folderName.lowercased() == folder.lowercased() || $0.folderName.lowercased().hasPrefix(folder.lowercased() + "/") }.count
                Text("Permanently removes this folder and \(n) note\(n == 1 ? "" : "s") inside it.")
            }
            .fullScreenCover(item: $compose) { req in ComposeView(prefillTitle: req.prefillTitle, diary: req.diary, onSaved: { path.append($0) }) }
            .sheet(isPresented: $showReadwise) { ReadwiseConnectView() }
            .sheet(isPresented: $showSettings) { AxisSettingsView() }
            .alert("Import", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(importMessage ?? "") }
            .confirmationDialog("Fix imported note names?", isPresented: $showFixNames, titleVisibility: .visible) {
                let n = model.obsidianArtifactCount()
                Button("Fix \(n) name\(n == 1 ? "" : "s")") {
                    let fixed = model.cleanupObsidianTitles()
                    importMessage = "Cleaned \(fixed) note name\(fixed == 1 ? "" : "s")."
                }
                .disabled(n == 0)
                Button("Cancel", role: .cancel) {}
            } message: {
                let n = model.obsidianArtifactCount()
                Text(n == 0 ? "No mangled names found."
                            : "\(n) note\(n == 1 ? "" : "s") have Obsidian import junk in the name (a “.md” or a “#…” block reference, e.g. “Hamnet.md#tr-…”). This strips it back to the clean name (e.g. “Hamnet”); links follow and duplicates merge.")
            }
            .alert("New folder", isPresented: $showNewFolder) {
                TextField("Folder name", text: $newFolderName)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Create") { model.createFolder(newFolderName) }
            } message: {
                Text("Create an empty folder now — you can move notes into it and map it to an axis afterward. Use “parent/child” for a subfolder.")
            }
            .alert("Rename note", isPresented: Binding(get: { renameNoteID != nil }, set: { if !$0 { renameNoteID = nil } })) {
                TextField("Name", text: $noteNameDraft)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    if let id = renameNoteID, let n = model.note(id: id) {
                        let leaf = noteNameDraft.trimmingCharacters(in: .whitespaces)
                        if !leaf.isEmpty {
                            model.renameNote(id, to: n.folderName.isEmpty ? leaf : n.folderName + "/" + leaf)
                        }
                    }
                }
            }
            .confirmationDialog("Delete this note?",
                                isPresented: Binding(get: { deleteNoteID != nil }, set: { if !$0 { deleteNoteID = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let id = deleteNoteID, let n = model.note(id: id) { model.delete([n]) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This removes the note. It can't be undone.") }
            .sheet(isPresented: $showBulkMove) {
                BulkFolderPicker(excluding: selection.folders) { destination in
                    model.moveNotes(Array(selection.notes), toFolder: destination)
                    for f in selection.folders where f.lowercased() != destination.lowercased() {
                        _ = model.moveFolder(f, into: destination)
                    }
                    showBulkMove = false
                    withAnimation { selection.clear() }
                }
            }
            .confirmationDialog(bulkDeleteTitle,
                                isPresented: $bulkDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    model.deleteFolders(Array(selection.folders))
                    model.delete(model.notes.filter { selection.notes.contains($0.id) })
                    withAnimation { selection.clear() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure? This permanently removes the selected item\(selection.count == 1 ? "" : "s")\(selection.folders.isEmpty ? "" : " (and every note inside a selected folder)"). This can't be undone.")
            }
        }
    }

    /// Are-you-sure title with the exact counts being deleted.
    private var bulkDeleteTitle: String {
        let n = selection.notes.count, f = selection.folders.count
        var parts: [String] = []
        if n > 0 { parts.append("\(n) note\(n == 1 ? "" : "s")") }
        if f > 0 { parts.append("\(f) folder\(f == 1 ? "" : "s")") }
        return "Delete " + (parts.joined(separator: " and ")) + "?"
    }

    /// One button in the multi-select action bar.
    @ViewBuilder
    private func bulkActionButton(_ title: String, _ icon: String, enabled: Bool,
                                  destructive: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.body)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(destructive ? Color.red : Color.accentColor)
            .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// Rename the single selected item (a note or a folder) via the existing dialogs.
    private func startBulkRename() {
        guard selection.count == 1 else { return }
        if let id = selection.notes.first {
            noteNameDraft = model.note(id: id)?.displayName ?? ""
            renameNoteID = id
        } else if let folder = selection.folders.first {
            folderNameDraft = folder
            renameFolderPath = folder
        }
    }

    // MARK: - Search

    @ViewBuilder
    private func searchResults(_ query: String) -> some View {
        let results = matchingNotes(query)
        if results.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                Text("No matches for \u{201C}\(query)\u{201D}").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(results) { note in
                    Button { path.append(note.id) } label: { searchRow(note) }
                        .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
        }
    }

    private func searchRow(_ note: Note) -> some View {
        let color = model.axis(for: note)?.color ?? .secondary
        return HStack(spacing: 12) {
            Image(systemName: note.isStub ? "circle.dashed" : "doc.text.fill")
                .foregroundStyle(note.isStub ? Color.secondary.opacity(0.6) : color.opacity(0.85))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(note.displayName).font(.system(.body, design: .rounded).weight(.medium))
                Text(note.folderName.isEmpty ? "unfiled" : note.folderName)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    /// Any note whose title, folder path, body, or `[[links]]` match — so you can
    /// jump straight to a note (or find everything that links to it).
    private func matchingNotes(_ query: String) -> [Note] {
        let _t0 = CFAbsoluteTimeGetCurrent()
        defer { let ms = (CFAbsoluteTimeGetCurrent() - _t0) * 1000
            if ms > 20 { print("⏱️[perf] search \(Int(ms))ms over \(model.notes.count) notes") } }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        // Match case-insensitively WITHOUT allocating a lowercased copy of every note's
        // body (the old `.lowercased().contains` did, ×5,000 per keystroke), and drop the
        // regex link parse — a note's [[links]] are already in its body text. Rank in the
        // same pass so the sort doesn't recompute string matches.
        func has(_ s: String) -> Bool { s.range(of: q, options: .caseInsensitive) != nil }
        var scored: [(note: Note, rank: Int)] = []
        for n in model.notes {
            if n.displayName.range(of: q, options: [.caseInsensitive, .anchored]) != nil { scored.append((n, 0)) }
            else if has(n.displayName) { scored.append((n, 1)) }
            else if has(n.folderName) { scored.append((n, 2)) }
            else if has(n.body) { scored.append((n, 3)) }
        }
        return scored.sorted { a, b in
            a.rank != b.rank ? a.rank < b.rank
                : a.note.displayName.localizedCaseInsensitiveCompare(b.note.displayName) == .orderedAscending
        }.map(\.note)
    }

    /// The "+" menu. Extracted to keep the main body under the type-checker's limit.
    @ViewBuilder private var addMenuContent: some View {
        Button { compose = ComposeRequest() } label: { Label("New note", systemImage: "square.and.pencil") }
        Button { newFolderName = ""; showNewFolder = true } label: { Label("New folder", systemImage: "folder.badge.plus") }
        Button { compose = ComposeRequest(diary: true) } label: { Label("Add to today's diary", systemImage: "calendar.badge.plus") }
        Divider()
        Button { importContacts() } label: { Label("Sync contacts", systemImage: "person.crop.circle.badge.plus") }
        if model.isReadwiseConnected {
            Button { Task { importMessage = await model.syncReadwiseNow() } } label: { Label("Sync Readwise now", systemImage: "arrow.triangle.2.circlepath") }
        }
        Button { showReadwise = true } label: { Label(model.isReadwiseConnected ? "Readwise settings" : "Import from Readwise", systemImage: "books.vertical") }
        Button {
            Task {
                let n = await model.backfillBookGenres()
                importMessage = n == 0 ? "No new genres found (books may already be tagged, or none matched)."
                                       : "Tagged \(n) book\(n == 1 ? "" : "s") with a genre → books/genre/…"
            }
        } label: { Label("Look up book genres", systemImage: "text.book.closed") }
        Button { showFixNames = true } label: { Label("Fix imported note names", systemImage: "character.cursor.ibeam") }
        #if DEBUG
        Button { let (a, u) = model.importReadwise(ReadwiseService.sampleBooks); importMessage = "Readwise (sample): \(a) new, \(u) updated." } label: { Label("Readwise sample (debug)", systemImage: "ladybug") }
        #endif
    }

    /// The multi-select action bar pinned to the bottom in cabinet mode. Extracted from
    /// the main body to keep it under the SwiftUI type-checker's complexity limit.
    @ViewBuilder private var bulkActionBar: some View {
        if selection.active && cabinetMode && searchText.isEmpty {
            HStack(spacing: 0) {
                bulkActionButton("Move", "folder", enabled: !selection.isEmpty) { showBulkMove = true }
                bulkActionButton("Rename", "pencil", enabled: selection.count == 1) { startBulkRename() }
                bulkActionButton("Delete", "trash", enabled: !selection.isEmpty, destructive: true) { bulkDeleteConfirm = true }
                Spacer().frame(width: 96)   // clear of the floating companion in the corner
            }
            .padding(.leading).padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .topLeading) {
                Text(selection.isEmpty ? "Select notes or folders" : "\(selection.count) selected")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.leading).padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private func row(_ node: FolderNode) -> some View {
        if let note = node.note {
            NavigationLink(value: note.id) { NoteRow(note: note) }
                .onDrag { NSItemProvider(object: note.id.uuidString as NSString) }
                .contextMenu {
                    noteActionButtons(
                        open: nil,
                        rename: { noteNameDraft = note.displayName; renameNoteID = note.id },
                        move: { folderSheet = .moveNote(note.id) },
                        delete: { deleteNoteID = note.id }
                    )
                }
        } else {
            folderRow(node)
        }
    }

    /// Move any dropped notes into `folder` (classic NSItemProvider API — reliable on a
    /// physical device). Returns whether the drop was accepted.
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

    private func folderRow(_ node: FolderNode) -> some View {
        let path = node.path ?? ""
        let folder = path.isEmpty ? nil : model.folder(named: path)
        let axis = model.axis(id: folder?.axisID)
        let color = axis?.color ?? Color.secondary
        return HStack(spacing: 12) {
            AxisIconTile(symbol: folderSymbol(node.displayName, folder?.category), color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.displayName)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                if let folder {
                    Text(subtitle(folder)).font(.caption).foregroundStyle(.secondary)
                } else if !path.isEmpty, model.notes.contains(where: { $0.folderName == path }) {
                    Text("needs a category").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
            if node.noteNodes.count > 0 {
                Text("\(node.noteNodes.count)")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            if !path.isEmpty { folderMenu(path, growthAxes: folder?.growthAxes ?? [], intensity: folder?.defaultIntensity) }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            if !path.isEmpty {
                folderMenuContent(path, growthAxes: folder?.growthAxes ?? [], intensity: folder?.defaultIntensity)
            }
        }
        .listRowBackground(dropHighlight == path && !path.isEmpty ? Color.accentColor.opacity(0.15) : nil)
        .onDrop(of: [.text], isTargeted: Binding(
            get: { dropHighlight == path && !path.isEmpty },
            set: { if !path.isEmpty { dropHighlight = $0 ? path : (dropHighlight == path ? nil : dropHighlight) } }
        )) { providers in
            path.isEmpty ? false : handleNoteDrop(providers, into: path)
        }
    }

    private func subtitle(_ folder: Folder) -> String {
        var parts = [folder.category]
        let axisNames = folder.growthAxes.compactMap { model.axis(id: $0)?.name }
        if !axisNames.isEmpty { parts.append(axisNames.joined(separator: " + ")) }
        if let intensity = folder.defaultIntensity { parts.append("⚡\(intensity)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func folderMenuContent(_ path: String, growthAxes: [String], intensity: Int?) -> some View {
        Button { renameFolderPath = path; folderNameDraft = path } label: {
            Label("Rename or move folder…", systemImage: "pencil")
        }
        Button { folderSheet = .merge(path) } label: {
            Label("Merge into…", systemImage: "arrow.triangle.merge")
        }
        Button { folderSheet = .axes(path) } label: {
            Label(growthAxes.isEmpty ? "Grows…" : "Grows: \(growthAxes.count) axes", systemImage: "circle.hexagongrid")
        }
        Menu("Default intensity") {
            Button { model.setFolderIntensity(nil, forFolder: path) } label: {
                if intensity == nil { Label("Neutral (3)", systemImage: "checkmark") } else { Text("Neutral (3)") }
            }
            ForEach(1...5, id: \.self) { level in
                Button { model.setFolderIntensity(level, forFolder: path) } label: {
                    if intensity == level { Label("⚡ \(level)", systemImage: "checkmark") } else { Text("⚡ \(level)") }
                }
            }
        }
        Divider()
        Button(role: .destructive) { deleteFolderPath = path } label: {
            Label("Delete folder…", systemImage: "trash")
        }
    }

    private func folderMenu(_ path: String, growthAxes: [String], intensity: Int?) -> some View {
        Menu { folderMenuContent(path, growthAxes: growthAxes, intensity: intensity) } label: {
            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
        }
    }

    // MARK: - Tree

    private func buildTree() -> [FolderNode] {
        let _t0 = CFAbsoluteTimeGetCurrent()
        defer { let ms = (CFAbsoluteTimeGetCurrent() - _t0) * 1000
            if ms > 20 { print("⏱️[perf] buildTree \(Int(ms))ms notes=\(model.notes.count)") } }
        var notesByPath: [String: [Note]] = [:]
        for group in model.groupedByFolder { notesByPath[group.id] = group.notes }

        var prefixes = Set<String>()
        func addPrefixes(_ p: String) {
            guard !p.isEmpty else { return }
            var acc = ""
            for segment in p.split(separator: "/").map(String.init) {
                acc = acc.isEmpty ? segment : acc + "/" + segment
                prefixes.insert(acc)
            }
        }
        for key in notesByPath.keys { addPrefixes(key) }
        for folder in model.folders { addPrefixes(folder.name) }

        var nodes: [String: FolderNode] = [:]
        for p in prefixes { nodes[p] = FolderNode(folder: p) }
        var roots: [FolderNode] = []
        for p in prefixes.sorted(by: alpha) {
            let node = nodes[p]!
            if let slash = p.lastIndex(of: "/") {
                nodes[String(p[..<slash])]?.subfolders.append(node)
            } else {
                roots.append(node)
            }
        }
        for (path, ns) in notesByPath where !path.isEmpty {
            guard let node = nodes[path] else { continue }
            for note in ns.sorted(by: chronological) { node.noteNodes.append(FolderNode(note: note)) }
        }
        if let unfiled = notesByPath[""], !unfiled.isEmpty {
            let notesNode: FolderNode
            if let existing = nodes["notes"] { notesNode = existing }
            else { let created = FolderNode(folder: "notes"); nodes["notes"] = created; roots.append(created); notesNode = created }
            let unfiledNode = FolderNode(folder: "")
            for note in unfiled.sorted(by: chronological) { unfiledNode.noteNodes.append(FolderNode(note: note)) }
            notesNode.subfolders.append(unfiledNode)
        }
        return roots.sorted { alpha($0.path ?? "", $1.path ?? "") }
    }

    private func alpha(_ a: String, _ b: String) -> Bool {
        a.localizedCaseInsensitiveCompare(b) == .orderedAscending
    }

    /// Files within a folder go newest-first by date; notes sharing a date (e.g. a
    /// batch of imported contacts) fall back to alphabetical, so those stay A–Z
    /// while dated entries like diary notes read in time order.
    private func chronological(_ a: Note, _ b: Note) -> Bool {
        a.date != b.date ? a.date > b.date : alpha(a.displayName, b.displayName)
    }

    private func importContacts() {
        Task {
            do {
                let contacts = try await ContactsImporter.fetchContacts()
                let (added, updated) = model.importContacts(contacts)
                importMessage = contacts.isEmpty ? "No contacts found on this device."
                    : "Synced \(added) new, updated \(updated) into your Contacts folder."
            } catch ContactsImporter.ImportError.accessDenied {
                importMessage = "Contacts access was declined. You can enable it in Settings → Numinous."
            } catch {
                importMessage = "Couldn't import contacts: \(error.localizedDescription)"
            }
        }
    }
}

/// Wrapper so a folder path can drive a `.sheet(item:)`.
struct FolderRef: Identifiable { let id: String }

/// The one folder sheet FoldersView presents, tagged by kind — so a single
/// `.sheet(item:)` covers both (stacking two silently broke Merge).
enum FolderSheet: Identifiable {
    case axes(String)
    case merge(String)
    case moveNote(UUID)
    var id: String {
        switch self {
        case .axes(let p): return "axes:" + p
        case .merge(let p): return "merge:" + p
        case .moveNote(let id): return "move:" + id.uuidString
        }
    }
}

/// Pick a destination folder to merge a source folder into. Merging moves every note
/// (and subfolder) out of the source and into the destination; notes that collide by
/// name are combined, and all `[[links]]` are rewritten — this is just a rename onto an
/// existing path. You can't merge a folder into itself or one of its own subfolders.
struct MergeFolderPicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let source: String
    let onPick: (String) -> Void
    @State private var search = ""

    /// Every folder path that exists (from folders and note paths, with all prefixes),
    /// minus the source and its own subtree.
    private var destinations: [String] {
        var paths = Set<String>()
        func addPrefixes(_ p: String) {
            guard !p.isEmpty else { return }
            var acc = ""
            for seg in p.split(separator: "/").map(String.init) {
                acc = acc.isEmpty ? seg : acc + "/" + seg
                paths.insert(acc)
            }
        }
        for n in model.notes { addPrefixes(n.folderName) }
        for f in model.folders { addPrefixes(f.name) }
        // Exclude the EXACT source (case-sensitive) and its own subtree — so a case-variant
        // like "medical" is still offered as a destination for "Medical".
        return paths
            .filter { $0 != source && !$0.lowercased().hasPrefix(source.lowercased() + "/") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var filtered: [String] {
        let q = search.lowercased().trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? destinations : destinations.filter { $0.lowercased().contains(q) }
    }

    private func count(_ path: String) -> Int {
        let p = path.lowercased()
        return model.notes.filter { let fn = $0.folderName.lowercased(); return fn == p || fn.hasPrefix(p + "/") }.count
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(filtered, id: \.self) { dest in
                        Button { onPick(dest) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(model.axis(id: model.folder(named: dest)?.axisID)?.color ?? .secondary)
                                Text(dest).foregroundStyle(.primary)
                                Spacer()
                                Text("\(count(dest))").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                } header: {
                    Text("Merge “\(source)” into")
                } footer: {
                    Text("Moves every note in “\(source)” into the folder you pick. Notes with the same name are combined and all links update automatically.")
                }
            }
            .searchable(text: $search, prompt: "Find a folder")
            .navigationTitle("Merge folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Pick a destination folder to move ONE note into — a reliable, no-drag way to refile a
/// note (tap the note's ⋯ → "Move to folder…"). Lists every existing folder except the one
/// it's already in; typing a name that doesn't exist offers to create it.
struct MoveNotePicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let noteID: UUID
    let onPick: (String) -> Void
    @State private var search = ""

    private var noteName: String { model.note(id: noteID)?.displayName ?? "note" }
    private var currentFolder: String { model.note(id: noteID)?.folderName ?? "" }

    private var destinations: [String] {
        var paths = Set<String>()
        func addPrefixes(_ p: String) {
            guard !p.isEmpty else { return }
            var acc = ""
            for seg in p.split(separator: "/").map(String.init) {
                acc = acc.isEmpty ? seg : acc + "/" + seg
                paths.insert(acc)
            }
        }
        for n in model.notes { addPrefixes(n.folderName) }
        for f in model.folders { addPrefixes(f.name) }
        let cur = currentFolder.lowercased()
        return paths
            .filter { $0.lowercased() != cur }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var filtered: [String] {
        let q = search.lowercased().trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? destinations : destinations.filter { $0.lowercased().contains(q) }
    }

    private func count(_ path: String) -> Int {
        let p = path.lowercased()
        return model.notes.filter { let fn = $0.folderName.lowercased(); return fn == p || fn.hasPrefix(p + "/") }.count
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(filtered, id: \.self) { dest in
                        Button { onPick(dest) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(model.axis(id: model.folder(named: dest)?.axisID)?.color ?? .secondary)
                                Text(dest).foregroundStyle(.primary)
                                Spacer()
                                Text("\(count(dest))").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    // Let a typed name that isn't an existing folder create a new one.
                    let q = search.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
                    if !q.isEmpty, !destinations.contains(where: { $0.caseInsensitiveCompare(q) == .orderedSame }) {
                        Button { onPick(q) } label: {
                            Label("Move to new folder “\(q)”", systemImage: "folder.badge.plus")
                        }
                    }
                } header: {
                    Text("Move “\(noteName)” to")
                } footer: {
                    Text("Refiles this note. All links to it update automatically.")
                }
            }
            .searchable(text: $search, prompt: "Find or name a folder")
            .navigationTitle("Move note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Pick a destination folder to move a MULTI-SELECTION into (notes and/or whole folders).
/// Lists every folder except the ones being moved; typing a new name creates it.
struct BulkFolderPicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let excluding: Set<String>          // folders being moved — can't move into themselves
    let onPick: (String) -> Void
    @State private var search = ""

    private var destinations: [String] {
        var paths = Set<String>()
        func addPrefixes(_ p: String) {
            guard !p.isEmpty else { return }
            var acc = ""
            for seg in p.split(separator: "/").map(String.init) {
                acc = acc.isEmpty ? seg : acc + "/" + seg
                paths.insert(acc)
            }
        }
        for n in model.notes { addPrefixes(n.folderName) }
        for f in model.folders { addPrefixes(f.name) }
        let ex = Set(excluding.map { $0.lowercased() })
        // Exclude the moved folders themselves and anything nested under them.
        return paths
            .filter { p in !ex.contains(where: { p.lowercased() == $0 || p.lowercased().hasPrefix($0 + "/") }) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var filtered: [String] {
        let q = search.lowercased().trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? destinations : destinations.filter { $0.lowercased().contains(q) }
    }

    private func count(_ path: String) -> Int {
        let p = path.lowercased()
        return model.notes.filter { let fn = $0.folderName.lowercased(); return fn == p || fn.hasPrefix(p + "/") }.count
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(filtered, id: \.self) { dest in
                        Button { onPick(dest) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(model.axis(id: model.folder(named: dest)?.axisID)?.color ?? .secondary)
                                Text(dest).foregroundStyle(.primary)
                                Spacer()
                                Text("\(count(dest))").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    let q = search.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
                    if !q.isEmpty, !destinations.contains(where: { $0.caseInsensitiveCompare(q) == .orderedSame }) {
                        Button { onPick(q) } label: {
                            Label("Move to new folder “\(q)”", systemImage: "folder.badge.plus")
                        }
                    }
                } header: {
                    Text("Move selection to")
                } footer: {
                    Text("Refiles the selected notes and folders. All links update automatically.")
                }
            }
            .searchable(text: $search, prompt: "Find or name a folder")
            .navigationTitle("Move")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Multi-select axis picker for a folder — tap several axes, they stay checked,
/// then Done. (A `Menu` can't do this: it dismisses on every tap.)
struct FolderAxisPicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let path: String

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.axes) { axis in
                        let on = (model.folder(named: path)?.growthAxes ?? []).contains(axis.id)
                        Button { model.toggleFolderAxis(axis.id, forFolder: path) } label: {
                            HStack(spacing: 12) {
                                Circle().fill(axis.color).frame(width: 12, height: 12)
                                Text(axis.name).foregroundStyle(.primary)
                                Spacer()
                                if on { Image(systemName: "checkmark").foregroundStyle(.blue).fontWeight(.semibold) }
                            }
                        }
                    }
                } header: {
                    Text("Grows")
                } footer: {
                    Text("Pick one or more parts of life this folder grows. Each note's growth is split evenly among them.")
                }
            }
            .navigationTitle(path)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// A soft, tinted rounded-square icon that gives each folder/note a bit of warmth
/// and identity instead of a bare colored dot.
struct AxisIconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(color.opacity(0.15))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(color)
            )
    }
}

/// A friendly SF Symbol for a folder, guessed from its name/category — so the
/// tree reads at a glance instead of looking like a database table.
func folderSymbol(_ name: String, _ category: String?) -> String {
    let hay = (name + " " + (category ?? "")).lowercased()
    func has(_ keys: String...) -> Bool { keys.contains { hay.contains($0) } }
    switch true {
    case has("people", "contact", "friend", "relationship"): return "person.2.fill"
    case has("book", "read", "cognition", "ideas"):          return "book.fill"
    case has("workout", "sport", "fitness", "gym", "exercise"): return "figure.run"
    case has("health"):                                       return "heart.fill"
    case has("meal", "nutrition", "food", "gut"):             return "fork.knife"
    case has("calendar", "event"):                            return "calendar"
    case has("diary", "journal"):                             return "book.closed.fill"
    case has("travel", "trip"):                               return "airplane"
    case has("music", "song"):                                return "music.note"
    case has("work", "project"):                              return "briefcase.fill"
    case has("note"):                                         return "note.text"
    default:                                                  return "folder.fill"
    }
}

/// Rename and recolor the axes (purely cosmetic — scoring uses axis ids).
struct AxisSettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var backupURL: URL?
    @State private var showRestorePicker = false
    @State private var pendingRestore: URL?
    @State private var restoreMessage: String?
    @State private var showAutoBackupPicker = false
    @State private var showObsidianPicker = false
    @State private var importMessage: String?
    @State private var importing = false
    @State private var showHomePrompt = false
    @State private var homeDraft = ""
    @StateObject private var locator = LocationService()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(model.axes) { axis in AxisEditorRow(axis: axis) }
                } header: {
                    Text("Axes")
                } footer: {
                    Text("Rename or recolor the parts of life your avatar grows along. Your notes and growth stay exactly as they are.")
                }

                Section {
                    HStack {
                        Image(systemName: "house.fill").foregroundStyle(.secondary)
                        Text(model.homeLocation?.name ?? "Not set")
                            .foregroundStyle(model.homeLocation == nil ? .secondary : .primary)
                    }
                    Button {
                        Task { if let p = await locator.currentPlaceStructured() { model.setHome(p) } }
                    } label: { Label("Use current location", systemImage: "location.fill") }
                    Button { homeDraft = model.homeLocation?.name ?? ""; showHomePrompt = true } label: {
                        Label("Enter home city", systemImage: "mappin")
                    }
                    if model.homeLocation != nil {
                        Button(role: .destructive) { model.setHome(nil) } label: {
                            Label("Clear home", systemImage: "xmark")
                        }
                    }
                } header: {
                    Text("Home")
                } footer: {
                    Text("Where you live. Travel notes grow your Meaning axis more the farther they are from home and the longer the trip.")
                }

                Section {
                    if model.isAutoBackupOn {
                        Label("Auto‑backup: on\(model.autoBackupFolderName.map { " → \($0)" } ?? "")", systemImage: "checkmark.icloud")
                            .foregroundStyle(.green)
                        Button(role: .destructive) { model.disableAutoBackup() } label: {
                            Label("Turn off auto‑backup", systemImage: "xmark")
                        }
                    } else {
                        Button { showAutoBackupPicker = true } label: {
                            Label("Turn on auto‑backup…", systemImage: "clock.arrow.circlepath")
                        }
                    }
                    if let backupURL {
                        ShareLink(item: backupURL) { Label("Export a backup now", systemImage: "square.and.arrow.up") }
                    }
                    Button { showRestorePicker = true } label: {
                        Label("Restore from a backup", systemImage: "arrow.down.doc")
                    }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Auto‑backup saves a copy of your data to a folder you pick (choose one in iCloud Drive) on every change — so it survives even if the app is deleted. You can also export once, or restore to replace everything currently in Numinous.")
                }

                Section {
                    Button { showObsidianPicker = true } label: {
                        Label("Import from Obsidian…", systemImage: "square.and.arrow.down.on.square")
                    }
                    .disabled(importing)
                    if importing {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Importing your vault… (large or iCloud vaults can take a minute)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Import")
                } footer: {
                    Text("Pick your Obsidian vault folder (put a copy in iCloud Drive first). Every markdown file becomes a note, subfolders become folders, and [[wikilinks]] resolve as usual. Notes you've already written in Numinous are never overwritten — only empty ones are filled. Recognized folders (People, Books, Workouts…) are mapped to an axis automatically; map any others by hand. Imported notes start dormant — they grant no growth until you open one and add to it.")
                }

                Section {
                    let learned = model.linkLearning.aliases.count + model.linkLearning.skips.count
                    if learned == 0 {
                        Text("Find links will learn from your Add / Skip / Edit-folder choices as you review.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("Learned \(model.linkLearning.aliases.count) auto-link\(model.linkLearning.aliases.count == 1 ? "" : "s") and \(model.linkLearning.skips.count) skip\(model.linkLearning.skips.count == 1 ? "" : "s").", systemImage: "sparkles")
                            .font(.callout)
                        Button(role: .destructive) { model.resetLinkLearning() } label: {
                            Label("Forget what Find links learned", systemImage: "arrow.counterclockwise")
                        }
                    }
                } header: {
                    Text("Find links learning")
                } footer: {
                    Text("Surfaces you confirm auto-link next time (even offline); names you skip aren't offered again; folders you choose become the default for that name.")
                }

                Section {
                    Link(destination: URL(string: "https://sketchfab.com/3d-models/sculpting-a-human-body-a24baf3514834527972bffdad882258e")!) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("3D body: “sculpting a human body”")
                            Text("by Animation-class-k · CC-BY 4.0 · Sketchfab")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Credits")
                }
            }
            .navigationTitle("Customize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { backupURL = model.exportBackup() }
            .alert("Home", isPresented: $showHomePrompt) {
                TextField("City, State", text: $homeDraft)
                Button("Cancel", role: .cancel) {}
                Button("Set") {
                    let name = homeDraft.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    Task {
                        if let c = await LocationService.coordinate(for: name) {
                            model.setHome(Place(name: name, latitude: c.latitude, longitude: c.longitude))
                        } else {
                            model.setHome(Place(name: name))   // keep the name even if it won't geocode
                        }
                    }
                }
            } message: { Text("Where do you live? Used to measure how far your travels take you.") }
            .fileImporter(isPresented: $showRestorePicker, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result { pendingRestore = url }
            }
            .fileImporter(isPresented: $showAutoBackupPicker, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { _ = model.enableAutoBackup(folder: url) }
            }
            .fileImporter(isPresented: $showObsidianPicker, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    importing = true
                    Task {
                        let r = await model.importObsidianVault(at: url)
                        importing = false
                        if r.files == 0 {
                            importMessage = "No markdown files found in that folder."
                        } else {
                            importMessage = "Imported \(r.files) note\(r.files == 1 ? "" : "s") — \(r.added) new, \(r.updated) updated. Map the new folders to an axis to grow along them."
                        }
                    }
                }
            }
            .alert("Obsidian import", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(importMessage ?? "") }
            .alert("Restore backup?", isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })) {
                Button("Cancel", role: .cancel) { pendingRestore = nil }
                Button("Replace everything", role: .destructive) {
                    if let url = pendingRestore {
                        restoreMessage = model.importBackup(from: url) ? "Backup restored." : "Couldn't read that backup file."
                    }
                    pendingRestore = nil
                }
            } message: { Text("This replaces all notes, folders, and growth currently in Numinous with the backup's contents.") }
            .alert("Restore", isPresented: Binding(get: { restoreMessage != nil }, set: { if !$0 { restoreMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(restoreMessage ?? "") }
        }
    }
}

private struct AxisEditorRow: View {
    @EnvironmentObject var model: AppModel
    let axis: Axis
    @State private var name = ""

    var body: some View {
        HStack(spacing: 12) {
            ColorPicker("", selection: Binding(
                get: { model.axis(id: axis.id)?.color ?? axis.color },
                set: { if let hex = $0.toHex() { model.setAxisColor(axis.id, hex: hex) } }
            ))
            .labelsHidden()
            TextField("Name", text: $name).textInputAutocapitalization(.words)
        }
        .onAppear { name = axis.name }
        .onChange(of: name) { newValue in
            let t = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, t != model.axis(id: axis.id)?.name { model.renameAxis(axis.id, name: t) }
        }
    }
}
