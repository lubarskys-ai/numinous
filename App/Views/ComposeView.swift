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
    @State private var showLocationPrompt = false
    @State private var locationDraft = ""
    @State private var locating = false
    @StateObject private var locator = LocationService()

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
                    if location.isEmpty {
                        Button {
                            Task { await useCurrentLocation() }
                        } label: {
                            HStack {
                                Label(locating ? "Locating…" : "Use current location",
                                      systemImage: "location.fill")
                                Spacer()
                                if locating { ProgressView() }
                            }
                        }
                        .disabled(locating)
                        Button("Enter manually") { locationDraft = ""; showLocationPrompt = true }
                            .font(.callout)
                    } else {
                        Button {
                            locationDraft = location
                            showLocationPrompt = true
                        } label: {
                            HStack {
                                Label(location, systemImage: "mappin.and.ellipse")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("Edit").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Note") {
                    LinkingEditor(text: $text)
                    Text("Type [[ to link an existing note, or create a new one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New Note")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: title) { _ in updateSuggestion() }
            .task {
                // Automatic: if location access is already granted, fill it in silently.
                if location.isEmpty, locator.isAuthorized { await useCurrentLocation() }
            }
            .alert("Location", isPresented: $showLocationPrompt) {
                TextField("Where were you?", text: $locationDraft)
                Button("Cancel", role: .cancel) {}
                Button("Save") { location = locationDraft.trimmingCharacters(in: .whitespaces) }
            } message: {
                Text("Add a place to this note.")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(trimmedTitle.isEmpty)
                }
            }
        }
    }

    private func useCurrentLocation() async {
        locating = true
        if let place = await locator.currentPlace() {
            location = place
        } else if !locator.isAuthorized {
            // Denied or unavailable — let them type it instead.
            locationDraft = ""; showLocationPrompt = true
        }
        locating = false
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
