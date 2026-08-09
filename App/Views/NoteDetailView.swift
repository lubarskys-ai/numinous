import SwiftUI
import PhotosUI
import NuminousCore

struct NoteDetailView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let noteID: UUID

    @State private var editedBody = ""
    @State private var loadedBodyFor: UUID?
    @State private var editingBody = false           // reading (rendered links) vs raw editing
    @State private var openLinkTarget: LinkTarget?   // a tapped rendered link to open
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFollowUp = false
    @State private var followUpMessage: String?
    @State private var titleDraft = ""
    @State private var findLinksNote: Note?          // presents the composer's Find-links flow
    @State private var hasTripRange = false          // travel notes: is a trip date range set?
    @State private var tripStart = Date()
    @State private var tripEnd = Date()

    private struct LinkTarget: Identifiable { let id: UUID }

    var body: some View {
        if let note = model.note(id: noteID) {
            List {
                titleSection(note)
                headerSection(note)
                if isTrip(note) { tripSection(note) }
                if isRecord(note) {
                    // A logged activity (workout, mindful, nutrition) — keep it simple:
                    // your own note, plus the one useful connection ("who were you with").
                    bodySection(note, label: "Notes", minHeight: 70)
                    suggestionsSection(note)
                } else if isEntity(note) {
                    // A thing you relate to (person, place, concept) — lead with its
                    // web of connections; your own notes are secondary.
                    linkedFromSection(note)
                    linksToSection(note)
                    suggestionsSection(note)
                    bodySection(note, label: "Notes", minHeight: 70)
                    reminderSection
                } else {
                    // A journal entry — your writing comes first.
                    bodySection(note, label: "Note", minHeight: 130)
                    reminderSection
                    suggestionsSection(note)
                    linksToSection(note)
                    linkedFromSection(note)
                }
                photosSection(note)
                deleteSection(note)
            }
            .navigationTitle(note.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if loadedBodyFor != note.id {
                    editedBody = note.body; titleDraft = note.title; loadedBodyFor = note.id
                    editingBody = note.body.isEmpty   // start reading unless there's nothing yet
                    if let range = model.tripRange(note.id) {
                        hasTripRange = true; tripStart = range.start; tripEnd = range.end
                    } else {
                        hasTripRange = false
                    }
                }
            }
            .sheet(item: $openLinkTarget) { t in
                NavigationStack { NoteDetailView(noteID: t.id) }
            }
            .fullScreenCover(item: $findLinksNote, onDismiss: {
                if let fresh = model.note(id: noteID) { editedBody = fresh.body }
            }) { n in
                ComposeView(editing: n)
            }
            .onDisappear {
                // Autosave on leave so edits (and links) persist without a manual Save.
                if editedBody != note.body { model.updateBody(note.id, body: editedBody) }
                commitRename(note)
            }
            .onChange(of: photoItems) { items in
                guard !items.isEmpty else { return }
                Task {
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            model.addPhoto(to: note.id, data: data)
                        }
                    }
                    photoItems = []
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if editedBody != note.body { model.updateBody(note.id, body: editedBody) }
                        commitRename(note)
                        dismiss()
                    }
                    .disabled(editedBody == note.body && titleDraft.trimmingCharacters(in: .whitespaces) == note.title)
                }
            }
            .sheet(isPresented: $showFollowUp) {
                FollowUpSheet(noteTitle: note.title, defaultTitle: defaultFollowUpTitle(note)) { message in
                    followUpMessage = message
                }
            }
            .alert("Follow-up", isPresented: Binding(get: { followUpMessage != nil },
                                                     set: { if !$0 { followUpMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(followUpMessage ?? "") }
        } else {
            Text("This note no longer exists.").foregroundStyle(.secondary)
        }
    }

    // MARK: - Entry vs entity

    /// A journal entry is titled by date; everything else — people, places, and
    /// concepts like history/1860s — is an entity we relate to, shown
    /// connections-first (links & relations) rather than as a writing surface.
    private func isEntity(_ note: Note) -> Bool { !Self.isDateTitled(note.displayName) }
    /// A logged health record — gets a stripped-down detail view, not the CRM layout.
    private func isRecord(_ note: Note) -> Bool { note.origin?.source == "healthkit" }
    /// A travel note — can carry a trip date range that auto-links diary entries.
    private func isTrip(_ note: Note) -> Bool { AppModel.isTravelNote(note.folderName) }
    private static func isDateTitled(_ name: String) -> Bool {
        name.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil
    }

    // MARK: - Sections

    @ViewBuilder
    private func titleSection(_ note: Note) -> some View {
        Section {
            TextField("folder/Name", text: $titleDraft)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { commitRename(note) }
        } footer: {
            Text("Edit the folder or name — links to this note follow it everywhere.")
        }
    }

    @ViewBuilder
    private func headerSection(_ note: Note) -> some View {
        Section {
            if note.origin?.source == "readwise" { bookHeader(note) }
            if let folder = model.folder(named: note.folderName) {
                let axis = model.axis(id: folder.axisID)
                HStack(spacing: 8) {
                    Circle().fill(axis?.color ?? .secondary).frame(width: 8, height: 8)
                    Text(folder.name).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if let axis {
                        Text(axis.name).font(.caption).foregroundStyle(axis.color)
                    }
                    if !note.isStub {
                        Text("· ⚡\(note.intensity)").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            if isEntity(note) && !isRecord(note) { entitySummary(note) }
            if let loc = note.location, !loc.isEmpty {
                LabeledContent("Location", value: loc)
            }
            if note.origin?.source == "readwise" {
                Toggle(isOn: Binding(get: { !note.isStub },
                                     set: { model.setFinished(note.id, $0) })) {
                    Label(note.isStub ? "Mark as finished" : "Finished reading",
                          systemImage: note.isStub ? "book.closed" : "checkmark.seal.fill")
                }
                .tint(.green)
                if note.isStub {
                    Text("A book grows Mind only once you finish it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if note.isStub {
                Label("Dormant — write about it or add a [[link]] to start growing.",
                      systemImage: "moon.zzz")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if note.origin?.source == "healthkit" {
                Label("Verified activity", systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            if note.origin?.source == "followup" {
                Label("Followed through", systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.green)
            }
        }
    }

    /// Trip date range for a travel note. When set, any diary entry dated within the
    /// range automatically links to this trip.
    @ViewBuilder
    private func tripSection(_ note: Note) -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { hasTripRange },
                set: { on in
                    hasTripRange = on
                    if on { model.setTripRange(note.id, start: tripStart, end: tripEnd) }
                    else { model.setTripRange(note.id, start: nil, end: nil) }
                }
            )) {
                Label("These are trip dates", systemImage: "airplane")
            }
            if hasTripRange {
                DatePicker("Start", selection: Binding(
                    get: { tripStart },
                    set: { tripStart = $0; if tripEnd < $0 { tripEnd = $0 }
                           model.setTripRange(note.id, start: tripStart, end: tripEnd) }
                ), displayedComponents: .date)
                DatePicker("End", selection: Binding(
                    get: { tripEnd },
                    set: { tripEnd = $0; if tripStart > $0 { tripStart = $0 }
                           model.setTripRange(note.id, start: tripStart, end: tripEnd) }
                ), in: tripStart..., displayedComponents: .date)
            }
        } header: {
            Text("Trip")
        } footer: {
            Text(hasTripRange
                 ? "Diary entries dated within these days automatically link to this trip."
                 : "Turn on to mark a start–end date range. Diary entries during a trip link here on their own.")
        }
    }

    @ViewBuilder
    private func suggestionsSection(_ note: Note) -> some View {
        let suggestions = model.connectionSuggestions(for: note)
        if !suggestions.isEmpty {
            Section {
                ForEach(suggestions) { suggestion in
                    let candidate = suggestion.note
                    HStack(spacing: 10) {
                        Circle().fill(model.axis(for: candidate)?.color ?? .gray).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(candidate.displayName)
                            Text(suggestion.reason)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Link") { link(to: candidate.title) }
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Suggested connections")
            } footer: {
                Text("People and moments from around this time. Linking one connects it into your web.")
            }
        }
    }

    @ViewBuilder
    private func bodySection(_ note: Note, label: String, minHeight: CGFloat) -> some View {
        Section {
            if editingBody {
                LinkingEditor(text: $editedBody, minHeight: minHeight,
                              onCommit: { model.updateBody(note.id, body: $0) })
                HStack {
                    Text("Type [[ or tap Link to connect a note.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") {
                        model.updateBody(note.id, body: editedBody)
                        editingBody = false
                    }.font(.callout.weight(.medium))
                }
            } else {
                Text(renderedBody(editedBody))
                    .frame(maxWidth: .infinity, minHeight: minHeight * 0.5, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.openURL, OpenURLAction { url in openBodyLink(url); return .handled })
                    .contentShape(Rectangle())
                    .onTapGesture { editingBody = true }   // tap the text to edit (cursor)
            }
        } header: {
            HStack(spacing: 14) {
                Text(label)
                Spacer()
                if editedBody.trimmingCharacters(in: .whitespaces).count >= 3 {
                    Button {
                        // Save any in-progress edits first so the scan sees the latest text.
                        if editedBody != note.body { model.updateBody(note.id, body: editedBody) }
                        findLinksNote = model.note(id: note.id)
                    } label: { Label("Find links", systemImage: "sparkles").font(.caption) }
                }
                if !editingBody {
                    Button { editingBody = true } label: { Label("Edit", systemImage: "pencil").font(.caption) }
                }
            }
        }
    }

    /// The body with `[[folder/Name]]` rendered as bracket-less, axis-colored, underlined
    /// tappable links; a tap opens that note. Plain text passes through unchanged.
    private func renderedBody(_ body: String) -> AttributedString {
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var empty = AttributedString("Empty — tap to write.")
            empty.foregroundColor = .secondary
            return empty
        }
        let ns = body as NSString
        guard let re = try? NSRegularExpression(pattern: #"\[\[([^\]]+)\]\]"#) else { return AttributedString(body) }
        var out = AttributedString()
        var last = 0
        for m in re.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last {
                out += AttributedString(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            }
            let raw = ns.substring(with: m.range(at: 1))
            let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
            let target = parts.first?.trimmingCharacters(in: .whitespaces) ?? raw
            let display = parts.count > 1 ? parts[1] : leafName(target)
            var chip = AttributedString(display)
            chip.foregroundColor = axisColor(forTarget: target)
            chip.underlineStyle = .single
            if let enc = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
                chip.link = URL(string: "numinous-open:\(enc)")
            }
            out += chip
            last = m.range.location + m.range.length
        }
        if last < ns.length { out += AttributedString(ns.substring(from: last)) }
        return out
    }

    private func openBodyLink(_ url: URL) {
        guard url.scheme == "numinous-open" else { return }
        let encoded = String(url.absoluteString.dropFirst("numinous-open:".count))
        let target = (encoded.removingPercentEncoding ?? encoded).lowercased()
        if let hit = model.notes.first(where: { $0.title.lowercased() == target }) {
            openLinkTarget = LinkTarget(id: hit.id)
        }
    }

    private func axisColor(forTarget target: String) -> Color {
        guard let slash = target.lastIndex(of: "/") else { return .accentColor }
        let folder = String(target[..<slash])
        return model.axis(id: model.folder(named: folder)?.axisID ?? "")?.color ?? .accentColor
    }

    private func leafName(_ target: String) -> String {
        guard let slash = target.lastIndex(of: "/") else { return target }
        return String(target[target.index(after: slash)...])
    }

    @ViewBuilder
    private var reminderSection: some View {
        Section {
            Button { showFollowUp = true } label: {
                Label("Remind me to follow up…", systemImage: "bell.badge")
            }
        }
    }

    @ViewBuilder
    private func linksToSection(_ note: Note) -> some View {
        Section(isEntity(note) ? "Connects to" : "Links to") {
            let targets = note.linkTargets
            if targets.isEmpty {
                Text("No links yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(targets, id: \.self) { target in
                    if let other = model.note(titled: target) {
                        NavigationLink(value: other.id) { linkLabel(other) }
                    } else {
                        Label(target + " · new", systemImage: "plus.circle").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func linkedFromSection(_ note: Note) -> some View {
        let back = model.backlinks(to: note)
        if isEntity(note) {
            if back.isEmpty {
                Section("Mentioned in") {
                    Text("Nothing links here yet.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                // Grouped by life area so you see how this connects across your world.
                ForEach(backlinksByAxis(back), id: \.axisID) { group in
                    Section {
                        ForEach(group.notes) { b in NavigationLink(value: b.id) { linkLabel(b) } }
                    } header: {
                        HStack(spacing: 6) {
                            Circle().fill(group.color).frame(width: 7, height: 7)
                            Text("Mentioned in · \(group.name)")
                        }
                    }
                }
            }
        } else {
            Section("Linked from") {
                if back.isEmpty {
                    Text("Nothing links here yet.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(back) { b in NavigationLink(value: b.id) { linkLabel(b) } }
                }
            }
        }
    }

    /// A one-line "N connections across these areas" summary with axis dots.
    @ViewBuilder
    private func entitySummary(_ note: Note) -> some View {
        let total = model.backlinks(to: note).count + note.linkTargets.count
        if total > 0 {
            HStack(spacing: 8) {
                Image(systemName: "link").font(.caption).foregroundStyle(.secondary)
                Text("^[\(total) connection](inflect: true)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 3) {
                    ForEach(connectedAxisIDs(note), id: \.self) { id in
                        Circle().fill(model.axis(id: id)?.color ?? .secondary).frame(width: 7, height: 7)
                    }
                }
            }
        }
    }

    private struct AxisGroup { let axisID: String; let name: String; let color: Color; let notes: [Note] }

    /// Backlinks bucketed by the axis of the note doing the linking, in axis order.
    private func backlinksByAxis(_ back: [Note]) -> [AxisGroup] {
        var byAxis: [String: [Note]] = [:]
        for n in back { byAxis[model.axis(for: n)?.id ?? "_none", default: []].append(n) }
        var out = model.axes.compactMap { axis -> AxisGroup? in
            guard let notes = byAxis[axis.id] else { return nil }
            return AxisGroup(axisID: axis.id, name: axis.name, color: axis.color, notes: notes)
        }
        if let none = byAxis["_none"] {
            out.append(AxisGroup(axisID: "_none", name: "Other", color: .secondary, notes: none))
        }
        return out
    }

    /// Distinct axes this note touches (its backlinks + what it links to), axis order.
    private func connectedAxisIDs(_ note: Note) -> [String] {
        var ids = Set<String>()
        for n in model.backlinks(to: note) { if let a = model.axis(for: n)?.id { ids.insert(a) } }
        for t in note.linkTargets {
            if let other = model.note(titled: t), let a = model.axis(for: other)?.id { ids.insert(a) }
        }
        return model.axes.map(\.id).filter { ids.contains($0) }
    }

    @ViewBuilder
    private func photosSection(_ note: Note) -> some View {
        // A book already has its cover; no photo picker needed.
        if note.origin?.source != "readwise" {
            Section("Photos") {
                let photos = note.photos ?? []
                if !photos.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(photos, id: \.self) { name in
                                if let image = ImageStore.load(name) {
                                    Image(uiImage: image)
                                        .resizable().scaledToFill()
                                        .frame(width: 84, height: 84)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .overlay(alignment: .topTrailing) {
                                            Button {
                                                model.removePhoto(from: note.id, name: name)
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundStyle(.white, .black.opacity(0.5))
                                            }
                                            .padding(3)
                                        }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                PhotosPicker(selection: $photoItems, maxSelectionCount: 10, matching: .images) {
                    Label("Add photos", systemImage: "photo.badge.plus")
                }
            }
        }
    }

    @ViewBuilder
    private func deleteSection(_ note: Note) -> some View {
        Section {
            Button("Delete note", role: .destructive) {
                model.delete([note]); dismiss()
            }
        }
    }

    // MARK: - Helpers

    /// A sensible default reminder title — person-aware ("Call Sam").
    private func defaultFollowUpTitle(_ note: Note) -> String {
        Folder.normalize(note.folderName) == "people"
            ? "Call \(note.displayName)"
            : "Follow up: \(note.displayName)"
    }

    /// Apply an inline title edit as a rename/move that follows every link.
    private func commitRename(_ note: Note) {
        let t = titleDraft.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != note.title else { return }
        model.renameNote(note.id, to: t)
    }

    private func link(to title: String) {
        let sep = editedBody.isEmpty || editedBody.hasSuffix("\n") || editedBody.hasSuffix(" ") ? "" : " "
        editedBody += sep + "[[\(title)]]"
        model.updateBody(noteID, body: editedBody)
    }

    private func linkLabel(_ note: Note) -> some View {
        HStack(spacing: 10) {
            Circle().fill(model.axis(for: note)?.color ?? Color.gray.opacity(0.4)).frame(width: 8, height: 8)
            Text(note.title)
        }
    }

    /// Cover + author + highlight count for an imported book (Readwise metadata).
    @ViewBuilder
    private func bookHeader(_ note: Note) -> some View {
        let author = note.details.first { $0.key == "Author" }?.value
        let cover = note.details.first { $0.key == "Cover" }?.value
        let highlightCount = note.body.split(separator: "\n").filter { $0.hasPrefix("> ") }.count
        HStack(spacing: 14) {
            Group {
                if let cover, let url = URL(string: cover) {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.secondary.opacity(0.12)
                    }
                } else {
                    Color.secondary.opacity(0.12)
                        .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
                }
            }
            .frame(width: 58, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.08)))

            VStack(alignment: .leading, spacing: 4) {
                Text(note.displayName).font(.headline)
                if let author { Text("by \(author)").font(.subheadline).foregroundStyle(.secondary) }
                if highlightCount > 0 {
                    Label("\(highlightCount) highlights", systemImage: "quote.opening")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}
