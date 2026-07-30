import SwiftUI
import NuminousCore

/// The Folders tab as a clean, collapsible folder → file tree: every folder
/// expands to its notes, all in one place. Each folder maps to a growth axis.
struct FoldersView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false

    private struct Node: Identifiable {
        let id: String        // folder path ("" = Unfiled)
        let notes: [Note]
    }

    private var tree: [Node] {
        var byFolder: [String: [Note]] = [:]
        for group in model.groupedByFolder { byFolder[group.id] = group.notes }
        var names = Set(model.folders.map { $0.name })
        for key in byFolder.keys where !key.isEmpty { names.insert(key) }
        var nodes = names
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { Node(id: $0, notes: byFolder[$0] ?? []) }
        if let unfiled = byFolder[""], !unfiled.isEmpty {
            nodes.append(Node(id: "", notes: unfiled))
        }
        return nodes
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(tree) { node in
                    DisclosureGroup {
                        if !node.id.isEmpty {
                            axisMenu(for: node.id)
                        }
                        if node.notes.isEmpty {
                            Text("No notes yet").font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(node.notes) { note in
                                NavigationLink(value: note.id) { NoteRow(note: note) }
                            }
                        }
                    } label: {
                        header(for: node)
                    }
                }
            }
            .navigationTitle("Folders")
            .navigationDestination(for: UUID.self) { id in NoteDetailView(noteID: id) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Customize axes")
                }
            }
            .sheet(isPresented: $showSettings) { AxisSettingsView() }
        }
    }

    private func header(for node: Node) -> some View {
        let folder = model.folder(named: node.id)
        return HStack(spacing: 10) {
            Circle().fill(model.axis(id: folder?.axisID)?.color ?? Color.gray.opacity(0.4))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.id.isEmpty ? "Unfiled" : node.id).font(.body.weight(.medium))
                if let folder {
                    Text("\(folder.category) · \(model.axis(id: folder.axisID)?.name ?? "—")")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !node.id.isEmpty {
                    Text("needs a category").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Text("\(node.notes.count)").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func axisMenu(for folderName: String) -> some View {
        let current = model.axis(id: model.folder(named: folderName)?.axisID)?.name
        return Menu {
            ForEach(model.axes) { axis in
                Button {
                    model.assignAxis(toFolder: folderName, axisID: axis.id)
                } label: {
                    if current == axis.name { Label(axis.name, systemImage: "checkmark") }
                    else { Text(axis.name) }
                }
            }
        } label: {
            Label("Grows: \(current ?? "choose an axis")", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
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
