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

    /// Repairs malformed links so the graph never ingests garbage: collapses nested
    /// `[[a/[[b]]` (the innermost link wins → `[[b]]`), drops stray single brackets
    /// inside a link, and turns an unterminated `[[foo` into plain text rather than a
    /// bogus link. Run on save — never mid-keystroke, or an in-progress `[[` breaks.
    public static func sanitize(_ text: String) -> String {
        var out = ""
        var link: String? = nil     // non-nil while inside a [[ … ]]
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "[", i + 1 < chars.count, chars[i + 1] == "[" {
                // Opening (or a nested opening): the inner link is the intended one,
                // so discard whatever we'd accumulated for an outer, unclosed link.
                link = ""
                i += 2; continue
            }
            if chars[i] == "]", i + 1 < chars.count, chars[i + 1] == "]" {
                if let buf = link {
                    let t = buf.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { out += "[[\(t)]]" }
                    link = nil
                }
                i += 2; continue
            }
            if link != nil {
                if chars[i] != "[" && chars[i] != "]" { link!.append(chars[i]) }  // drop stray brackets
            } else {
                out.append(chars[i])
            }
            i += 1
        }
        // Unterminated link at the end → keep the words as plain text, not a bogus link.
        if let buf = link {
            let t = buf.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out += t }
        }
        return out
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
