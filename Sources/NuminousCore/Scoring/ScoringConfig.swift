import Foundation

/// All the tunable numbers behind growth, in one place. The brief calls for
/// "something simple, tuned once it's playable" — so every mechanic is a field
/// here rather than a magic number sprinkled through the engine.
public struct ScoringConfig: Codable, Sendable, Equatable {

    // MARK: Base credit

    /// Points a new manual note credits to its own axis.
    public var basePerNote: Double

    /// Points a passive (HealthKit) note credits to its axis. Lower than a
    /// written note, and — crucially — passive notes never earn link bonuses.
    public var passiveBaseCredit: Double

    // MARK: The core mechanic — links

    /// Bonus for a unique link between two notes in the *same* axis.
    public var sameAxisLinkBonus: Double

    /// Bonus for a unique link *across* two different axes. This is the whole
    /// thesis: it must be meaningfully larger than `sameAxisLinkBonus`. Note the
    /// bonus is credited to *each* axis involved, so a cross-axis link's total
    /// system value is `2 × crossAxisLinkBonus` versus `1 × sameAxisLinkBonus`.
    public var crossAxisLinkBonus: Double

    /// Multiplier applied to a link's bonus when either endpoint is an in-person
    /// person note — weighting real presence over mediated contact.
    public var inPersonMultiplier: Double

    // MARK: Anti-binge caps (consistency beats binge-logging)

    /// Max growth revealed from a single logging session (across all axes).
    public var sessionGrowthCap: Double

    /// Soft cap on growth per calendar day. Growth above this is kept but scaled
    /// down (see `softCapScale`) rather than hard-clipped — restraint is a quiet
    /// side effect, never a punished streak.
    public var softDailyCap: Double

    /// Fraction of full credit earned for growth beyond the soft daily cap.
    public var softCapScale: Double

    public init(
        basePerNote: Double = 10,
        passiveBaseCredit: Double = 4,
        sameAxisLinkBonus: Double = 5,
        crossAxisLinkBonus: Double = 15,
        inPersonMultiplier: Double = 1.5,
        sessionGrowthCap: Double = 60,
        softDailyCap: Double = 100,
        softCapScale: Double = 0.25
    ) {
        self.basePerNote = basePerNote
        self.passiveBaseCredit = passiveBaseCredit
        self.sameAxisLinkBonus = sameAxisLinkBonus
        self.crossAxisLinkBonus = crossAxisLinkBonus
        self.inPersonMultiplier = inPersonMultiplier
        self.sessionGrowthCap = sessionGrowthCap
        self.softDailyCap = softDailyCap
        self.softCapScale = softCapScale
    }

    public static let `default` = ScoringConfig()
}
