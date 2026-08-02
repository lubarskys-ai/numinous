import SwiftUI
import NuminousCore

/// Write a note by hand. Like capture, it's titled by date and filed under a
/// category you choose (an existing folder or a new one); pick intensity, an
/// optional location, and write freely with inline `[[` linking.
struct ComposeView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var intensity = 3
    @State private var location = ""
    @State private var category: String
    @State private var showNewCategory = false
    @State private var newCategoryDraft = ""
    @State private var showLocationPrompt = false
    @State private var locationDraft = ""
    @State private var locating = false
    @State private var showFollowUp = false
    @State private var reminderNoteTitle = ""
    @State private var scanning = false
    @State private var didScan = false
    @State private var linkedNames: [String] = []
    @StateObject private var locator = LocationService()

    init(prefillTitle: String?) {
        // Historically callers passed a "folder/…"; use its folder as the category.
        let folder: String? = prefillTitle.flatMap { t in
            guard let slash = t.lastIndex(of: "/") else { return t.isEmpty ? nil : t }
            return String(t[..<slash])
        }
        _category = State(initialValue: (folder?.isEmpty == false) ? folder! : "notes")
    }

    /// Categories to file under: sensible defaults plus your existing folders.
    private var categoryOptions: [String] {
        var seen = Set<String>(); var out: [String] = []
        for c in [category, "notes", "diary"] + model.folders.map(\.name) where seen.insert(c.lowercased()).inserted {
            out.append(c)
        }
        return out
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Menu {
                        ForEach(categoryOptions, id: \.self) { cat in
                            Button { category = cat } label: {
                                if cat == category { Label(cat, systemImage: "checkmark") } else { Text(cat) }
                            }
                        }
                        Divider()
                        Button { newCategoryDraft = ""; showNewCategory = true } label: {
                            Label("New category…", systemImage: "plus")
                        }
                    } label: {
                        HStack {
                            Label("Category", systemImage: "folder")
                            Spacer()
                            Text(category).foregroundStyle(.secondary)
                            Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    if let axis = model.axis(id: model.folder(named: category)?.axisID) {
                        Text("Titled by date, filed in \(category) — grows \(axis.name).")
                    } else {
                        Text("Titled with today's date and filed in \(category).")
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
                        Button { Task { await useCurrentLocation() } } label: {
                            HStack {
                                Label(locating ? "Locating…" : "Use current location", systemImage: "location.fill")
                                Spacer()
                                if locating { ProgressView() }
                            }
                        }
                        .disabled(locating)
                        Button("Enter manually") { locationDraft = ""; showLocationPrompt = true }
                            .font(.callout)
                    } else {
                        Button { locationDraft = location; showLocationPrompt = true } label: {
                            HStack {
                                Label(location, systemImage: "mappin.and.ellipse").foregroundStyle(.primary)
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

                Section {
                    Button {
                        scanning = true
                        Task {
                            let found = await model.smartLinkSuggestions(in: text)
                            for s in found { applyLink(s) }
                            linkedNames = found.map(\.name)
                            didScan = true
                            scanning = false
                        }
                    } label: {
                        if scanning {
                            HStack { ProgressView(); Text("Finding links…") }
                        } else {
                            Label("Find & add links", systemImage: "link.badge.plus")
                        }
                    }
                    .disabled(scanning || text.trimmingCharacters(in: .whitespaces).count < 3)
                    if didScan {
                        if linkedNames.isEmpty {
                            Text("Nothing to link yet — try naming a person, place, or thing.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Label("Linked \(linkedNames.joined(separator: " · "))", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                        }
                    }
                } footer: {
                    Text("Finds the people, places, and things you mention and links them right in.")
                }

                Section {
                    Button {
                        let id = createNote()
                        reminderNoteTitle = model.note(id: id)?.title ?? category
                        showFollowUp = true
                    } label: {
                        Label("Remind me to follow up…", systemImage: "bell.badge")
                    }
                }
            }
            .navigationTitle("New Note")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if location.isEmpty, locator.isAuthorized { await useCurrentLocation() }
            }
            .alert("New category", isPresented: $showNewCategory) {
                TextField("e.g. golf clubs", text: $newCategoryDraft).autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Use") {
                    let c = newCategoryDraft.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
                    if !c.isEmpty { category = c }
                }
            } message: {
                Text("Notes here are titled by date. The folder is created for you.")
            }
            .alert("Location", isPresented: $showLocationPrompt) {
                TextField("Where were you?", text: $locationDraft)
                Button("Cancel", role: .cancel) {}
                Button("Save") { location = locationDraft.trimmingCharacters(in: .whitespaces) }
            } message: {
                Text("Add a place to this note.")
            }
            .sheet(isPresented: $showFollowUp, onDismiss: { dismiss() }) {
                FollowUpSheet(noteTitle: reminderNoteTitle, defaultTitle: followUpDefault) { _ in }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(category.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func useCurrentLocation() async {
        locating = true
        if let place = await locator.currentPlace() {
            location = place
        } else if !locator.isAuthorized {
            locationDraft = ""; showLocationPrompt = true
        }
        locating = false
    }

    private func save() { _ = createNote(); dismiss() }

    @discardableResult
    private func createNote() -> UUID {
        model.createCapturedNote(body: text, folder: category, intensity: intensity,
                                 location: location.isEmpty ? nil : location)
    }

    /// Wire a found link into the note text — replace the words in place (punctuation/
    /// case-tolerant), or append if the cleaned name isn't found verbatim.
    private func applyLink(_ s: LinkSuggestion) {
        let wikilink = "[[\(s.target)]]"
        if !s.surface.isEmpty, let r = AutoLinker.flexibleRange(of: s.surface, in: text) {
            text.replaceSubrange(r, with: wikilink)
        } else if let r = AutoLinker.flexibleRange(of: s.name, in: text) {
            text.replaceSubrange(r, with: wikilink)
        } else {
            text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + wikilink
        }
    }

    /// A sensible reminder title seeded from the note's opening words.
    private var followUpDefault: String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
        let words = firstLine.split(separator: " ").prefix(4).joined(separator: " ")
        return words.isEmpty ? "Follow up" : "Follow up: \(words)"
    }
}
