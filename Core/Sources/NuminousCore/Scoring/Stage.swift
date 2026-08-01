import Foundation

/// The avatar's growth stage — and *only* the stage — is what other users can
/// see. It's a coarse tier, never a raw score or exact rank, so the social layer
/// stays light and un-grindable.
///
/// Growth is expressed as increasing *fidelity*: the early avatar is a
/// low-detail sketch that becomes progressively more defined, culminating in the
/// full photo-generated likeness.
public struct Stage: Identifiable, Hashable, Sendable {
    public let index: Int
    public let id: String
    public let name: String
    /// Revealed-point total at which this stage begins.
    public let threshold: Double

    public init(index: Int, id: String, name: String, threshold: Double) {
        self.index = index
        self.id = id
        self.name = name
        self.threshold = threshold
    }
}

public extension Stage {
    /// Default fidelity ladder, low-detail → true likeness. Thresholds are
    /// intentionally simple to start and meant to be tuned once it's playable.
    static let ladder: [Stage] = [
        Stage(index: 0, id: "sketch",   name: "Sketch",   threshold: 0),
        Stage(index: 1, id: "outline",  name: "Outline",  threshold: 60),
        Stage(index: 2, id: "form",     name: "Form",     threshold: 180),
        Stage(index: 3, id: "shaded",   name: "Shaded",   threshold: 400),
        Stage(index: 4, id: "defined",  name: "Defined",  threshold: 800),
        Stage(index: 5, id: "realized", name: "Realized", threshold: 1500),
    ]
}

/// Resolves a revealed-point total to a stage plus the fractional progress
/// toward the next one (for smoothly interpolating avatar detail).
public struct StageResolver: Sendable {
    public let ladder: [Stage]

    public init(ladder: [Stage] = Stage.ladder) {
        // Keep sorted by threshold for the lookup below.
        self.ladder = ladder.sorted { $0.threshold < $1.threshold }
    }

    /// The current stage for a revealed-point total.
    public func stage(for total: Double) -> Stage {
        var current = ladder.first!
        for stage in ladder where total >= stage.threshold {
            current = stage
        }
        return current
    }

    /// Progress toward the *next* stage in 0...1 (1 at the final stage).
    public func fidelity(for total: Double) -> Double {
        let current = stage(for: total)
        guard let next = ladder.first(where: { $0.index == current.index + 1 }) else {
            return 1
        }
        let span = next.threshold - current.threshold
        guard span > 0 else { return 1 }
        return min(1, max(0, (total - current.threshold) / span))
    }
}

public extension ScoreResult {
    /// The publicly-visible stage, derived from revealed growth.
    func stage(using resolver: StageResolver = StageResolver()) -> Stage {
        resolver.stage(for: revealedTotal)
    }

    /// Fractional progress toward the next stage.
    func fidelity(using resolver: StageResolver = StageResolver()) -> Double {
        resolver.fidelity(for: revealedTotal)
    }
}
