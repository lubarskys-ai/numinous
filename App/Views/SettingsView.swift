import SwiftUI
import NuminousCore

/// Customize the axes — rename and recolor the parts of life the avatar grows
/// along. The engine only ever reasons about axis *ids*, so renaming is purely
/// cosmetic and never disturbs scoring or history.
struct SettingsView: View {
    @EnvironmentObject var store: NoteStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(store.axes) { axis in
                        AxisEditorRow(axis: axis)
                    }
                } header: {
                    Text("Axes")
                } footer: {
                    Text("Axes are the parts of life your avatar grows along. Rename or recolor them to fit how you think about your life — your notes and growth stay exactly as they are.")
                }

                Section {
                    Button("Reset axes to defaults", role: .destructive) {
                        store.resetAxes()
                    }
                }
            }
            .navigationTitle("Customize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct AxisEditorRow: View {
    @EnvironmentObject var store: NoteStore
    let axis: Axis

    @State private var name: String = ""

    var body: some View {
        HStack(spacing: 12) {
            ColorPicker("", selection: Binding(
                get: { Color(hex: store.axis(axis.id)?.colorHex ?? axis.colorHex) },
                set: { newColor in
                    if let hex = newColor.toHex() { store.setAxisColor(axis.id, hex: hex) }
                }
            ))
            .labelsHidden()

            TextField("Name", text: $name)
                .textInputAutocapitalization(.words)
        }
        .onAppear { name = axis.name }
        .onChange(of: name) { newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != store.axis(axis.id)?.name {
                store.renameAxis(axis.id, name: trimmed)
            }
        }
    }
}
