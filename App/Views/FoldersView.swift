import SwiftUI
import NuminousCore

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
    @State private var showCompose = false
    @State private var showReadwise = false
    @State private var composePrefill: String?
    @State private var importMessage: String?
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                OutlineGroup(buildTree(), children: \.children) { node in
                    row(node)
                }
            }
            .navigationTitle("Folders")
            .navigationDestination(for: UUID.self) { id in NoteDetailView(noteID: id) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Customize axes")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { composePrefill = nil; showCompose = true } label: { Label("New note", systemImage: "square.and.pencil") }
                        Button { path.append(model.createDiaryEntry()) } label: { Label("Diary entry", systemImage: "calendar.badge.plus") }
                        Divider()
                        Button { importContacts() } label: { Label("Import contacts", systemImage: "person.crop.circle.badge.plus") }
                        Button { showReadwise = true } label: { Label("Import from Readwise", systemImage: "books.vertical") }
                        #if DEBUG
                        Button { let (a, u) = model.importReadwise(ReadwiseService.sampleBooks); importMessage = "Readwise (sample): \(a) new, \(u) updated." } label: { Label("Readwise sample (debug)", systemImage: "ladybug") }
                        #endif
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showCompose) { ComposeView(prefillTitle: composePrefill) }
            .sheet(isPresented: $showReadwise) { ReadwiseConnectView() }
            .sheet(isPresented: $showSettings) { AxisSettingsView() }
            .alert("Import", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(importMessage ?? "") }
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
        return HStack(spacing: 10) {
            Circle().fill(axis?.color ?? Color.gray.opacity(0.4)).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.displayName).font(.body.weight(.medium))
                if let folder {
                    Text(subtitle(folder, axis)).font(.caption).foregroundStyle(.secondary)
                } else if !path.isEmpty, model.notes.contains(where: { $0.folderName == path }) {
                    Text("needs a category").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
            if node.noteNodes.count > 0 {
                Text("\(node.noteNodes.count)").font(.caption).foregroundStyle(.secondary)
            }
            if !path.isEmpty { folderMenu(path, current: axis?.name, intensity: folder?.defaultIntensity) }
        }
    }

    private func subtitle(_ folder: Folder, _ axis: Axis?) -> String {
        var parts = [folder.category]
        if let axis { parts.append(axis.name) }
        if let intensity = folder.defaultIntensity { parts.append("⚡\(intensity)") }
        return parts.joined(separator: " · ")
    }

    private func folderMenu(_ path: String, current: String?, intensity: Int?) -> some View {
        Menu {
            Menu("Grows") {
                ForEach(model.axes) { axis in
                    Button { model.assignAxis(toFolder: path, axisID: axis.id) } label: {
                        if current == axis.name { Label(axis.name, systemImage: "checkmark") } else { Text(axis.name) }
                    }
                }
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
                    : "Imported \(added) new, updated \(updated) in your People folder."
            } catch ContactsImporter.ImportError.accessDenied {
                importMessage = "Contacts access was declined. You can enable it in Settings → Numinous."
            } catch {
                importMessage = "Couldn't import contacts: \(error.localizedDescription)"
            }
        }
    }
}

/// Rename and recolor the axes (purely cosmetic — scoring uses axis ids).
struct AxisSettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

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
            }
            .navigationTitle("Customize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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
