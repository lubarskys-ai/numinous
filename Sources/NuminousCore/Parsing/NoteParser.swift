import Foundation

/// Parses a plain-markdown note with optional YAML frontmatter into a `Note`.
///
/// A deliberately small YAML subset — flat `key: value` lines between `---`
/// fences — which is all the frontmatter this app writes. The note's folder is
/// derived from its title path (`people/Sam`), not from frontmatter. Structured
/// `details` are not represented in markdown; they live in the app's store.
public enum NoteParser {

    public static func parse(
        _ text: String,
        fallbackTitle: String,
        id: UUID = UUID()
    ) -> Note {
        let (frontmatter, body) = splitFrontmatter(text)

        let title = frontmatter["title"] ?? fallbackTitle
        let date = frontmatter["date"].flatMap(parseDate) ?? Date()
        let intensity = frontmatter["intensity"].flatMap { Int($0) }.map { min(5, max(1, $0)) } ?? 3
        let location = frontmatter["location"]
        let source = frontmatter["source"].flatMap { NoteSource(rawValue: normalizeEnum($0)) } ?? .manual
        let sessionID = frontmatter["session"]

        return Note(
            id: id,
            title: title,
            date: date,
            body: body,
            intensity: intensity,
            location: location,
            details: [],
            source: source,
            sessionID: sessionID,
            isStub: false
        )
    }

    // MARK: - Frontmatter

    static func splitFrontmatter(_ text: String) -> ([String: String], String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return ([:], text)
        }

        var map: [String: String] = [:]
        var bodyStart: Int? = nil
        for index in 1..<lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces) == "---" {
                bodyStart = index + 1
                break
            }
            let line = lines[index]
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            value = stripQuotes(value)
            guard !key.isEmpty, !value.isEmpty else { continue }
            map[key.lowercased()] = value
        }

        guard let start = bodyStart else { return ([:], text) }
        let body = lines[start...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (map, body)
    }

    private static func stripQuotes(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        let quotes: [Character] = ["\"", "'"]
        if let first = value.first, let last = value.last, first == last, quotes.contains(first) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func normalizeEnum(_ value: String) -> String {
        let cleaned = value.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").lowercased()
        switch cleaned {
        case "healthkit", "health kit": return "healthKit"
        default: return value
        }
    }

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    nonisolated(unsafe) private static let isoDateTimeFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ string: String) -> Date? {
        if let date = isoFormatter.date(from: string) { return date }
        if let date = isoDateTimeFormatter.date(from: string) { return date }
        return nil
    }
}
