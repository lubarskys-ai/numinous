import SwiftUI
import NuminousCore

/// Reference + management of folders: each folder's category and the axis it
/// grows. Changing a folder's axis reflows all its notes' contributions.
struct FoldersView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.folders) { folder in
                        HStack {
                            Circle().fill(model.axis(id: folder.axisID)?.color ?? Color.gray.opacity(0.4))
                                .frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(folder.name).font(.body.weight(.medium))
                                Text(folder.category).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu {
                                ForEach(model.axes) { axis in
                                    Button {
                                        model.setFolderAxis(axis.id, forFolder: folder.id)
                                    } label: {
                                        if folder.axisID == axis.id { Label(axis.name, systemImage: "checkmark") }
                                        else { Text(axis.name) }
                                    }
                                }
                            } label: {
                                Text(model.axis(id: folder.axisID)?.name ?? "Choose")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("Each folder's category maps to a growth axis. Changing the axis reflows every note in that folder.")
                }
            }
            .navigationTitle("Folders")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Customize axes")
                }
            }
            .sheet(isPresented: $showSettings) { AxisSettingsView() }
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
