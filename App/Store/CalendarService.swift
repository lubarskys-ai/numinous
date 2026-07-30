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

/// Reads events across all of the user's calendars (with permission). On-device;
/// nothing is uploaded — events only become notes when you tap them.
enum CalendarService {

    enum CalError: Error { case accessDenied }

    static func fetchEvents(daysBack: Int = 30, daysForward: Int = 14) async throws -> [CalendarEvent] {
        let store = EKEventStore()

        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = try await store.requestFullAccessToEvents()
        } else {
            granted = try await withCheckedThrowingContinuation { cont in
                store.requestAccess(to: .event) { ok, error in
                    if let error { cont.resume(throwing: error) } else { cont.resume(returning: ok) }
                }
            }
        }
        guard granted else { throw CalError.accessDenied }

        let calendars = store.calendars(for: .event)
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
