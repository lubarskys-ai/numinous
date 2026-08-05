import SwiftUI
import UIKit
import NuminousCore

/// A full-screen note editor: the writing area is the hero (a big text view, NOT a
/// Form row — which is what bounced the cursor), with category, details, and links
/// tucked into compact bars. Titled by date, filed under a chosen category.
///
/// "Find links" never rewrites what you typed. It scans the text and shows its
/// findings as **highlights** — blue for things it can auto-link to notes you already
/// have, orange for brand-new notes it proposes — and you add, edit, or skip each.
/// Wikilinks are only written into the saved note, and only for the ones you keep.
struct ComposeView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var intensity = 3
    @State private var location = ""
    @State private var category: String
    @State private var showCategoryPicker = false
    @State private var showLocationPrompt = false
    @State private var locationDraft = ""
    @State private var locating = false
    @State private var showFollowUp = false
    @State private var reminderNoteTitle = ""
    @State private var scanning = false
    @State private var didScan = false
    @State private var manualEdit = false                 // editing text while a scan's results are held
    @State private var confirmed: [LinkSuggestion] = []   // auto-linked (blue) — applied on save
    @State private var pending: [LinkSuggestion] = []     // proposed new notes (orange) — awaiting a decision
    @State private var editSheetFor: LinkSuggestion?
    @State private var actionFor: LinkSuggestion?          // a highlighted span the user tapped
    @State private var editName = ""
    @State private var editFolder = "notes"
    @State private var existingNoteID: UUID?               // set in diary mode → save updates in place
    @State private var diaryResolved = false
    @StateObject private var locator = LocationService()

    /// When true, this is "Add to today's diary": on appear it pulls today's diary entry
    /// forward (if one exists) and saves back into it instead of creating a new note.
    let diaryMode: Bool

    /// Optional: notified with the new note's id after Save (used by quick-capture /
    /// Folders to switch tabs or push the note). The editor still dismisses itself.
    var onSaved: ((UUID) -> Void)? = nil

    init(prefillTitle: String? = nil, diary: Bool = false, onSaved: ((UUID) -> Void)? = nil) {
        self.onSaved = onSaved
        self.diaryMode = diary
        let folder: String? = prefillTitle.flatMap { t in
            guard let slash = t.lastIndex(of: "/") else { return t.isEmpty ? nil : t }
            return String(t[..<slash])
        }
        _category = State(initialValue: diary ? "notes/diary" : ((folder?.isEmpty == false) ? folder! : "notes"))
    }

    /// True once a scan found something to review. In this mode the note text is shown
    /// read-only with the findings highlighted, so nothing gets rewritten under you.
    private var reviewing: Bool { didScan && (!confirmed.isEmpty || !pending.isEmpty) }

    /// The category shown on the chip — just the leaf, so "notes/diary" reads as "diary".
    private var categoryLabel: String {
        guard let slash = category.lastIndex(of: "/") else { return category }
        return String(category[category.index(after: slash)...])
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
                if reviewing && !manualEdit {
                    reviewArea
                } else {
                    LinkingEditor(text: $text)
                        .padding(.horizontal, 14)
                        .padding(.top, 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if reviewing {
                        reviewWhileEditing   // keep suggestions reachable while you edit
                    } else if didScan {
                        linkStatus
                    }
                }
            }
            .navigationTitle(reviewing && !manualEdit ? "Review links" : (diaryMode ? "Today's Diary" : "New Note"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(category.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    if reviewing && !manualEdit {
                        Button { manualEdit = true } label: { Label("Edit text", systemImage: "pencil") }
                    } else {
                        Button { findLinks() } label: {
                            if scanning { HStack { ProgressView(); Text("Finding…") } }
                            else { Label(didScan ? "Re-scan" : "Find links", systemImage: "link.badge.plus") }
                        }
                        .disabled(scanning || text.trimmingCharacters(in: .whitespaces).count < 3)
                        if reviewing && manualEdit {
                            Button { manualEdit = false } label: { Label("Highlights", systemImage: "highlighter") }
                        }
                    }
                    Spacer()
                    detailsMenu
                }
            }
            .task { if location.isEmpty, locator.isAuthorized { await useCurrentLocation() } }
            .onAppear { resolveDiary() }
            .alert("Location", isPresented: $showLocationPrompt) {
                TextField("Where were you?", text: $locationDraft)
                Button("Cancel", role: .cancel) {}
                Button("Save") { location = locationDraft.trimmingCharacters(in: .whitespaces) }
            } message: { Text("Add a place to this note.") }
            .sheet(item: $editSheetFor) { s in editSheet(s) }
            .sheet(isPresented: $showFollowUp, onDismiss: { dismiss() }) {
                FollowUpSheet(noteTitle: reminderNoteTitle, defaultTitle: followUpDefault) { _ in }
            }
        }
    }

    // MARK: - Bars

    private var categoryBar: some View {
        Button { showCategoryPicker = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                Text(categoryLabel).fontWeight(.medium)
                Image(systemName: "chevron.down").font(.caption2)
                Spacer()
                if !location.isEmpty { Label(location, systemImage: "mappin.and.ellipse").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Text("⚡\(intensity)").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .sheet(isPresented: $showCategoryPicker) { CategoryPickerView(category: $category) }
    }

    // MARK: - Review (highlighted preview — the note text is never rewritten here)

    private var reviewArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(reviewText())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                    .tint(.blue)
                    .environment(\.openURL, OpenURLAction { url in handleSpanTap(url); return .handled })

                if !pending.isEmpty {
                    Divider()
                    Text("New links to review").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(pending) { s in pendingRow(s) }
                }

                Label("Tap any highlight to add or edit it. Blue = linked to notes you already have; orange = suggested new notes.",
                      systemImage: "hand.tap")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .confirmationDialog(actionFor?.name ?? "Link",
                            isPresented: Binding(get: { actionFor != nil }, set: { if !$0 { actionFor = nil } }),
                            titleVisibility: .visible,
                            presenting: actionFor) { s in
            if pending.contains(where: { $0.id == s.id }) {
                Button("Add to \(s.folderLabel.isEmpty ? "notes" : s.folderLabel)") { confirm(s); actionFor = nil }
                Button("Edit folder…") { actionFor = nil; beginEdit(s) }
                Button("Skip", role: .destructive) {
                    model.recordLinkSkipped(name: s.name, surface: s.surface)
                    pending.removeAll { $0.id == s.id }; actionFor = nil
                }
            } else {
                Button("Edit link…") { actionFor = nil; beginEdit(s) }
                Button("Remove link", role: .destructive) { confirmed.removeAll { $0.id == s.id }; actionFor = nil }
            }
        } message: { s in
            Text(pending.contains(where: { $0.id == s.id })
                 ? "New note in “\(s.folderLabel.isEmpty ? "notes" : s.folderLabel)”."
                 : "Linked to \(s.target).")
        }
    }

    private func pendingRow(_ s: LinkSuggestion) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Color.orange).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(.callout.weight(.medium))
                Text(folderPart(s.target)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add") { confirm(s) }.buttonStyle(.borderless)
            Menu {
                Button { beginEdit(s) } label: { Label("Edit folder…", systemImage: "folder") }
                Button(role: .destructive) {
                    model.recordLinkSkipped(name: s.name, surface: s.surface)
                    pending.removeAll { $0.id == s.id }
                } label: {
                    Label("Skip", systemImage: "xmark")
                }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var linkStatus: some View {
        Group {
            if !confirmed.isEmpty || !pending.isEmpty {
                Label("Found \(confirmed.count + pending.count) — review above.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Text("Nothing to link yet — name a person, place, or thing.").foregroundStyle(.secondary)
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

    /// Scan for links and enter review — WITHOUT touching the note text. Findings are
    /// held as suggestions and only written into the note when you save.
    private func findLinks() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        scanning = true
        Task {
            let found = await model.smartLinkSuggestions(in: text)
            confirmed = found.filter { !$0.isNew }
            pending = found.filter { $0.isNew }
            didScan = true
            // Stay editable by default — the note text must never lock. Suggestions sit
            // in the strip below; "Highlights" shows the marked-up read-only view on demand.
            manualEdit = true
            scanning = false
        }
    }

    private func confirm(_ s: LinkSuggestion) {
        pending.removeAll { $0.id == s.id }
        if !confirmed.contains(where: { $0.id == s.id }) { confirmed.append(s) }
        model.recordLinkConfirmed(name: s.name, surface: s.surface, target: s.target)
    }

    private func beginEdit(_ s: LinkSuggestion) {
        editName = s.name
        editFolder = folderPart(s.target)
        editSheetFor = s
    }

    private func commitEdit(_ s: LinkSuggestion) {
        let folder = editFolder.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        let name = editName.trimmingCharacters(in: .whitespaces)
        let target = (folder.isEmpty ? "notes" : folder) + "/" + name
        let edited = LinkSuggestion(name: name, target: target, surface: s.surface, isNew: true)
        pending.removeAll { $0.id == s.id }
        confirmed.removeAll { $0.id == s.id }
        confirmed.append(edited)
        model.recordLinkConfirmed(name: edited.name, surface: edited.surface, target: edited.target)
        editSheetFor = nil
    }

    /// A compact strip shown under the editor while you edit text with a scan's
    /// results still held — so links stay reachable (Add/Skip) without leaving edit mode.
    @ViewBuilder
    private var reviewWhileEditing: some View {
        if !confirmed.isEmpty || !pending.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !confirmed.isEmpty {
                    Label("\(confirmed.count) link\(confirmed.count == 1 ? "" : "s") ready to save", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
                if !pending.isEmpty {
                    ScrollView {
                        VStack(spacing: 4) { ForEach(pending) { s in pendingRow(s) } }
                    }
                    .frame(maxHeight: 150)
                    Text("Tap “Highlights” to see these marked in your note.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
    }

    private func editSheet(_ s: LinkSuggestion) -> some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("Name", text: $editName) }
                Section("Folder") {
                    TextField("folder path", text: $editFolder)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(categoryOptions, id: \.self) { cat in
                                Button { editFolder = cat } label: {
                                    Text(cat).font(.caption.weight(.medium))
                                        .padding(.horizontal, 11).padding(.vertical, 6)
                                        .background((editFolder == cat ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12)), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Edit link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editSheetFor = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { commitEdit(s) }
                        .disabled(editName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func useCurrentLocation() async {
        locating = true
        if let place = await locator.currentPlace() { location = place }
        else if !locator.isAuthorized { locationDraft = ""; showLocationPrompt = true }
        locating = false
    }

    /// In diary mode, pull today's entry forward so you continue writing in it.
    private func resolveDiary() {
        guard diaryMode, !diaryResolved else { return }
        diaryResolved = true
        if let id = model.todaysDiaryID() {
            existingNoteID = id
            text = model.note(id: id)?.body ?? ""
        }
    }

    private func save() { let id = createNote(); onSaved?(id); dismiss() }

    /// Build the note body with the confirmed/kept links woven in, then persist —
    /// updating today's diary in place when we pulled one forward, otherwise creating a
    /// new note. This is the ONLY place the note text gains wikilinks from a scan.
    @discardableResult
    private func createNote() -> UUID {
        var body = text
        for s in confirmed { body = insert(s, into: body) }
        if let id = existingNoteID {
            model.updateBody(id, body: body)
            return id
        }
        return model.createCapturedNote(body: body, folder: category, intensity: intensity,
                                        location: location.isEmpty ? nil : location)
    }

    // MARK: - Text helpers

    /// The note text with confident links (blue) and proposed new ones (orange) marked,
    /// for the review preview. The note text itself is untouched.
    private func reviewText() -> AttributedString {
        struct Mark { let range: Range<String.Index>; let pending: Bool; let id: UUID }
        var marks: [Mark] = []
        for s in confirmed {
            if let r = AutoLinker.flexibleRange(of: s.surface.isEmpty ? s.name : s.surface, in: text) {
                marks.append(Mark(range: r, pending: false, id: s.id))
            }
        }
        for s in pending {
            if let r = AutoLinker.flexibleRange(of: s.surface.isEmpty ? s.name : s.surface, in: text) {
                marks.append(Mark(range: r, pending: true, id: s.id))
            }
        }
        marks.sort { $0.range.lowerBound < $1.range.lowerBound }

        var out = AttributedString()
        var cursor = text.startIndex
        for m in marks where m.range.lowerBound >= cursor {
            if cursor < m.range.lowerBound {
                out += AttributedString(String(text[cursor..<m.range.lowerBound]))
            }
            var chip = AttributedString(String(text[m.range]))
            // Tapping the highlight itself opens edit/add — intercepted via openURL below.
            chip.link = URL(string: "\(Self.linkScheme)\(m.id.uuidString)")
            chip.underlineStyle = .single
            if m.pending {
                chip.backgroundColor = Color.orange.opacity(0.30)
            } else {
                chip.foregroundColor = .blue
            }
            out += chip
            cursor = m.range.upperBound
        }
        if cursor < text.endIndex { out += AttributedString(String(text[cursor...])) }
        return out
    }

    private static let linkScheme = "numinous-suggest:"

    /// A tap on a highlighted span → open contextual add/edit for that suggestion.
    private func handleSpanTap(_ url: URL) {
        let all = pending + confirmed
        actionFor = all.first { "\(Self.linkScheme)\($0.id.uuidString)" == url.absoluteString }
    }

    private func insert(_ s: LinkSuggestion, into body: String) -> String {
        var body = body
        let wikilink = "[[\(s.target)]]"
        if !s.surface.isEmpty, let r = AutoLinker.flexibleRange(of: s.surface, in: body) {
            body.replaceSubrange(r, with: wikilink)
        } else if let r = AutoLinker.flexibleRange(of: s.name, in: body) {
            body.replaceSubrange(r, with: wikilink)
        } else {
            body += (body.isEmpty || body.hasSuffix("\n") ? "" : "\n") + wikilink
        }
        return body
    }

    private func folderPart(_ target: String) -> String {
        guard let slash = target.lastIndex(of: "/") else { return "notes" }
        return String(target[..<slash])
    }

    private var followUpDefault: String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
        let words = firstLine.split(separator: " ").prefix(4).joined(separator: " ")
        return words.isEmpty ? "Follow up" : "Follow up: \(words)"
    }
}
