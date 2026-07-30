import Foundation

/// All the tunable numbers behind growth, in one place. The brief calls for
/// "something simple, tuned once it's playable" — so every mechanic is a field
/// here rather than a magic number sprinkled through the engine.
public struct ScoringConfig: Codable, Sendable, Equatable {

    // MARK: Base credit

    /// Points a new manual note credits to its own axis (before intensity).
    public var basePerNote: Double

    /// Points a passive (HealthKit) note credits to its axis. Lower than a
    /// written note, and — crucially — passive notes never earn link bonuses.
    public var passiveBaseCredit: Double

    // MARK: The core mechanic — links

    /// Bonus for a unique link between two notes in the *same* axis.
    public var sameAxisLinkBonus: Double

    /// Bonus for a unique link *across* two different axes. The whole thesis:
    /// meaningfully larger than `sameAxisLinkBonus`, and credited to *each* axis.
    public var crossAxisLinkBonus: Double

    // MARK: Intensity — the "speed of development" dial

    /// Maps a note's 1–5 intensity to a growth multiplier. 3 is neutral (×1);
    /// a profound note (×2) develops you twice as fast as a faint one (×0.5).
    /// Applied to base credit and (averaged over endpoints) to link bonuses.
    public var intensityMultipliers: [Int: Double]

    // MARK: Anti-binge caps (consistency beats binge-logging)

    public var sessionGrowthCap: Double
    public var softDailyCap: Double
    public var softCapScale: Double

    public init(
        basePerNote: Double = 10,
        passiveBaseCredit: Double = 4,
        sameAxisLinkBonus: Double = 5,
        crossAxisLinkBonus: Double = 15,
        intensityMultipliers: [Int: Double] = [1: 0.5, 2: 0.75, 3: 1, 4: 1.5, 5: 2],
        sessionGrowthCap: Double = 90,
        softDailyCap: Double = 150,
        softCapScale: Double = 0.25
    ) {
        self.basePerNote = basePerNote
        self.passiveBaseCredit = passiveBaseCredit
        self.sameAxisLinkBonus = sameAxisLinkBonus
        self.crossAxisLinkBonus = crossAxisLinkBonus
        self.intensityMultipliers = intensityMultipliers
        self.sessionGrowthCap = sessionGrowthCap
        self.softDailyCap = softDailyCap
        self.softCapScale = softCapScale
    }

    /// Growth multiplier for an intensity value (defaults to ×1 if out of range).
    public func factor(forIntensity intensity: Int) -> Double {
        intensityMultipliers[intensity] ?? 1
    }

    public static let `default` = ScoringConfig()
}
