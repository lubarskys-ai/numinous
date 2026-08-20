import SwiftUI
import PhotosUI
import MapKit
import NuminousCore

struct NoteDetailView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let noteID: UUID

    @State private var editedBody = ""
    @State private var loadedBodyFor: UUID?
    @State private var openLinkTarget: LinkTarget?   // a tapped rendered link to open
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFollowUp = false
    @State private var followUpMessage: String?
    @State private var titleDraft = ""
    @State private var showPlacePicker = false        // presents the searchable place-list picker
    @State private var newGenreForNote: UUID?         // book id awaiting a typed new genre
    @State private var newGenreDraft = ""
    @State private var fullEditNote: Note?           // presents the full-screen composer for editing / find-links
    @State private var editAutofocus = false         // put the keyboard up when opened by tapping to edit
    @State private var hasTripRange = false          // travel notes: is a trip date range set?
    @State private var tripStart = Date()
    @State private var tripEnd = Date()
    @State private var editingLocation = false
    @State private var locationDraft = ""
    @State private var editingPlace: PlaceRef?
    @StateObject private var locator = LocationService()

    private struct LinkTarget: Identifiable { let id: UUID }
    private struct PlaceRef: Identifiable { let id = UUID(); let place: Place }

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
            .alert("Add a place", isPresented: $editingLocation) {
                TextField("Where were you?", text: $locationDraft)
                Button("Cancel", role: .cancel) {}
                Button("Add") { addTypedPlace(to: note.id, name: locationDraft) }
            } message: { Text("Add a place to this note. You can add more than one.") }
            .sheet(item: $editingPlace) { ref in
                PlaceEditorView(noteID: note.id, place: ref.place)
            }
            .sheet(isPresented: $showPlacePicker) {
                PlacePickerView { r in
                    model.linkPlace(model.ensurePlaceNote(name: r.name, latitude: r.latitude, longitude: r.longitude), into: note.id)
                    refreshBody(note.id)
                }
            }
            .alert("New genre", isPresented: Binding(get: { newGenreForNote != nil }, set: { if !$0 { newGenreForNote = nil } })) {
                TextField("Genre — e.g. Thriller", text: $newGenreDraft)
                Button("Cancel", role: .cancel) {}
                Button("Add") { if let id = newGenreForNote { applyGenre(id, to: newGenreDraft) } }
            }
            .onAppear {
                if loadedBodyFor != note.id {
                    editedBody = note.body; titleDraft = note.title; loadedBodyFor = note.id
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
            .fullScreenCover(item: $fullEditNote, onDismiss: {
                editAutofocus = false
                if let fresh = model.note(id: noteID) { editedBody = fresh.body }
            }) { n in
                ComposeView(editing: n, autofocus: editAutofocus)
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.avatarFocus = AvatarFocus(label: note.displayName, ids: [note.id], expandNeighbors: true) } label: {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                    }
                    .accessibilityLabel("See this note's connections in the graph")
                }
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
    /// A `books/genre/…` note — a shelf whose books link to it; shown as a plain book list.
    private func isGenreNote(_ note: Note) -> Bool { Folder.normalize(note.folderName) == "books/genre" }
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
            // A 1–5 star rating for things you evaluate (books, restaurants, wine, films).
            if AppModel.isRateableFolder(note.folderName) {
                StarRating(rating: note.rating) { model.setRating(note.id, to: $0) }
            }
            // Pick a genre for a book (existing or new) — groups it under books/genre/…
            if AppModel.isBookFolder(note.folderName) {
                genreRow(note)
            }
            // Date the entry actually belongs to — change it to backdate a diary entry so
            // it sorts under the day it happened, not the day you typed it. Shown for
            // journal entries and logged records, not for people/places/books.
            if !isEntity(note) {
                DatePicker(
                    "Date",
                    selection: Binding(
                        get: { note.date },
                        set: { newDate in
                            // Flush any in-progress body edit first, so re-syncing below
                            // (a backdate can retitle the note and add a trip link) can't
                            // clobber unsaved text.
                            if editedBody != note.body { model.updateBody(note.id, body: editedBody) }
                            model.setNoteDate(note.id, to: newDate)
                            if let fresh = model.note(id: note.id) {
                                titleDraft = fresh.title
                                editedBody = fresh.body
                            }
                        }
                    ),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .font(.subheadline)
            }
            if !AppModel.isBookFolder(note.folderName) { locationRows(note) }
            // Every book — however it was imported (Readwise or the Obsidian vault) — gets the
            // read toggle. A book grows Mind only once you finish it.
            if AppModel.isBookFolder(note.folderName) {
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

    /// The note's places — one row each (with a delete), plus an add control. A note can
    /// hold several places; coordinates (from GPS, or geocoded from a typed name) are kept
    /// so these can later be plotted on a map.
    @ViewBuilder
    private func locationRows(_ note: Note) -> some View {
        ForEach(note.allPlaces, id: \.name) { place in
            HStack(spacing: 6) {
                Button { editingPlace = PlaceRef(place: place) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: place.hasCoordinate ? "mappin.circle.fill" : "mappin.and.ellipse")
                            .foregroundStyle(place.hasCoordinate ? Color.secondary : Color.orange)
                        Text(place.name).foregroundStyle(.primary)
                        Spacer()
                        Text(place.hasCoordinate ? "" : "set on map")
                            .font(.caption2).foregroundStyle(.orange)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    model.removePlace(note.id, name: place.name)
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(place.name)")
            }
        }
        Menu {
            Button { showPlacePicker = true } label: {
                Label("Search for a place…", systemImage: "magnifyingglass")
            }
            Button { locationDraft = ""; editingLocation = true } label: {
                Label("Enter a place name", systemImage: "mappin")
            }
            Button {
                Task { await model.captureCurrentPlace(into: note.id); refreshBody(note.id) }   // GPS → place note + pin + body link
            } label: {
                Label("Use current location", systemImage: "location.fill")
            }
        } label: {
            Label(note.allPlaces.isEmpty ? "Add location" : "Add another location", systemImage: "plus.circle")
                .foregroundStyle(.tint)
        }
    }

    /// Geocode a typed place name and weave it into the note as a mappable, linked place —
    /// entered once, it becomes note text, a graph node, and a map pin.
    private func addTypedPlace(to id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task { await model.attachPlaceByName(trimmed, into: id); refreshBody(id) }
    }

    /// Re-sync the editable body buffer after a model action rewrote the note body (adding a
    /// place link), so it shows and the on-leave autosave doesn't clobber it.
    private func refreshBody(_ id: UUID) {
        if let fresh = model.note(id: id) { editedBody = fresh.body }
    }

    @ViewBuilder
    private func bodySection(_ note: Note, label: String, minHeight: CGFloat) -> some View {
        Section {
            if editedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Tap to write…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: minHeight * 0.5, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onTapGesture { openFullEditor(note) }
            } else {
                // Reading mode: tappable links; tapping the text opens the full-screen editor.
                Text(renderedBody(editedBody))
                    .frame(maxWidth: .infinity, minHeight: minHeight * 0.5, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.openURL, OpenURLAction { url in openBodyLink(url); return .handled })
                    .contentShape(Rectangle())
                    .onTapGesture { openFullEditor(note) }
            }
        } header: {
            HStack(spacing: 14) {
                Text(label)
                Spacer()
                if editedBody.trimmingCharacters(in: .whitespaces).count >= 3 {
                    Button { openFullEditor(note) } label: { Label("Find links", systemImage: "sparkles").font(.caption) }
                }
                Button { openFullEditor(note) } label: { Label("Edit", systemImage: "pencil").font(.caption) }
            }
        }
    }

    /// A genre picker for a book: choose an existing genre, add a new one, or clear it.
    /// Set a book's genre AND refresh the local edit buffer. `setBookGenre` rewrites the
    /// note body (it appends the `[[books/genre/…]]` link), so without this the view's stale
    /// `editedBody` would be written back on disappear and wipe the genre out.
    private func applyGenre(_ id: UUID, to genre: String?) {
        model.setBookGenre(id, to: genre)
        if let fresh = model.note(id: id) { editedBody = fresh.body }
    }

    @ViewBuilder private func genreRow(_ note: Note) -> some View {
        let current = model.genre(of: note)
        Menu {
            ForEach(model.existingGenres(), id: \.self) { g in
                Button { applyGenre(note.id, to: g) } label: {
                    if current?.caseInsensitiveCompare(g) == .orderedSame { Label(g, systemImage: "checkmark") } else { Text(g) }
                }
            }
            Divider()
            Button { newGenreDraft = ""; newGenreForNote = note.id } label: { Label("New genre…", systemImage: "plus") }
            if current != nil {
                Button(role: .destructive) { applyGenre(note.id, to: nil) } label: { Label("Clear genre", systemImage: "xmark") }
            }
        } label: {
            HStack(spacing: 8) {
                Label("Genre", systemImage: "books.vertical").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(current ?? "Choose…").foregroundStyle(current == nil ? .secondary : .primary)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// Editing the substance of a note happens in the full-screen composer (roomy editor +
    /// linking), not a cramped inline box — opened by tapping the body, Edit, or Find links.
    private func openFullEditor(_ note: Note) {
        if editedBody != note.body { model.updateBody(note.id, body: editedBody) }
        editAutofocus = true
        fullEditNote = model.note(id: note.id)
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
        if isGenreNote(note) {
            // A genre note is a shelf: list the books tagged with it, plainly.
            Section(back.isEmpty ? "Books" : "^[\(back.count) book](inflect: true) in this genre") {
                if back.isEmpty {
                    Text("No books tagged with this genre yet.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(back) { b in NavigationLink(value: b.id) { linkLabel(b) } }
                }
            }
        } else if isEntity(note) {
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

/// A tappable 1–5 star row. Tapping a star sets that rating; tapping the current
/// rating again clears it back to unrated.
struct StarRating: View {
    let rating: Int?
    var onChange: (Int?) -> Void

    var body: some View {
        HStack {
            Label("Rating", systemImage: "star.leadinghalf.filled")
                .font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { i in
                    Image(systemName: (rating ?? 0) >= i ? "star.fill" : "star")
                        .font(.body)
                        .foregroundStyle((rating ?? 0) >= i ? Color.yellow : Color.secondary.opacity(0.4))
                        .contentShape(Rectangle())
                        .onTapGesture { onChange(rating == i ? nil : i) }
                        .accessibilityLabel("\(i) star\(i == 1 ? "" : "s")")
                }
            }
        }
    }
}

/// Correct where a place sits when a geocode is wrong: tap the map to move the pin to the
/// right spot, re-search the name, or use your current location. Saves the corrected name
/// + coordinate back to the note.
struct PlaceEditorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let noteID: UUID
    let place: Place

    @State private var name: String
    @State private var coord: CLLocationCoordinate2D?
    @State private var position: MapCameraPosition
    @StateObject private var locator = LocationService()

    init(noteID: UUID, place: Place) {
        self.noteID = noteID
        self.place = place
        _name = State(initialValue: place.name)
        if let lat = place.latitude, let lng = place.longitude {
            let c = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            _coord = State(initialValue: c)
            _position = State(initialValue: .region(MKCoordinateRegion(center: c, latitudinalMeters: 4000, longitudinalMeters: 4000)))
        } else {
            _coord = State(initialValue: nil)
            _position = State(initialValue: .automatic)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "mappin.and.ellipse").foregroundStyle(.secondary)
                    TextField("Place name", text: $name)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await search() } }
                    Button { Task { await search() } } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("Search this name")
                    Button { Task { await useCurrent() } } label: { Image(systemName: "location.fill") }
                        .accessibilityLabel("Use current location")
                }
                .padding(12)
                Divider()
                MapReader { proxy in
                    Map(position: $position) {
                        if let coord {
                            Marker(name.isEmpty ? "Here" : name, coordinate: coord).tint(.red)
                        }
                    }
                    .onTapGesture { pt in
                        if let c = proxy.convert(pt, from: .local) { coord = c }
                    }
                }
                .overlay(alignment: .bottom) {
                    Text(coord == nil ? "Tap the map to drop a pin where this was."
                                      : "Tap the map to move the pin to the right spot.")
                        .font(.caption).padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 14)
                }
            }
            .navigationTitle("Fix location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    /// Find the typed name (business/restaurant via MKLocalSearch, else a plain address)
    /// and center the pin there.
    private func search() async {
        var near = coord
        if near == nil { near = await locator.currentCoordinate() }
        var cc: CLLocationCoordinate2D?
        if let hit = await LocationService.searchPlace(name, near: near) {
            cc = CLLocationCoordinate2D(latitude: hit.latitude, longitude: hit.longitude)
        } else if let c = await LocationService.coordinate(for: name, near: near) {
            cc = CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
        }
        guard let cc else { return }
        coord = cc
        position = .region(MKCoordinateRegion(center: cc, latitudinalMeters: 2000, longitudinalMeters: 2000))
    }

    private func useCurrent() async {
        guard let p = await locator.currentPlaceStructured(), let lat = p.latitude, let lng = p.longitude else { return }
        let cc = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        coord = cc
        if name.trimmingCharacters(in: .whitespaces).isEmpty { name = p.name }
        position = .region(MKCoordinateRegion(center: cc, latitudinalMeters: 2000, longitudinalMeters: 2000))
    }

    private func save() {
        model.updatePlace(noteID, original: place.name, name: name,
                          latitude: coord?.latitude, longitude: coord?.longitude)
        dismiss()
    }
}

/// One result in the place picker.
struct PlaceSearchResult: Identifiable {
    let id = UUID()
    let name: String
    let subtitle: String
    let latitude: Double
    let longitude: Double
}

/// A searchable LIST of matching places (name or address) to choose from — so an ambiguous
/// name (many "Starbucks") resolves to the right one instead of auto-taking the nearest.
struct PlacePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var locator = LocationService()
    let onPick: (PlaceSearchResult) -> Void

    @State private var query = ""
    @State private var results: [PlaceSearchResult] = []
    @State private var searching = false
    @State private var didSearch = false

    var body: some View {
        NavigationStack {
            List {
                if searching {
                    HStack(spacing: 10) { ProgressView(); Text("Searching…").foregroundStyle(.secondary) }
                }
                ForEach(results) { r in
                    Button { onPick(r); dismiss() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "mappin.circle.fill").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.name).foregroundStyle(.primary)
                                if !r.subtitle.isEmpty {
                                    Text(r.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if didSearch, !searching, results.isEmpty {
                    Text("No places found for “\(query)”. Try a different name, or add it by address.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search a place — name or address")
            .autocorrectionDisabled()
            .task(id: query) {
                let q = query.trimmingCharacters(in: .whitespaces)
                guard q.count >= 2 else { results = []; didSearch = false; return }
                try? await Task.sleep(nanoseconds: 350_000_000)   // debounce
                guard !Task.isCancelled else { return }
                searching = true; didSearch = true
                let near = await locator.currentCoordinate()
                let hits = await LocationService.searchPlaces(q, near: near)
                guard !Task.isCancelled else { return }
                results = hits.map { PlaceSearchResult(name: $0.name, subtitle: $0.subtitle,
                                                       latitude: $0.latitude, longitude: $0.longitude) }
                searching = false
            }
            .navigationTitle("Add location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
