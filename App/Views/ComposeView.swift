import SwiftUI
import NuminousCore

struct ComposeView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var text = ""
    @State private var intensity = 3
    @State private var location = ""
    @State private var newFolderCategory = ""
    @State private var newFolderAxis = Axis.defaultSet.first?.id ?? "body"

    init(prefillTitle: String?) {
        _title = State(initialValue: prefillTitle ?? "")
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var folderName: String {
        guard let slash = trimmedTitle.lastIndex(of: "/") else { return "" }
        return String(trimmedTitle[..<slash])
    }
    private var knownFolder: Folder? { folderName.isEmpty ? nil : model.folder(named: folderName) }
    private var isNewFolder: Bool { !folderName.isEmpty && knownFolder == nil }
    private var detectedLinks: [String] { WikilinkParser.extract(from: text) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. people/Sam, books/Dune", text: $title)
                        .autocorrectionDisabled()
                        // Folder paths are lowercase; don't auto-capitalize into a new folder.
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Title")
                } footer: {
                    Text("File it as folder/name. End with just \"folder/\" to auto-date.")
                }

                if let folder = knownFolder {
                    Section("Folder") {
                        HStack {
                            Circle().fill(model.axis(id: folder.axisID)?.color ?? .gray).frame(width: 9, height: 9)
                            Text("\(folder.name) · \(folder.category)")
                            Spacer()
                            Text("grows \(model.axis(id: folder.axisID)?.name ?? "—")").foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                } else if isNewFolder {
                    Section("New folder “\(folderName)”") {
                        TextField("Category (e.g. Cognition)", text: $newFolderCategory)
                        Picker("Grows which axis?", selection: $newFolderAxis) {
                            ForEach(model.axes) { Text($0.name).tag($0.id) }
                        }
                    }
                }

                Section("Details") {
                    Picker("Intensity", selection: $intensity) {
                        Text("1 · faint (×0.5)").tag(1)
                        Text("2 · light (×0.75)").tag(2)
                        Text("3 · present (×1)").tag(3)
                        Text("4 · vivid (×1.5)").tag(4)
                        Text("5 · profound (×2)").tag(5)
                    }
                    TextField("Location (optional)", text: $location)
                }

                Section("Note") {
                    LinkingEditor(text: $text)
                    Text("Type [[ to link an existing note, or create a new one.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if !detectedLinks.isEmpty {
                    Section("Connections") {
                        ForEach(detectedLinks, id: \.self) { link in
                            HStack {
                                Image(systemName: model.noteExists(titled: link) ? "link" : "plus.circle")
                                    .foregroundStyle(model.noteExists(titled: link) ? Color.accentColor : .secondary)
                                Text(link)
                                Spacer()
                                if !model.noteExists(titled: link) {
                                    Text("will be created").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("New Note")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: title) { _ in updateSuggestion() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(trimmedTitle.isEmpty)
                }
            }
        }
    }

    private func updateSuggestion() {
        // A note inherits its folder's default intensity (still overridable here).
        if let folder = knownFolder, let d = folder.defaultIntensity { intensity = d }
        guard isNewFolder, newFolderCategory.isEmpty else { return }
        if case let .suggest(axisID, _) = model.suggestAxis(forNewFolderNamed: folderName) {
            newFolderAxis = axisID
        }
    }

    private func save() {
        var finalTitle = trimmedTitle
        guard !finalTitle.isEmpty else { return }
        if finalTitle.hasSuffix("/") { finalTitle += NotesView.stamp() }

        if isNewFolder {
            let category = newFolderCategory.trimmingCharacters(in: .whitespaces)
            model.upsertFolder(name: folderName,
                               category: category.isEmpty ? folderName.capitalized : category,
                               axisID: newFolderAxis)
        }

        let note = Note(title: finalTitle, date: Date(), body: text,
                        intensity: intensity,
                        location: location.trimmingCharacters(in: .whitespaces).isEmpty ? nil : location)
        model.save(note)
        dismiss()
    }
}
