import SwiftUI
import NuminousCore

/// A quiet, once-a-week look back: which life areas you tended, which went quiet, who you've
/// drifted from, and one grounded observation. The moment where the app stops being a store
/// of your life and reflects it back — the point of the whole thing.
struct WeeklyReviewView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let digest: AppModel.WeeklyDigest
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !digest.tendedAxisIDs.isEmpty {
                    Section {
                        ForEach(digest.tendedAxisIDs, id: \.self) { axisRow($0) }
                    } header: { Text("You tended") } footer: { Text("Areas of your life you touched this week.") }
                }
                if !digest.quietAxisIDs.isEmpty {
                    Section {
                        ForEach(digest.quietAxisIDs, id: \.self) { axisRow($0) }
                    } header: { Text("Quiet this week") } footer: { Text("No pressure — just noticing where your attention went.") }
                }
                if !digest.drifting.isEmpty {
                    Section {
                        ForEach(digest.drifting) { p in
                            Button { path.append(p.id) } label: { personRow(p) }
                                .buttonStyle(.plain)
                        }
                    } header: { Text("People you've drifted from") } footer: { Text("A gentle nudge — maybe reach out to one of them.") }
                }
                if let nudge = digest.travelNudge {
                    Section {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "globe.americas").foregroundStyle(.teal)
                            Text(nudge).font(.callout)
                        }
                    } header: { Text("Where you've been") } footer: { Text("A place you don't know already grows you more than a longer trip back somewhere you do.") }
                }
                if let reflection = digest.reflection {
                    Section {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "sparkles").foregroundStyle(.pink)
                            Text(reflection).font(.callout)
                        }
                    } header: { Text("Numinous noticed") }
                }
                if digest.isEmpty {
                    Text("Not much to look back on yet — keep tending your notes and this will fill in.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Your week")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(for: UUID.self) { NoteDetailView(noteID: $0) }
        }
    }

    private func axisRow(_ id: String) -> some View {
        HStack(spacing: 10) {
            Circle().fill(model.axis(id: id)?.color ?? .secondary).frame(width: 10, height: 10)
            Text(model.axis(id: id)?.name ?? id).foregroundStyle(.primary)
        }
    }

    private func personRow(_ p: AppModel.WeeklyDigest.Person) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Color.pink.opacity(0.8)).frame(width: 9, height: 9)
            Text(p.name).foregroundStyle(.primary)
            Spacer()
            if let stale = AppModel.outOfTouchLabel(p.lastContact) {
                Text(stale).font(.caption).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
