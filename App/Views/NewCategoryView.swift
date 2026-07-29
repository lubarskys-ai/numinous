import SwiftUI
import NuminousCore

/// Create a new user-defined category and map it to an axis. The axis picker is
/// pre-filled with a suggestion once there's enough data to compare against —
/// always overridable, never auto-applied.
struct NewCategoryView: View {
    @EnvironmentObject var store: NoteStore
    @Environment(\.dismiss) private var dismiss

    var onCreated: (String) -> Void

    @State private var name = ""
    @State private var axisID: String = Axis.defaultSet.first?.id ?? "body"
    @State private var suggestedAxisID: String?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Hiking, Courses, Dates", text: $name)
                        .autocorrectionDisabled()
                }

                Section("Which part of life does this grow?") {
                    Picker("Axis", selection: $axisID) {
                        ForEach(store.axes) { axis in
                            Text(axis.name).tag(axis.id)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()

                    if let suggestedAxisID, let axis = store.axis(suggestedAxisID) {
                        Label("Suggested from your other categories: \(axis.name)",
                              systemImage: "wand.and.stars")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("New Category")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: name) { newValue in updateSuggestion(newValue) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let category = store.addCategory(name: trimmedName, axisID: axisID)
                        onCreated(category.id)
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty)
                }
            }
        }
    }

    private func updateSuggestion(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { suggestedAxisID = nil; return }
        switch store.suggestAxis(forNewCategoryNamed: trimmed) {
        case .askUser:
            suggestedAxisID = nil
        case .suggest(let suggested, _):
            suggestedAxisID = suggested
            axisID = suggested
        }
    }
}
