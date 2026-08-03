import SwiftUI
import NuminousCore

/// Quick capture: dictate (via the keyboard mic) or type a note, then let Numinous
/// find the people and things you mentioned. Confident matches to notes you already
/// have are linked automatically; brand-new ones are highlighted for you to confirm,
/// edit, or skip — nothing is written into the note until you save.
struct CaptureView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var onSaved: (UUID) -> Void

    @State private var text = ""
    @State private var category = "notes"
    @State private var showNewCategory = false
    @State private var newCategoryDraft = ""
    @State private var scanning = false
    @State private var didScan = false
    @State private var confirmed: [LinkSuggestion] = []   // will link on save (auto or approved)
    @State private var pending: [LinkSuggestion] = []     // proposed new notes, awaiting a decision
    @State private var editSheetFor: LinkSuggestion?
    @State private var editName = ""
    @State private var editFolder = "notes"
    @FocusState private var focused: Bool

    private var reviewing: Bool { didScan && (!confirmed.isEmpty || !pending.isEmpty) }

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
                noteSection
                if reviewing { pendingSection }
                categorySection
                if !reviewing { findSection }
            }
            .navigationTitle("Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focused = true }
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
            .sheet(item: $editSheetFor) { s in editSheet(s) }
        }
    }

    // MARK: - Note (editor, or highlighted review preview)

    @ViewBuilder
    private var noteSection: some View {
        Section {
            if reviewing {
                Text(reviewText())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                Button { exitReview() } label: {
                    Label("Edit note text", systemImage: "pencil")
                }
                .font(.callout)
            } else {
                TextEditor(text: $text)
                    .frame(minHeight: 150)
                    .focused($focused)
                    .onChange(of: text) { _ in didScan = false; confirmed = []; pending = [] }
            }
        } header: {
            Text(reviewing ? "Review links" : "Speak or type")
        } footer: {
            if reviewing {
                Text("Blue = auto-linked. Orange = suggested new notes, listed below to add or skip.")
            } else {
                Text("Tap the 🎤 on your keyboard to dictate, then find the links.")
            }
        }
    }

    /// Reliable list of proposed new links — add, edit the folder, or skip each.
    @ViewBuilder
    private var pendingSection: some View {
        if !pending.isEmpty {
            Section {
                ForEach(pending) { s in
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
                            Button(role: .destructive) { pending.removeAll { $0.id == s.id } } label: {
                                Label("Skip", systemImage: "xmark")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("New links to review")
            } footer: {
                Text("Add the ones that fit; skip the rest. Nothing is written until you save.")
            }
        }
    }

    private var categorySection: some View {
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
            Text("Titled with today's date and filed here (e.g. diary).")
        }
    }

    private var findSection: some View {
        Section {
            Button {
                scanning = true
                Task {
                    let found = await model.smartLinkSuggestions(in: text)
                    confirmed = found.filter { !$0.isNew }
                    pending = found.filter { $0.isNew }
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

            if didScan && confirmed.isEmpty && pending.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nothing to link yet — try naming a person, place, or thing.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let hint = model.onDeviceAIHint {
                        Label(hint, systemImage: "sparkles").font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
        } footer: {
            Text("Links people & places you already track, and proposes new notes for the rest.")
        }
    }

    // MARK: - Edit sheet

    private func editSheet(_ s: LinkSuggestion) -> some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $editName)
                }
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

    // MARK: - Actions

    private func confirm(_ s: LinkSuggestion) {
        pending.removeAll { $0.id == s.id }
        if !confirmed.contains(where: { $0.id == s.id }) { confirmed.append(s) }
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
        editSheetFor = nil
    }

    private func exitReview() {
        confirmed = []; pending = []; didScan = false
    }

    private func save() {
        var body = text
        for s in confirmed { body = insert(s, into: body) }
        let id = model.createCapturedNote(body: body, folder: category)
        onSaved(id); dismiss()
    }

    // MARK: - Text helpers

    /// The note text with confident links (blue) and proposed new ones (orange,
    /// tappable) marked — for the review preview. The note text itself is untouched.
    private func reviewText() -> AttributedString {
        struct Mark { let range: Range<String.Index>; let pending: Bool; let index: Int }
        var marks: [Mark] = []
        for (i, s) in confirmed.enumerated() {
            if let r = AutoLinker.flexibleRange(of: s.surface.isEmpty ? s.name : s.surface, in: text) {
                marks.append(Mark(range: r, pending: false, index: i))
            }
        }
        for (i, s) in pending.enumerated() {
            if let r = AutoLinker.flexibleRange(of: s.surface.isEmpty ? s.name : s.surface, in: text) {
                marks.append(Mark(range: r, pending: true, index: i))
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
            if m.pending {
                chip.backgroundColor = Color.orange.opacity(0.30)
            } else {
                chip.foregroundColor = .blue
                chip.underlineStyle = .single
            }
            out += chip
            cursor = m.range.upperBound
        }
        if cursor < text.endIndex { out += AttributedString(String(text[cursor...])) }
        return out
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
}
