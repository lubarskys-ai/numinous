import Foundation

/// Suggests which axis a *new* user-defined category should map to.
///
/// The brief is explicit about two things here:
/// 1. With too little data (fewer than ~1 mapped category per axis), there's
///    nothing to compare against — so don't guess, ask the user to pick directly.
/// 2. Axis *names* are user-renamable, which rules out a hardcoded keyword
///    dictionary. So classification must reason from the user's *own* existing
///    categories, not from baked-in word lists.
///
/// This is a deterministic, on-device heuristic: it maps a new category to the
/// axis of the most textually-similar already-mapped category. In the real app
/// this is the natural place to swap in an LLM call (new category name + the
/// user's axes and their current categories); the result is always presented as
/// a pre-filled, overridable suggestion — never auto-applied.
public struct AxisClassifier: Sendable {

    public enum Suggestion: Equatable, Sendable {
        /// Not enough mapped categories yet — present a plain axis picker.
        case askUser
        /// A suggested axis with a 0...1 confidence, always overridable.
        case suggest(axisID: String, confidence: Double)
    }

    /// Minimum mapped categories per axis before we attempt a suggestion.
    public var dataThresholdPerAxis: Double

    public init(dataThresholdPerAxis: Double = 1.0) {
        self.dataThresholdPerAxis = dataThresholdPerAxis
    }

    public func suggestAxis(
        forNewCategoryNamed name: String,
        existingCategories: [Category],
        axes: [Axis]
    ) -> Suggestion {
        let mapped = existingCategories.filter { $0.axisID != nil }

        // Guard 1: too little data to compare against.
        guard !axes.isEmpty,
              Double(mapped.count) >= dataThresholdPerAxis * Double(axes.count) else {
            return .askUser
        }

        // Score similarity of the new name against every mapped category name;
        // the best match donates its axis.
        var best: (axisID: String, score: Double)? = nil
        for category in mapped {
            guard let axisID = category.axisID else { continue }
            let score = Self.similarity(name, category.name)
            if best == nil || score > best!.score {
                best = (axisID, score)
            }
        }

        guard let best, best.score > 0 else { return .askUser }
        return .suggest(axisID: best.axisID, confidence: best.score)
    }

    /// Token-overlap (Jaccard) similarity with a light character-bigram tie-break,
    /// in 0...1. Language-agnostic and dictionary-free.
    static func similarity(_ a: String, _ b: String) -> Double {
        let tokensA = tokens(a), tokensB = tokens(b)
        if !tokensA.isEmpty, !tokensB.isEmpty {
            let inter = tokensA.intersection(tokensB).count
            let union = tokensA.union(tokensB).count
            if inter > 0 { return Double(inter) / Double(union) }
        }
        let bigramsA = bigrams(a), bigramsB = bigrams(b)
        guard !bigramsA.isEmpty, !bigramsB.isEmpty else { return 0 }
        let inter = bigramsA.intersection(bigramsB).count
        let union = bigramsA.union(bigramsB).count
        return union == 0 ? 0 : Double(inter) / Double(union) * 0.5 // weighted below token match
    }

    private static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    private static func bigrams(_ s: String) -> Set<String> {
        let chars = Array(s.lowercased().filter { $0.isLetter || $0.isNumber })
        guard chars.count >= 2 else { return [] }
        return Set((0..<(chars.count - 1)).map { String(chars[$0...$0+1]) })
    }
}
