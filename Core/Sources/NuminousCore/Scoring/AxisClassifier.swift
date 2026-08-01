import Foundation

/// Suggests which axis a *new* folder should map to.
///
/// With too little data (fewer than ~1 mapped folder per axis), there's nothing
/// to compare against — so don't guess, ask the user to pick. Once there's data,
/// suggest the axis of the most textually-similar existing folder. This is the
/// natural seam to later swap in an LLM call; the result is always a pre-filled,
/// overridable suggestion, never auto-applied.
public struct AxisClassifier: Sendable {

    public enum Suggestion: Equatable, Sendable {
        case askUser
        case suggest(axisID: String, confidence: Double)
    }

    public var dataThresholdPerAxis: Double

    public init(dataThresholdPerAxis: Double = 1.0) {
        self.dataThresholdPerAxis = dataThresholdPerAxis
    }

    public func suggestAxis(
        forNewFolderNamed name: String,
        existingFolders: [Folder],
        axes: [Axis]
    ) -> Suggestion {
        let mapped = existingFolders.filter { $0.axisID != nil }
        guard !axes.isEmpty,
              Double(mapped.count) >= dataThresholdPerAxis * Double(axes.count) else {
            return .askUser
        }

        var best: (axisID: String, score: Double)? = nil
        for folder in mapped {
            guard let axisID = folder.axisID else { continue }
            // Compare against both the folder's name and its category label.
            let score = max(Self.similarity(name, folder.name), Self.similarity(name, folder.category))
            if best == nil || score > best!.score { best = (axisID, score) }
        }

        guard let best, best.score > 0 else { return .askUser }
        return .suggest(axisID: best.axisID, confidence: best.score)
    }

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
        return union == 0 ? 0 : Double(inter) / Double(union) * 0.5
    }

    private static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }
    private static func bigrams(_ s: String) -> Set<String> {
        let chars = Array(s.lowercased().filter { $0.isLetter || $0.isNumber })
        guard chars.count >= 2 else { return [] }
        return Set((0..<(chars.count - 1)).map { String(chars[$0...$0 + 1]) })
    }
}
