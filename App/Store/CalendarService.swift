import Foundation
import EventKit
import UIKit

/// A calendar event, flattened from EventKit into a Sendable value.
struct CalendarEvent: Identifiable, Sendable {
    let id: String              // event identifier (stable) — used as import externalID
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    let calendarTitle: String   // which calendar it came from (supports many)
    let calendarColorHex: String
    let attendees: [String]     // attendee display names
}

/// A selectable calendar (source), flattened for the picker UI.
struct CalendarInfo: Identifiable, Sendable {
    let id: String          // calendarIdentifier
    let title: String
    let colorHex: String
}

/// Reads events across your calendars (with permission). On-device; nothing is
/// uploaded — events only become notes when you tap them. You choose which
/// calendars to include (via an "excluded ids" set the UI persists).
enum CalendarService {

    enum CalError: Error { case accessDenied }

    private static func ensureAccess(_ store: EKEventStore) async throws -> Bool {
        if #available(iOS 17.0, *) {
            return try await store.requestFullAccessToEvents()
        } else {
            return try await withCheckedThrowingContinuation { cont in
                store.requestAccess(to: .event) { ok, error in
                    if let error { cont.resume(throwing: error) } else { cont.resume(returning: ok) }
                }
            }
        }
    }

    /// Every event calendar available to the user, for the selection UI.
    static func availableCalendars() async throws -> [CalendarInfo] {
        let store = EKEventStore()
        guard try await ensureAccess(store) else { throw CalError.accessDenied }
        return store.calendars(for: .event)
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, colorHex: Self.hex(from: $0.cgColor)) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func fetchEvents(daysBack: Int = 30, daysForward: Int = 14,
                            excluding: Set<String> = []) async throws -> [CalendarEvent] {
        let store = EKEventStore()
        guard try await ensureAccess(store) else { throw CalError.accessDenied }

        var calendars = store.calendars(for: .event)
        if !excluding.isEmpty { calendars = calendars.filter { !excluding.contains($0.calendarIdentifier) } }
        guard !calendars.isEmpty else { return [] }
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
        let end = cal.date(byAdding: .day, value: daysForward, to: Date()) ?? Date()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)

        let events = store.events(matching: predicate)
            .sorted { $0.startDate > $1.startDate }
            .prefix(200)

        return events.map { event in
            CalendarEvent(
                id: event.eventIdentifier ?? UUID().uuidString,
                title: event.title ?? "(untitled)",
                start: event.startDate,
                end: event.endDate,
                isAllDay: event.isAllDay,
                location: event.location,
                calendarTitle: event.calendar.title,
                calendarColorHex: Self.hex(from: event.calendar.cgColor),
                attendees: (event.attendees ?? []).compactMap { $0.name }
            )
        }
    }

    private static func hex(from cgColor: CGColor?) -> String {
        guard let cgColor, let color = cgColor.components, color.count >= 3 else { return "#8A8A8A" }
        let r = Int((color[0] * 255).rounded()), g = Int((color[1] * 255).rounded()), b = Int((color[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }
}
