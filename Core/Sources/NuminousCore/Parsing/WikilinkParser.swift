import Foundation

/// Extracts `[[Name]]` wikilink targets from note bodies, matching Obsidian's
/// behavior closely enough for this app: same simple regex, plus support for
/// `[[Target|alias]]` (the link target is what matters for the graph, not the
/// display alias).
public enum WikilinkParser {
    // Mirrors the brief's /\[\[([^\]]+)\]\]/g.
    private static let regex = try! NSRegularExpression(pattern: #"\[\[([^\]]+)\]\]"#)

    /// Returns the ordered, de-duplicated list of link targets found in `text`.
    /// Targets are trimmed; an `alias` after a `|` is dropped; empties skipped.
    /// De-duplication is case-insensitive but preserves the first-seen spelling.
    public static func extract(from text: String) -> [String] {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))

        var seen = Set<String>()
        var result: [String] = []
        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            let raw = ns.substring(with: match.range(at: 1))
            let target = raw.split(separator: "|", maxSplits: 1).first.map(String.init) ?? raw
            let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                result.append(trimmed)
            }
        }
        return result
    }

    /// Rewrites every `[[target]]` by passing its (trimmed) target through
    /// `transform` and substituting the result. Any `|alias` is preserved, and links
    /// whose target is unchanged are left byte-for-byte identical. Used to keep all
    /// links pointing at a note when it's renamed or moved to another folder.
    public static func rewrite(in text: String, transform: (String) -> String) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = ""
        var last = 0
        for match in matches {
            let full = match.range
            out += ns.substring(with: NSRange(location: last, length: full.location - last))
            let raw = ns.substring(with: match.range(at: 1))
            let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let trimmed = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let newTarget = transform(trimmed)
            if newTarget == trimmed {
                out += ns.substring(with: full)                       // unchanged — keep verbatim
            } else if parts.count > 1 {
                out += "[[\(newTarget)|\(parts[1])]]"
            } else {
                out += "[[\(newTarget)]]"
            }
            last = full.location + full.length
        }
        out += ns.substring(from: last)
        return out
    }
}
