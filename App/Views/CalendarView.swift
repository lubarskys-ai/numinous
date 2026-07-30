import SwiftUI
import NuminousCore

/// A tab that reads events across all your calendars. Tap any event to turn it
/// into a note (pre-filled with its date, location, and [[people/…]] links).
struct CalendarView: View {
    @EnvironmentObject var model: AppModel

    enum LoadState {
        case loading, denied, loaded([CalendarEvent]), failed(String)
    }
    @State private var state: LoadState = .loading
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Calendar")
                .navigationDestination(for: UUID.self) { id in NoteDetailView(noteID: id) }
                .task { await load() }
                .refreshable { await load() }
        }
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
        let days = byDay.keys.sorted(by: >)
        return List {
            ForEach(days, id: \.self) { day in
                Section(Self.dayLabel(day)) {
                    ForEach(byDay[day] ?? []) { event in
                        Button { open(event) } label: { row(event) }
                            .buttonStyle(.plain)
                    }
                }
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
            let events = try await CalendarService.fetchEvents()
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

    private static func timeLabel(_ event: CalendarEvent) -> String {
        if event.isAllDay { return "All day" }
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
        return f.string(from: event.start)
    }
}
