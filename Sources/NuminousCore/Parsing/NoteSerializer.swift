import Foundation

/// Writes a `Note` back out as plain markdown with YAML frontmatter — the
/// inverse of `NoteParser`. Notes stay human-readable files on disk, the way
/// Obsidian keeps them, so nothing is locked inside a proprietary store.
public enum NoteSerializer {

    nonisolated(unsafe) private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The full file contents (frontmatter + body) for a note. Only non-default
    /// fields are emitted, keeping files clean.
    public static func markdown(for note: Note) -> String {
        var lines: [String] = ["---"]
        lines.append("title: \(yaml(note.title))")
        if let categoryID = note.categoryID {
            lines.append("category: \(yaml(categoryID))")
        }
        lines.append("date: \(dayFormatter.string(from: note.date))")
        if let interaction = note.interaction {
            lines.append("interaction: \(interaction.rawValue)")
        }
        if let depth = note.depth {
            lines.append("depth: \(depth)")
        }
        if note.source != .manual {
            lines.append("source: \(note.source.rawValue)")
        }
        if let session = note.sessionID {
            lines.append("session: \(yaml(session))")
        }
        lines.append("---")

        let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            return lines.joined(separator: "\n") + "\n"
        }
        return lines.joined(separator: "\n") + "\n\n" + body + "\n"
    }

    /// Quotes a value only when it could be misread as YAML (contains a colon,
    /// leading/trailing space, or a leading special character).
    private static func yaml(_ value: String) -> String {
        let needsQuoting = value.contains(":")
            || value != value.trimmingCharacters(in: .whitespaces)
            || value.first.map { "#-?*&!|>%@`\"'".contains($0) } == true
        guard needsQuoting else { return value }
        let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
