import SwiftUI
import NuminousCore

struct NoteRowView: View {
    @EnvironmentObject var store: NoteStore
    let note: Note

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(store.axis(forCategory: note.categoryID)?.color ?? Color.gray.opacity(0.35))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 4) {
                Text(note.title)
                    .font(.body.weight(.medium))

                if let snippet {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    if let category = store.category(note.categoryID) {
                        TagView(text: category.name,
                                color: store.axis(forCategory: note.categoryID)?.color ?? .gray)
                    } else {
                        TagView(text: "needs a category", color: .orange)
                    }
                    if note.interaction == .inPerson {
                        Label("in person", systemImage: "person.2.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var snippet: String? {
        let trimmed = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.replacingOccurrences(of: "\n", with: " ")
    }
}
