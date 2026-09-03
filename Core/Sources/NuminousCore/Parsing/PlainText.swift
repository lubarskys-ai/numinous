import Foundation

/// Strips Markdown formatting out of generated prose.
///
/// The on-device model reaches for `**bold**` and headings out of habit, but a Numinous note
/// is plain text — the editor renders `[[links]]` and nothing else, so the asterisks just sit
/// there in the entry. Instructing the model not to emit them is unreliable on its own, so
/// the output is cleaned here as well.
///
/// Wikilinks are never touched: only emphasis, heading and code markers are removed, and the
/// words between them are kept exactly as written.
public enum PlainText {

    private static let emphasisPatterns: [String] = [
        "\\*\\*(.+?)\\*\\*",                                // **bold**
        "__(.+?)__",                                        // __bold__
        "(?<![\\w*])\\*(?!\\s)(.+?)(?<!\\s)\\*(?![\\w*])",  // *italic*
        "(?<![\\w_])_(?!\\s)(.+?)(?<!\\s)_(?![\\w_])",      // _italic_
        "`(.+?)`"                                           // `code`
    ]

    private static let emphasis: [NSRegularExpression] = emphasisPatterns.compactMap {
        try? NSRegularExpression(pattern: $0)
    }

    /// Return `text` with Markdown formatting removed, leaving the words intact.
    public static func stripMarkdown(_ text: String) -> String {
        // Cheap early-out — most entries carry no markers at all.
        guard text.contains(where: { "*_`#>".contains($0) }) else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { stripLine(String($0)) }
            .joined(separator: "\n")
    }

    private static func stripLine(_ line: String) -> String {
        var body = line
        var indent = ""
        if let firstNonSpace = body.firstIndex(where: { !$0.isWhitespace }) {
            indent = String(body[body.startIndex..<firstNonSpace])
            body = String(body[firstNonSpace...])
        } else {
            return line   // blank line
        }
        // Leading structure: "## Heading" → "Heading", "> quote" → "quote", "* item" → "- item".
        if body.hasPrefix("#") || body.hasPrefix(">") {
            while body.hasPrefix("#") || body.hasPrefix(">") { body.removeFirst() }
            body = body.trimmingCharacters(in: .whitespaces)
        }
        if body.hasPrefix("* ") || body.hasPrefix("+ ") {
            body = "- " + body.dropFirst(2)
        }

        // Inline markers. Repeat until stable so nested emphasis ("**a *b* c**") fully unwraps.
        for _ in 0..<3 {
            let before = body
            for re in emphasis {
                let range = NSRange(body.startIndex..., in: body)
                body = re.stringByReplacingMatches(in: body, range: range, withTemplate: "$1")
            }
            if body == before { break }
        }
        // Anything left is a marker the model opened and never closed.
        body = body.replacingOccurrences(of: "**", with: "")
        return indent + body
    }
}
