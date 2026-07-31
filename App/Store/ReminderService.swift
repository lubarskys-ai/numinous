import Foundation
import EventKit

/// Writes to the user's real iOS Reminders and Calendar via EventKit — the mirror
/// of `CalendarService` (which reads). Used to turn a note into a follow-up:
/// "met someone, remind me to call them in two weeks."
enum ReminderService {
    enum ServiceError: Error { case accessDenied }

    private static let store = EKEventStore()

    /// Create a reminder with a due date + an alarm; returns its identifier so we
    /// can later check whether the user completed it (and reward the follow-up).
    @discardableResult
    static func createReminder(title: String, notes: String?, due: Date) async throws -> String {
        try await requestAccess(to: .reminder)
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = store.defaultCalendarForNewReminders() ?? store.calendars(for: .reminder).first
        reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
        reminder.addAlarm(EKAlarm(absoluteDate: due))
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    /// Which of the given reminders the user has since marked complete.
    static func completed(of ids: [String]) async -> Set<String> {
        guard !ids.isEmpty, (try? await requestAccess(to: .reminder)) != nil else { return [] }
        var done: Set<String> = []
        for id in ids {
            if let r = store.calendarItem(withIdentifier: id) as? EKReminder, r.isCompleted { done.insert(id) }
        }
        return done
    }

    /// Create a calendar event with a lead-time alert.
    static func createEvent(title: String, notes: String?, start: Date, minutes: Int = 60) async throws {
        try await requestAccess(to: .event)
        let event = EKEvent(eventStore: store)
        event.title = title
        event.notes = notes
        event.startDate = start
        event.endDate = start.addingTimeInterval(TimeInterval(minutes * 60))
        event.calendar = store.defaultCalendarForNewEvents ?? store.calendars(for: .event).first
        event.addAlarm(EKAlarm(relativeOffset: -3600))
        try store.save(event, span: .thisEvent, commit: true)
    }

    private static func requestAccess(to entity: EKEntityType) async throws {
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = entity == .reminder
                ? try await store.requestFullAccessToReminders()
                : try await store.requestFullAccessToEvents()
        } else {
            granted = try await store.requestAccess(to: entity)
        }
        if !granted { throw ServiceError.accessDenied }
    }
}
