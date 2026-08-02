import Foundation

/// Deterministic auto-linking: scan free text (e.g. a dictated note) for the names
/// of notes you already have and suggest wikilinks to them — no LLM needed. A
/// smarter on-device-LLM layer (fuzzy references, new entities) can build on top.
public struct AutoLinker {
    public struct Suggestion: Equatable, Sendable {
        public let name: String     // display name matched, e.g. "Sam"
        public let target: String   // wikilink target, e.g. "people/Sam"
        public init(name: String, target: String) { self.name = name; self.target = target }
    }

    public init() {}

    /// Suggested links for `text`, given candidate notes as (displayName, target).
    /// Longest names win over shorter substrings; whole-word, case-insensitive;
    /// skips names already linked in the text.
    public func suggest(in text: String, candidates: [(name: String, target: String)]) -> [Suggestion] {
        let alreadyLinked = Set(WikilinkParser.extract(from: text).map { $0.lowercased() })
        var results: [Suggestion] = []
        var usedRanges: [Range<String.Index>] = []
        var seenTargets = Set<String>()
        let sorted = candidates
            .filter { $0.name.trimmingCharacters(in: .whitespaces).count >= 3 }
            .sorted { $0.name.count > $1.name.count }
        for candidate in sorted {
            let key = candidate.target.lowercased()
            if alreadyLinked.contains(key) || seenTargets.contains(key) { continue }
            guard let range = Self.firstWordRange(of: candidate.name, in: text) else { continue }
            if usedRanges.contains(where: { $0.overlaps(range) }) { continue }
            results.append(Suggestion(name: candidate.name, target: candidate.target))
            usedRanges.append(range)
            seenTargets.insert(key)
        }
        return results
    }

    /// A looser range: matches `phrase` in `text` ignoring case AND punctuation
    /// between/around words, on word boundaries. Finds "Dunkin' Donuts" for the
    /// cleaned name "dunkin donuts" (dictation adds caps/apostrophes the LLM drops),
    /// so a suggested link can replace the words in place instead of appending.
    public static func flexibleRange(of phrase: String, in text: String) -> Range<String.Index>? {
        // Alphanumeric tokens, matched in order separated by any run of non-alphanumerics.
        let tokens = phrase.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !tokens.isEmpty else { return nil }
        let pattern = "(?<![A-Za-z0-9])" + tokens.joined(separator: "[^A-Za-z0-9]+") + "(?![A-Za-z0-9])"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Range(m.range, in: text)
    }

    /// The first whole-word, case-insensitive occurrence of `name` in `text`.
    public static func firstWordRange(of name: String, in text: String) -> Range<String.Index>? {
        let needle = name.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return nil }
        var start = text.startIndex
        while let r = text.range(of: needle, options: [.caseInsensitive], range: start..<text.endIndex) {
            let before = r.lowerBound == text.startIndex ? nil : text[text.index(before: r.lowerBound)]
            let after = r.upperBound == text.endIndex ? nil : text[r.upperBound]
            let boundaryOK = !(before?.isLetter ?? false) && !(before?.isNumber ?? false)
                          && !(after?.isLetter ?? false) && !(after?.isNumber ?? false)
            if boundaryOK { return r }
            start = r.upperBound
        }
        return nil
    }
}
