import SwiftUI
import NuminousCore

/// A scalable browser for a folder (top-level category) with lots of notes — e.g.
/// thousands of synced contacts. Notes are grouped A–Z and searchable, in a lazy
/// List, so even a huge folder stays fast and easy to parse.
struct FolderBrowserView: View {
    @EnvironmentObject var model: AppModel
    let category: String
    @State private var search = ""

    private var all: [Note] {
        model.notes.filter { inCategory($0) }
    }

    private func inCategory(_ n: Note) -> Bool {
        let fn = n.folderName.lowercased(); let c = category.lowercased()
        return fn == c || fn.hasPrefix(c + "/")
    }

    /// Alphabetical sections; a leading non-letter (or empty) goes under "#".
    private var sections: [(key: String, notes: [Note])] {
        let q = search.lowercased().trimmingCharacters(in: .whitespaces)
        let filtered = q.isEmpty ? all : all.filter {
            $0.displayName.lowercased().contains(q) || $0.body.lowercased().contains(q)
        }
        let grouped = Dictionary(grouping: filtered) { note -> String in
            let first = note.displayName.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "#"
            return first.range(of: "^[A-Z]$", options: .regularExpression) != nil ? first : "#"
        }
        return grouped.keys.sorted().map { key in
            (key, grouped[key]!.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending })
        }
    }

    var body: some View {
        List {
            if all.isEmpty {
                Text("Nothing here yet.").foregroundStyle(.secondary)
            } else {
                ForEach(sections, id: \.key) { section in
                    Section(section.key) {
                        ForEach(section.notes) { note in
                            NavigationLink(value: note.id) { NoteRow(note: note) }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $search, prompt: "Search \(category) (\(all.count))")
        .navigationTitle(category)
        .navigationBarTitleDisplayMode(.inline)
    }
}
