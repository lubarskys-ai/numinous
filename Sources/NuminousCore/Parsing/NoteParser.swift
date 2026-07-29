import Foundation

/// Parses a plain-markdown note with optional YAML frontmatter into a `Note`.
///
/// This is a deliberately small YAML subset — flat `key: value` lines between
/// `---` fences — which is all the frontmatter this app writes. It is not a
/// general YAML parser and doesn't try to be.
public enum NoteParser {

    public struct ParseError: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// Parse a note.
    /// - Parameters:
    ///   - text: full file contents (frontmatter + body).
    ///   - fallbackTitle: used when no `title:` key is present — typically the
    ///     filename without extension, matching Obsidian's file-is-title model.
    public static func parse(
        _ text: String,
        fallbackTitle: String,
        id: UUID = UUID()
    ) -> Note {
        let (frontmatter, body) = splitFrontmatter(text)

        let title = frontmatter["title"] ?? fallbackTitle
        let categoryName = frontmatter["category"]
        let categoryID = categoryName.map(Category.slug)
        let date = frontmatter["date"].flatMap(parseDate) ?? Date()
        let interaction = frontmatter["interaction"].flatMap { InteractionMode(rawValue: normalizeEnum($0)) }
        let depth = frontmatter["depth"].flatMap { Int($0) }
        let source = frontmatter["source"].flatMap { NoteSource(rawValue: normalizeEnum($0)) } ?? .manual
        let sessionID = frontmatter["session"]

        return Note(
            id: id,
            title: title,
            categoryID: categoryID,
            date: date,
            body: body,
            interaction: interaction,
            depth: depth,
            source: source,
            sessionID: sessionID,
            isStub: false
        )
    }

    // MARK: - Frontmatter

    /// Splits leading `---`-fenced frontmatter from the body.
    /// Returns (`key: value` map, remaining body). No fence → empty map, whole text as body.
    static func splitFrontmatter(_ text: String) -> ([String: String], String) {
        // Normalize line endings so \r\n files parse identically.
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

        guard let start = bodyStart else {
            // Unterminated frontmatter — treat the whole thing as body, safest choice.
            return ([:], text)
        }
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
        // Accept "in-person", "in_person", "inPerson" etc. → matches rawValue "inPerson".
        let cleaned = value
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()
        switch cleaned {
        case "in person": return "inPerson"
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
