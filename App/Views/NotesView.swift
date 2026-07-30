import SwiftUI
import NuminousCore

struct NotesView: View {
    @EnvironmentObject var model: AppModel
    @State private var showCompose = false
    @State private var composePrefill: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.groupedByFolder) { group in
                    Section {
                        ForEach(group.notes) { note in
                            NavigationLink(value: note.id) { NoteRow(note: note) }
                        }
                        .onDelete { offsets in model.delete(offsets.map { group.notes[$0] }) }
                    } header: {
                        Text(group.id.isEmpty ? "Unfiled" : group.id)
                    }
                }
            }
            .navigationTitle("Notes")
            .navigationDestination(for: UUID.self) { id in NoteDetailView(noteID: id) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { composePrefill = "diary/" + Self.stamp(); showCompose = true } label: {
                        Label("Diary", systemImage: "calendar.badge.plus")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { composePrefill = nil; showCompose = true } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New note")
                }
            }
            .sheet(isPresented: $showCompose) {
                ComposeView(prefillTitle: composePrefill)
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
        HStack(spacing: 12) {
            Circle()
                .fill(model.axis(for: note)?.color ?? Color.gray.opacity(0.35))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 4) {
                Text(note.displayName).font(.body.weight(.medium))
                if let snippet { Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if !note.isStub {
                    HStack(spacing: 6) {
                        Text("⚡ \(note.intensity)").font(.caption2).foregroundStyle(.secondary)
                        if let loc = note.location, !loc.isEmpty {
                            Text("📍 \(loc)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private var snippet: String? {
        let t = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return t.replacingOccurrences(of: "\n", with: " ")
    }
}
