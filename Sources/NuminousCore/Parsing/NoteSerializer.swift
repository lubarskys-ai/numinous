import Foundation

/// Writes a `Note` back out as plain markdown with YAML frontmatter — the
/// inverse of `NoteParser`. Structured `details` are not emitted here (they live
/// in the app's store); everything else round-trips.
public enum NoteSerializer {

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func markdown(for note: Note) -> String {
        var lines: [String] = ["---"]
        lines.append("title: \(yaml(note.title))")
        lines.append("date: \(dayFormatter.string(from: note.date))")
        lines.append("intensity: \(note.intensity)")
        if let location = note.location, !location.isEmpty {
            lines.append("location: \(yaml(location))")
        }
        if note.source != .manual {
            lines.append("source: \(note.source.rawValue)")
        }
        if let session = note.sessionID {
            lines.append("session: \(yaml(session))")
        }
        lines.append("---")

        let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return lines.joined(separator: "\n") + "\n" }
        return lines.joined(separator: "\n") + "\n\n" + body + "\n"
    }

    private static func yaml(_ value: String) -> String {
        let needsQuoting = value.contains(":")
            || value != value.trimmingCharacters(in: .whitespaces)
            || value.first.map { "#-?*&!|>%@`\"'".contains($0) } == true
        guard needsQuoting else { return value }
        let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
