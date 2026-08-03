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

    /// Every event calendar available to the user, for the selection UI. Birthday
    /// calendars are excluded — they're an auto-generated flood (one per contact),
    /// not events you'd turn into notes.
    static func availableCalendars() async throws -> [CalendarInfo] {
        let store = EKEventStore()
        guard try await ensureAccess(store) else { throw CalError.accessDenied }
        return store.calendars(for: .event)
            .filter { $0.type != .birthday }
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, colorHex: Self.hex(from: $0.cgColor)) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func fetchEvents(daysBack: Int = 60, daysForward: Int = 120,
                            excluding: Set<String> = []) async throws -> [CalendarEvent] {
        let store = EKEventStore()
        guard try await ensureAccess(store) else { throw CalError.accessDenied }

        // Skip the Birthdays calendar (auto-generated from Contacts) — with a big
        // address book it swamps everything else.
        var calendars = store.calendars(for: .event).filter { $0.type != .birthday }
        if !excluding.isEmpty { calendars = calendars.filter { !excluding.contains($0.calendarIdentifier) } }
        guard !calendars.isEmpty else { return [] }
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
        let end = cal.date(byAdding: .day, value: daysForward, to: Date()) ?? Date()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)

        // Keep the events nearest to now (past or future) so the cap never drops the
        // ones you care about in favour of far-off entries.
        let events = store.events(matching: predicate)
            .sorted { abs($0.startDate.timeIntervalSinceNow) < abs($1.startDate.timeIntervalSinceNow) }
            .prefix(300)

        return events.map { event in
            // Recurring events share one eventIdentifier across all occurrences, which
            // collides in SwiftUI's List (only one per day survives). Make the id
            // unique per occurrence by folding in the start time.
            let base = event.eventIdentifier ?? UUID().uuidString
            return CalendarEvent(
                id: "\(base)@\(Int(event.startDate.timeIntervalSince1970))",
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
