import SwiftUI
import NuminousCore

/// The Notes tab: a reverse-chronological **stream** of everything you've written
/// (grouped by day) when idle, and a full-text **search** across titles, paths,
/// bodies, and links the moment you type. Capture lives here too. This is the
/// time/flow view of your life; the Folders tab is the structural view.
struct NotesView: View {
    @EnvironmentObject var model: AppModel
    @State private var searchText = ""
    @State private var categoryFilter: String?
    @State private var compose: ComposeRequest?
    @State private var showReconnect = false
    @State private var importMessage: String?
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Notes")
                .navigationDestination(for: UUID.self) { NoteDetailView(noteID: $0) }
                .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Search notes, text, links")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button { categoryFilter = nil } label: {
                                if categoryFilter == nil { Label("All", systemImage: "checkmark") } else { Text("All") }
                            }
                            if !categories.isEmpty { Divider() }
                            ForEach(categories, id: \.self) { cat in
                                Button { categoryFilter = cat } label: {
                                    if categoryFilter == cat { Label(cat, systemImage: "checkmark") } else { Text(cat) }
                                }
                            }
                            Divider()
                            Button { importContacts() } label: { Label("Sync contacts", systemImage: "person.crop.circle.badge.plus") }
                        } label: {
                            Label(categoryFilter ?? "All", systemImage: "line.3.horizontal.decrease.circle")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showReconnect = true } label: { Image(systemName: "location.magnifyingglass") }
                            .accessibilityLabel("Reconnect near you")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button { compose = ComposeRequest() } label: {
                                Label("New note", systemImage: "square.and.pencil")
                            }
                            Button { compose = ComposeRequest(diary: true) } label: {
                                Label("Add to today's diary", systemImage: "calendar.badge.plus")
                            }
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityLabel("Add note")
                    }
                }
                .fullScreenCover(item: $compose) { req in ComposeView(prefillTitle: req.prefillTitle, diary: req.diary) }
                .sheet(isPresented: $showReconnect) { ReconnectView() }
                .alert("Contacts", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: { Text(importMessage ?? "") }
        }
    }

    @ViewBuilder
    private var content: some View {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            let sections = streamSections
            if sections.isEmpty { emptyStream } else { streamList(sections) }
        } else {
            let hits = matchingNotes(searchText)
            if hits.isEmpty { emptyResults } else { resultsList(hits) }
        }
    }

    // MARK: - Stream (reverse-chronological, grouped by day)

    private func streamList(_ sections: [DaySection]) -> some View {
        List {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.notes) { note in
                        NavigationLink(value: note.id) { NoteRow(note: note) }
                    }
                    .onDelete { offsets in model.delete(offsets.map { section.notes[$0] }) }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private struct DaySection: Identifiable { let id: Date; let title: String; let notes: [Note] }

    private var streamSections: [DaySection] {
        let cal = Calendar.current
        let engaged = model.notes.filter { !$0.isStub && matchesFilter($0) }
        let groups = Dictionary(grouping: engaged) { cal.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { day in
            DaySection(id: day, title: Self.dayTitle(day),
                       notes: groups[day]!.sorted { $0.date > $1.date })
        }
    }

    /// Top-level categories among your written notes (e.g. "notes", "diary",
    /// "golf clubs") — not the full nested folder/file structure.
    private var categories: [String] {
        var seen = Set<String>()
        for note in model.notes where !note.isStub && !note.folderName.isEmpty {
            seen.insert(note.folderName.split(separator: "/").first.map(String.init) ?? note.folderName)
        }
        return seen.sorted()
    }

    private func matchesFilter(_ note: Note) -> Bool {
        guard let f = categoryFilter?.lowercased() else { return true }
        let top = note.folderName.split(separator: "/").first.map(String.init)?.lowercased() ?? note.folderName.lowercased()
        return top == f
    }

    // MARK: - Search

    private func resultsList(_ hits: [Note]) -> some View {
        List(hits) { note in
            NavigationLink(value: note.id) { NoteRow(note: note) }
        }
        .listStyle(.plain)
    }

    /// Any note whose name, folder path, body, or `[[links]]` match — ranked so a
    /// name hit beats a body hit, newest first within a rank.
    private func matchingNotes(_ query: String) -> [Note] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        func rank(_ n: Note) -> Int {
            if n.displayName.lowercased().hasPrefix(q) { return 0 }
            if n.displayName.lowercased().contains(q) { return 1 }
            if n.folderName.lowercased().contains(q) { return 2 }
            if n.body.lowercased().contains(q) { return 3 }
            return 4
        }
        return model.notes.filter { n in
            n.displayName.lowercased().contains(q)
                || n.folderName.lowercased().contains(q)
                || n.body.lowercased().contains(q)
                || n.linkTargets.contains { $0.lowercased().contains(q) }
        }
        .sorted { a, b in
            let ra = rank(a), rb = rank(b)
            return ra != rb ? ra < rb : a.date > b.date
        }
    }

    // MARK: - Empty states

    private var emptyStream: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.secondary)
            Text("Your story starts here.").font(.headline)
            Text("Capture a moment — dictate or write — and it streams here by day.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyResults: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.title).foregroundStyle(.secondary)
            Text("No matches.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Formatting

    static func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = cal.isDate(day, equalTo: Date(), toGranularity: .year) ? "EEEE, MMMM d" : "MMMM d, yyyy"
        return f.string(from: day)
    }

    private func importContacts() {
        Task {
            do {
                let contacts = try await ContactsImporter.fetchContacts()
                let (added, updated) = model.importContacts(contacts)
                importMessage = contacts.isEmpty
                    ? "No contacts found on this device."
                    : "Synced \(added) new, updated \(updated) into your Contacts folder."
            } catch ContactsImporter.ImportError.accessDenied {
                importMessage = "Contacts access was declined. You can enable it in Settings → Numinous."
            } catch {
                importMessage = "Couldn't sync contacts: \(error.localizedDescription)"
            }
        }
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date())
    }
}

struct NoteRow: View {
    @EnvironmentObject var model: AppModel
    let note: Note

    var body: some View {
        let color = model.axis(for: note)?.color ?? Color.secondary
        return HStack(spacing: 12) {
            Image(systemName: note.isStub ? "circle.dashed" : "doc.text.fill")
                .font(.callout)
                .foregroundStyle(note.isStub ? Color.secondary.opacity(0.6) : color.opacity(0.85))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(note.displayName).font(.system(.body, design: .rounded).weight(.medium))
                if let snippet { Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                HStack(spacing: 6) {
                    Text(note.folderName.isEmpty ? "unfiled" : note.folderName)
                        .font(.caption2).foregroundStyle(.tertiary)
                    if !note.isStub {
                        Text("⚡ \(note.intensity)").font(.caption2).foregroundStyle(.secondary)
                        if let loc = note.location, !loc.isEmpty {
                            Text("📍 \(loc)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var snippet: String? {
        let t = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return t.replacingOccurrences(of: "\n", with: " ")
    }
}

/// Reconnect: who you know where you are — or where you're headed. Matches your current
/// location and upcoming trips (and a place you type) against the places on your people &
/// contacts, so you can reach out. Pull-based and gentle — no notifications.
struct ReconnectView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var locator = LocationService()

    @State private var nearby: [AppModel.ReconnectPrompt] = []
    @State private var trips: [AppModel.ReconnectPrompt] = []
    @State private var query = ""
    @State private var loading = true
    @State private var noFix = false
    @State private var openNote: Wrapped?

    private struct Wrapped: Identifiable { let id: UUID }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if loading {
                        HStack { ProgressView(); Text("Checking where you are…").foregroundStyle(.secondary) }
                    } else if !locator.isAuthorized {
                        Text("Allow location (used elsewhere in the app) to see who's near you now.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if noFix {
                        Text("Couldn't get your location just now. Try again, or check a place below.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if nearby.isEmpty {
                        Text("No one on file is near you right now.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(nearby) { promptRow($0) }
                    }
                } header: { Label("Near you now", systemImage: "location.fill") }

                Section {
                    TextField("A city or state — e.g. Charleston, SC", text: $query)
                        .textInputAutocapitalization(.words).autocorrectionDisabled()
                    ForEach(model.peopleAt(place: query, reason: "In \(query.trimmingCharacters(in: .whitespaces))")) { promptRow($0) }
                    if query.trimmingCharacters(in: .whitespaces).count >= 3
                        && model.peopleAt(place: query, reason: "").isEmpty {
                        Text("No one on file there yet.").font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Label("Planning a trip?", systemImage: "airplane") }
                  footer: { Text("Type where you're headed to see who you know there.") }

                if !trips.isEmpty {
                    Section {
                        ForEach(trips) { promptRow($0) }
                    } header: { Label("On your calendar", systemImage: "calendar") }
                }
            }
            .navigationTitle("Reconnect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await refresh() }
            .sheet(item: $openNote) { w in NavigationStack { NoteDetailView(noteID: w.id) } }
        }
    }

    private func promptRow(_ p: AppModel.ReconnectPrompt) -> some View {
        Button { openNote = Wrapped(id: p.id) } label: {
            HStack(spacing: 11) {
                Circle().fill(Color.pink.opacity(0.8)).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).foregroundStyle(.primary)
                    Text("\(p.reason)\(p.reason.isEmpty ? "" : " · ")\(p.place)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func refresh() async {
        loading = true
        if locator.isAuthorized {
            let place = await locator.currentPlace()   // has an internal timeout
            if let place { nearby = model.peopleAt(place: place, reason: "You're here now") }
            noFix = (place == nil)
        }
        loading = false   // stop the spinner after the location step — calendar loads on its own
        if let events = try? await CalendarService.fetchEvents(daysBack: 0, daysForward: 120) {
            trips = model.tripPrompts(from: events)
        }
    }
}
