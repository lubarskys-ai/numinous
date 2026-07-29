import Foundation
import NuminousCore

struct StoredData {
    var notes: [Note]
    var categories: [Category]
}

/// Local-first persistence. Notes are saved as individual plain-markdown files
/// (Obsidian-style, human-readable, portable); categories live in a small JSON
/// sidecar. The note's UUID is the filename, so identity survives round-trips.
struct Storage {
    private let fm = FileManager.default

    private var root: URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Numinous", isDirectory: true)
    }
    private var notesDir: URL { root.appendingPathComponent("notes", isDirectory: true) }
    private var categoriesFile: URL { root.appendingPathComponent("categories.json") }

    init() {
        try? fm.createDirectory(at: notesDir, withIntermediateDirectories: true)
    }

    func load() -> StoredData {
        var notes: [Note] = []
        if let files = try? fm.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "md" {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let name = file.deletingPathExtension().lastPathComponent
                let id = UUID(uuidString: name) ?? UUID()
                notes.append(NoteParser.parse(text, fallbackTitle: name, id: id))
            }
        }

        var categories: [Category] = []
        if let data = try? Data(contentsOf: categoriesFile),
           let decoded = try? JSONDecoder().decode([Category].self, from: data) {
            categories = decoded
        }
        return StoredData(notes: notes, categories: categories)
    }

    func save(notes: [Note], categories: [Category]) {
        // Rewrite the notes directory so deletions are reflected.
        if let existing = try? fm.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: nil) {
            for file in existing where file.pathExtension == "md" {
                try? fm.removeItem(at: file)
            }
        }
        for note in notes {
            let url = notesDir.appendingPathComponent("\(note.id.uuidString).md")
            try? NoteSerializer.markdown(for: note).write(to: url, atomically: true, encoding: .utf8)
        }
        if let data = try? JSONEncoder().encode(categories) {
            try? data.write(to: categoriesFile)
        }
    }
}
