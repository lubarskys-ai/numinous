import SwiftUI
import UIKit
import NuminousCore

/// A tab that reads events across all your calendars. Tap any event to copy a diary
/// snippet (with [[people/…]] links) or drop it into today's diary — without spawning
/// a note per event.
struct CalendarView: View {
    @EnvironmentObject var model: AppModel

    enum LoadState {
        case loading, denied, loaded([CalendarEvent]), failed(String)
    }
    @State private var state: LoadState = .loading
    @State private var path: [UUID] = []
    @State private var showSubscribe = false
    @State private var showCalendars = false
    @State private var actionEvent: CalendarEvent?
    @State private var toast: String?
    @AppStorage("calendar_excluded_ids") private var excludedRaw = ""

    private var excludedIDs: Set<String> { Set(excludedRaw.split(separator: "\n").map(String.init)) }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Calendar")
                .navigationDestination(for: UUID.self) { id in NoteDetailView(noteID: id) }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button { showCalendars = true } label: { Label("Choose calendars", systemImage: "calendar") }
                            Button { showSubscribe = true } label: { Label("Subscribe to a feed", systemImage: "link.badge.plus") }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .sheet(isPresented: $showSubscribe) { CalendarSubscribeSheet() }
                .sheet(isPresented: $showCalendars, onDismiss: { Task { await load() } }) {
                    CalendarPickerSheet()
                }
                .task { await load() }
                .refreshable { await load() }
                .confirmationDialog("Add to your diary", isPresented: eventDialog, presenting: actionEvent) { event in
                    Button("Copy for diary") {
                        UIPasteboard.general.string = diarySnippet(event)
                        toast = "Copied — paste it into a diary entry."
                    }
                    Button("Add to \(Self.diaryDayLabel(event.start)) diary") {
                        model.appendToDiary(on: event.start, diarySnippet(event))
                        toast = "Added to \(Self.diaryDayLabel(event.start)) diary."
                    }
                    Button("Create a note", role: .none) { open(event) }
                    Button("Cancel", role: .cancel) {}
                } message: { event in
                    Text(diarySnippet(event))
                }
                // A lightweight overlay toast — NOT an .alert. Stacking .alert beneath the
                // .confirmationDialog on one view stopped the dialog from presenting, so
                // tapping an event did nothing and it "wouldn't add to the diary".
                .overlay(alignment: .bottom) { toastView }
                .task(id: toast) {
                    guard toast != nil else { return }
                    try? await Task.sleep(nanoseconds: 2_200_000_000)
                    withAnimation { toast = nil }
                }
                .animation(.easeInOut(duration: 0.25), value: toast)
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.secondary.opacity(0.2)))
                .shadow(radius: 8, y: 2)
                .padding(.bottom, 28)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var eventDialog: Binding<Bool> {
        Binding(get: { actionEvent != nil }, set: { if !$0 { actionEvent = nil } })
    }

    /// A diary-ready line for an event: title, who was there (as [[people/…]] links),
    /// time, and place — to paste into a diary entry or drop straight in.
    private func diarySnippet(_ e: CalendarEvent) -> String {
        var parts = [e.title]
        let people = e.attendees.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !people.isEmpty {
            parts.append("with " + people.map { "[[people/\($0)]]" }.joined(separator: ", "))
        }
        parts.append(Self.timeLabel(e))
        if let loc = e.location, !loc.isEmpty { parts.append("📍 \(loc)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView("Reading your calendar…")
        case .denied:
            emptyState("calendar.badge.exclamationmark", "Calendar access needed",
                       "Enable Calendar for Numinous in Settings to turn events into notes. Nothing is uploaded.")
        case .failed(let message):
            emptyState("exclamationmark.triangle", "Couldn't load calendar", message)
        case .loaded(let events):
            if events.isEmpty {
                emptyState("calendar", "No recent events", "Events from the last few weeks will show up here.")
            } else {
                eventList(events)
            }
        }
    }

    private func emptyState(_ icon: String, _ title: String, _ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func eventList(_ events: [CalendarEvent]) -> some View {
        let byDay = Dictionary(grouping: events) { Calendar.current.startOfDay(for: $0.start) }
        let days = byDay.keys.sorted()                    // past → future
        let today = Calendar.current.startOfDay(for: Date())
        let anchor = days.first { $0 >= today } ?? days.last   // today, or the next day with events
        return ScrollViewReader { proxy in
            List {
                ForEach(days, id: \.self) { day in
                    Section(Self.dayLabel(day)) {
                        ForEach(byDay[day] ?? []) { event in
                            Button { actionEvent = event } label: { row(event) }
                                .buttonStyle(.plain)
                        }
                    }
                    .id(day)
                }
            }
            .onAppear {
                guard let anchor else { return }
                DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
            }
        }
    }

    private func row(_ event: CalendarEvent) -> some View {
        let hasNote = model.noteID(forCalendarEvent: event.id) != nil
        return HStack(spacing: 12) {
            Circle().fill(Color(hex: event.calendarColorHex)).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title).font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text(Self.timeLabel(event)).font(.caption).foregroundStyle(.secondary)
                    Text("· \(event.calendarTitle)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let loc = event.location, !loc.isEmpty {
                    Text("📍 \(loc)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: hasNote ? "checkmark.circle.fill" : "plus.circle")
                .foregroundStyle(hasNote ? Color.accentColor : .secondary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func open(_ event: CalendarEvent) {
        if let id = model.createNote(from: event) { path.append(id) }
    }

    private func load() async {
        do {
            let events = try await CalendarService.fetchEvents(excluding: excludedIDs)
            state = .loaded(events)
        } catch CalendarService.CalError.accessDenied {
            state = .denied
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private static func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d"
        return f.string(from: date)
    }

    /// Possessive day label for the diary button — "today's" for today, else "Aug 12's" —
    /// so an event is filed under its OWN date's diary, not just today's.
    private static func diaryDayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "today's" }
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: date) + "'s"
    }

    private static func timeLabel(_ event: CalendarEvent) -> String {
        if event.isAllDay { return "All day" }
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
        return f.string(from: event.start)
    }
}

/// Subscribe to any public calendar feed (an .ics / webcal:// URL — TripIt,
/// a sports schedule, holidays, a shared Google/Outlook calendar). We hand the
/// URL to iOS, which subscribes and keeps it synced; its events then appear in
/// the Calendar tab like any other calendar.
struct CalendarSubscribeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var urlText = ""

    /// Any scheme (or none) is coerced to `webcal://` so iOS shows the subscribe prompt.
    private var subscribeURL: URL? {
        var s = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let range = s.range(of: "://") { s = String(s[range.upperBound...]) }
        return URL(string: "webcal://" + s)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…/calendar.ics or webcal://…", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Calendar URL")
                } footer: {
                    Text("Paste a public calendar link — e.g. your TripIt feed, a team schedule, or a shared calendar. iOS will ask you to subscribe; afterward, pull down to refresh and its events show up here.")
                }
                Section {
                    Button("Subscribe") { subscribe() }
                        .disabled(subscribeURL == nil)
                }
            }
            .navigationTitle("Subscribe to Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .alert("Couldn't subscribe", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }

    @State private var error: String?

    /// Hand the webcal URL to iOS and wait for the result — dismissing immediately
    /// (the old bug) could cancel the open, and failures were silent.
    private func subscribe() {
        guard let url = subscribeURL else { return }
        openURL(url) { accepted in
            if accepted { dismiss() }
            else { error = "iOS couldn't open that calendar link. Check the URL is a public .ics or webcal feed and try again." }
        }
    }
}

/// Choose which of your calendars feed the Calendar tab. Selections persist as an
/// "excluded ids" set so new calendars are included by default.
struct CalendarPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("calendar_excluded_ids") private var excludedRaw = ""
    @State private var calendars: [CalendarInfo] = []
    @State private var loading = true

    private var excluded: Set<String> {
        get { Set(excludedRaw.split(separator: "\n").map(String.init)) }
        nonmutating set { excludedRaw = newSet(newValue) }
    }
    private func newSet(_ s: Set<String>) -> String { s.sorted().joined(separator: "\n") }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Loading calendars…")
                } else if calendars.isEmpty {
                    Text("No calendars found.").foregroundStyle(.secondary)
                } else {
                    List(calendars) { cal in
                        Toggle(isOn: Binding(
                            get: { !excluded.contains(cal.id) },
                            set: { on in
                                var e = excluded
                                if on { e.remove(cal.id) } else { e.insert(cal.id) }
                                excluded = e
                            })) {
                            HStack(spacing: 10) {
                                Circle().fill(Color(hex: cal.colorHex)).frame(width: 10, height: 10)
                                Text(cal.title)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Calendars")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                calendars = (try? await CalendarService.availableCalendars()) ?? []
                loading = false
            }
        }
    }
}
