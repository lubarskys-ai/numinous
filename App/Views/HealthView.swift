import SwiftUI
import NuminousCore

/// A tab that reads your workouts and mindful minutes. Tap one to turn it into a
/// note — workouts grow Body, mindful sessions grow Spirit.
struct HealthView: View {
    @EnvironmentObject var model: AppModel

    enum LoadState { case loading, denied, loaded([HealthItem]), failed(String) }
    @State private var state: LoadState = .loading
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Health")
                .navigationDestination(for: UUID.self) { id in NoteDetailView(noteID: id) }
                .task { await load() }
                .refreshable { await load() }
                #if DEBUG
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Seed") { Task { await HealthKitService.seedSampleData(); await load() } }
                    }
                }
                #endif
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView("Reading your health data…")
        case .denied:
            emptyState("heart.text.square", "Health access needed",
                       "Enable Health for Numinous in Settings to turn workouts and mindful minutes into notes. Nothing is uploaded.")
        case .failed(let message):
            emptyState("exclamationmark.triangle", "Couldn't read Health", message)
        case .loaded(let items):
            if items.isEmpty {
                emptyState("heart.text.square", "No recent activity", "Workouts and mindful sessions from the last few weeks will show up here.")
            } else {
                list(items)
            }
        }
    }

    private func list(_ items: [HealthItem]) -> some View {
        let byDay = Dictionary(grouping: items) { Calendar.current.startOfDay(for: $0.start) }
        let days = byDay.keys.sorted(by: >)
        return List {
            ForEach(days, id: \.self) { day in
                Section(Self.dayLabel(day)) {
                    ForEach(byDay[day] ?? []) { item in
                        Button { open(item) } label: { row(item) }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func row(_ item: HealthItem) -> some View {
        let hasNote = healthNoteID(item) != nil
        let axisID = ["workout": "body", "mindful": "spirit", "nutrition": "gut"]
        let key = item.kind == .workout ? "workout" : (item.kind == .mindful ? "mindful" : "nutrition")
        let axisColor = model.axis(id: axisID[key] ?? "body")?.color ?? .secondary
        let icon = ["workout": "figure.run", "mindful": "brain.head.profile", "nutrition": "fork.knife"]
        let subtitle = item.kind == .nutrition
            ? (item.detail ?? "")
            : "\(Self.timeLabel(item.start)) · \(max(1, Int(item.duration / 60))) min"
        return HStack(spacing: 12) {
            Image(systemName: icon[key] ?? "heart")
                .foregroundStyle(axisColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: hasNote ? "checkmark.circle.fill" : "plus.circle")
                .foregroundStyle(hasNote ? Color.accentColor : .secondary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func healthNoteID(_ item: HealthItem) -> UUID? {
        model.notes.first { $0.origin?.source == "healthkit" && $0.origin?.externalID == item.id }?.id
    }

    private func open(_ item: HealthItem) {
        if let id = model.createNote(from: item) { path.append(id) }
    }

    private func load() async {
        do {
            let items = try await HealthKitService.fetch()
            state = .loaded(items)
        } catch HealthKitService.HealthError.unavailable {
            state = .failed("Health data isn't available on this device.")
        } catch {
            state = .denied
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

    private static func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d"
        return f.string(from: date)
    }

    private static func timeLabel(_ date: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
        return f.string(from: date)
    }
}
