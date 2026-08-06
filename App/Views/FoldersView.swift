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
    @State private var axisPickerFolder: FolderRef?
    @State private var renameFolderPath: String?
    @State private var folderNameDraft = ""
    @State private var deleteFolderPath: String?
    @State private var showReadwise = false
    @State private var importMessage: String?
    @State private var path = NavigationPath()
    @State private var searchText = ""
    @AppStorage("foldersCabinetMode") private var cabinetMode = true

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !searchText.isEmpty {
                    searchResults(searchText)
                } else if cabinetMode {
                    CabinetView(onOpenNote: { path.append($0) },
                                onEditAxes: { axisPickerFolder = FolderRef(id: $0) },
                                onBrowseFolder: { path.append($0) },
                                onDeleteFolder: { deleteFolderPath = $0 })
                } else {
                    List {
                        OutlineGroup(buildTree(), children: \.children) { node in
                            row(node)
                        }
                        .listRowSeparatorTint(Color.secondary.opacity(0.12))
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: "Search notes & links")
            .autocorrectionDisabled()
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
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { compose = ComposeRequest() } label: { Label("New note", systemImage: "square.and.pencil") }
                        Button { compose = ComposeRequest(diary: true) } label: { Label("Add to today's diary", systemImage: "calendar.badge.plus") }
                        Divider()
                        Button { importContacts() } label: { Label("Sync contacts", systemImage: "person.crop.circle.badge.plus") }
                        if model.isReadwiseConnected {
                            Button { Task { importMessage = await model.syncReadwiseNow() } } label: { Label("Sync Readwise now", systemImage: "arrow.triangle.2.circlepath") }
                        }
                        Button { showReadwise = true } label: { Label(model.isReadwiseConnected ? "Readwise settings" : "Import from Readwise", systemImage: "books.vertical") }
                        #if DEBUG
                        Button { let (a, u) = model.importReadwise(ReadwiseService.sampleBooks); importMessage = "Readwise (sample): \(a) new, \(u) updated." } label: { Label("Readwise sample (debug)", systemImage: "ladybug") }
                        #endif
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $axisPickerFolder) { ref in FolderAxisPicker(path: ref.id) }
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
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        func rank(_ n: Note) -> Int {
            if n.displayName.lowercased().hasPrefix(q) { return 0 }
            if n.displayName.lowercased().contains(q) { return 1 }
            if n.folderName.lowercased().contains(q) { return 2 }
            if n.linkTargets.contains(where: { $0.lowercased().contains(q) }) { return 3 }
            return 4
        }
        return model.notes.filter { n in
            n.displayName.lowercased().contains(q)
                || n.folderName.lowercased().contains(q)
                || n.body.lowercased().contains(q)
                || n.linkTargets.contains { $0.lowercased().contains(q) }
        }
        .sorted { a, b in
            let ra = rank(a), rb = rank(b)
            return ra != rb ? ra < rb : a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    @ViewBuilder
    private func row(_ node: FolderNode) -> some View {
        if let note = node.note {
            NavigationLink(value: note.id) { NoteRow(note: note) }
        } else {
            folderRow(node)
        }
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
    }

    private func subtitle(_ folder: Folder) -> String {
        var parts = [folder.category]
        let axisNames = folder.growthAxes.compactMap { model.axis(id: $0)?.name }
        if !axisNames.isEmpty { parts.append(axisNames.joined(separator: " + ")) }
        if let intensity = folder.defaultIntensity { parts.append("⚡\(intensity)") }
        return parts.joined(separator: " · ")
    }

    private func folderMenu(_ path: String, growthAxes: [String], intensity: Int?) -> some View {
        Menu {
            Button { axisPickerFolder = FolderRef(id: path) } label: {
                Label(growthAxes.isEmpty ? "Grows…" : "Grows: \(growthAxes.count) axes", systemImage: "circle.hexagongrid")
            }
            Button { renameFolderPath = path; folderNameDraft = path } label: {
                Label("Rename or move folder…", systemImage: "folder")
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
        } label: {
            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
        }
    }

    // MARK: - Tree

    private func buildTree() -> [FolderNode] {
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
                    if let backupURL {
                        ShareLink(item: backupURL) { Label("Export a backup", systemImage: "square.and.arrow.up") }
                    }
                    Button { showRestorePicker = true } label: {
                        Label("Restore from a backup", systemImage: "arrow.down.doc")
                    }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Export your whole graph as a file to keep in Files or iCloud Drive. Restoring replaces everything currently in Numinous.")
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
            .fileImporter(isPresented: $showRestorePicker, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result { pendingRestore = url }
            }
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
