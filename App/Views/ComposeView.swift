import SwiftUI
import NuminousCore

/// A full-screen note editor: the writing area is the hero (a big text view, NOT a
/// Form row — which is what bounced the cursor), with category, details, and links
/// tucked into compact bars. Titled by date, filed under a chosen category.
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
        let folder: String? = prefillTitle.flatMap { t in
            guard let slash = t.lastIndex(of: "/") else { return t.isEmpty ? nil : t }
            return String(t[..<slash])
        }
        _category = State(initialValue: (folder?.isEmpty == false) ? folder! : "notes")
    }

    private var categoryOptions: [String] {
        var seen = Set<String>(); var out: [String] = []
        for c in [category, "notes", "diary"] + model.folders.map(\.name) where seen.insert(c.lowercased()).inserted {
            out.append(c)
        }
        return out
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                categoryBar
                Divider()
                LinkingEditor(text: $text)
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if didScan { linkStatus }
            }
            .navigationTitle("New Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(category.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { findLinks() } label: {
                        if scanning { HStack { ProgressView(); Text("Finding…") } }
                        else { Label("Find links", systemImage: "link.badge.plus") }
                    }
                    .disabled(scanning || text.trimmingCharacters(in: .whitespaces).count < 3)
                    Spacer()
                    detailsMenu
                }
            }
            .task { if location.isEmpty, locator.isAuthorized { await useCurrentLocation() } }
            .alert("New category", isPresented: $showNewCategory) {
                TextField("e.g. golf clubs", text: $newCategoryDraft).autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Use") {
                    let c = newCategoryDraft.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
                    if !c.isEmpty { category = c }
                }
            } message: { Text("Notes here are titled by date. The folder is created for you.") }
            .alert("Location", isPresented: $showLocationPrompt) {
                TextField("Where were you?", text: $locationDraft)
                Button("Cancel", role: .cancel) {}
                Button("Save") { location = locationDraft.trimmingCharacters(in: .whitespaces) }
            } message: { Text("Add a place to this note.") }
            .sheet(isPresented: $showFollowUp, onDismiss: { dismiss() }) {
                FollowUpSheet(noteTitle: reminderNoteTitle, defaultTitle: followUpDefault) { _ in }
            }
        }
    }

    // MARK: - Bars

    private var categoryBar: some View {
        Menu {
            ForEach(categoryOptions, id: \.self) { cat in
                Button { category = cat } label: {
                    if cat == category { Label(cat, systemImage: "checkmark") } else { Text(cat) }
                }
            }
            Divider()
            Button { newCategoryDraft = ""; showNewCategory = true } label: { Label("New category…", systemImage: "plus") }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                Text(category).fontWeight(.medium)
                Image(systemName: "chevron.down").font(.caption2)
                Spacer()
                if !location.isEmpty { Label(location, systemImage: "mappin.and.ellipse").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Text("⚡\(intensity)").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private var linkStatus: some View {
        Group {
            if linkedNames.isEmpty {
                Text("Nothing to link yet — name a person, place, or thing.").foregroundStyle(.secondary)
            } else {
                Label("Linked \(linkedNames.joined(separator: " · "))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var detailsMenu: some View {
        Menu {
            Picker("Intensity", selection: $intensity) {
                Text("1 · faint").tag(1); Text("2 · light").tag(2); Text("3 · present").tag(3)
                Text("4 · vivid").tag(4); Text("5 · profound").tag(5)
            }
            if location.isEmpty {
                Button { Task { await useCurrentLocation() } } label: { Label("Use current location", systemImage: "location.fill") }
                Button { locationDraft = ""; showLocationPrompt = true } label: { Label("Enter location", systemImage: "mappin") }
            } else {
                Button { locationDraft = location; showLocationPrompt = true } label: { Label("Edit location", systemImage: "mappin.and.ellipse") }
                Button(role: .destructive) { location = "" } label: { Label("Clear location", systemImage: "xmark") }
            }
            Divider()
            Button { let id = createNote(); reminderNoteTitle = model.note(id: id)?.title ?? category; showFollowUp = true } label: {
                Label("Save & remind me…", systemImage: "bell.badge")
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
    }

    // MARK: - Actions

    private func findLinks() {
        scanning = true
        Task {
            let found = await model.smartLinkSuggestions(in: text)
            for s in found { applyLink(s) }
            linkedNames = found.map(\.name)
            didScan = true
            scanning = false
        }
    }

    private func useCurrentLocation() async {
        locating = true
        if let place = await locator.currentPlace() { location = place }
        else if !locator.isAuthorized { locationDraft = ""; showLocationPrompt = true }
        locating = false
    }

    private func save() { _ = createNote(); dismiss() }

    @discardableResult
    private func createNote() -> UUID {
        model.createCapturedNote(body: text, folder: category, intensity: intensity,
                                 location: location.isEmpty ? nil : location)
    }

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

    private var followUpDefault: String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
        let words = firstLine.split(separator: " ").prefix(4).joined(separator: " ")
        return words.isEmpty ? "Follow up" : "Follow up: \(words)"
    }
}
