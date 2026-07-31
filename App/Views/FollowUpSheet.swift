import SwiftUI

/// Turn a note into a real iOS reminder (or calendar event). The reminder is
/// tracked so that completing it later rewards the follow-through (grows Heart).
struct FollowUpSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let noteTitle: String        // e.g. "people/Sam" — linked back to when rewarded
    let defaultTitle: String     // e.g. "Call Sam"
    var onDone: (String) -> Void

    @State private var title: String
    @State private var date: Date
    @State private var busy = false
    @State private var errorText: String?

    init(noteTitle: String, defaultTitle: String, onDone: @escaping (String) -> Void) {
        self.noteTitle = noteTitle
        self.defaultTitle = defaultTitle
        self.onDone = onDone
        _title = State(initialValue: defaultTitle)
        _date = State(initialValue: Self.at(daysFromNow: 14))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Reminder") {
                    TextField("Title", text: $title)
                }
                Section("When") {
                    HStack {
                        ForEach(quickPicks, id: \.0) { label, days in
                            Button(label) { date = Self.at(daysFromNow: days) }
                                .buttonStyle(.bordered).controlSize(.small).font(.caption)
                        }
                    }
                    DatePicker("Date & time", selection: $date)
                }
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red)
                }
                Section {
                    Button { create(.reminder) } label: { Label("Add reminder", systemImage: "bell.badge") }
                    Button { create(.event) } label: { Label("Add to calendar", systemImage: "calendar.badge.plus") }
                } footer: {
                    Text("Complete the reminder in iOS and Numinous rewards the follow-through — your connection grows.")
                }
                .disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .navigationTitle("Follow up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private var quickPicks: [(String, Int)] { [("In 3 days", 3), ("In 2 weeks", 14), ("In a month", 30)] }
    private enum Kind { case reminder, event }

    private func create(_ kind: Kind) {
        busy = true; errorText = nil
        let notes = "From Numinous · \(noteTitle)"
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        Task {
            do {
                switch kind {
                case .reminder:
                    let id = try await ReminderService.createReminder(title: title, notes: notes, due: date)
                    model.recordFollowUp(reminderID: id, noteTitle: noteTitle, title: title, due: date)
                    onDone("Reminder set for \(df.string(from: date)). Complete it and your connection grows.")
                case .event:
                    try await ReminderService.createEvent(title: title, notes: notes, start: date)
                    onDone("Added to your calendar for \(df.string(from: date)).")
                }
                dismiss()
            } catch ReminderService.ServiceError.accessDenied {
                errorText = "Access was declined. Enable it in Settings → Numinous."
            } catch {
                errorText = "Couldn't create it: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    private static func at(daysFromNow days: Int) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: Date())) ?? Date()
        return cal.date(bySettingHour: 10, minute: 0, second: 0, of: day) ?? day
    }
}
