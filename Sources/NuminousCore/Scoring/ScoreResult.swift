import Foundation

/// Per-axis point totals, keyed by `Axis.id`. Missing key == 0.
public typealias AxisTotals = [String: Double]

public extension AxisTotals {
    /// Points for an axis, defaulting to 0.
    func points(_ axisID: String) -> Double { self[axisID] ?? 0 }

    /// Sum across all axes.
    var total: Double { values.reduce(0, +) }

    /// In-place add of another set of totals.
    static func += (lhs: inout AxisTotals, rhs: AxisTotals) {
        for (k, v) in rhs { lhs[k, default: 0] += v }
    }

    /// Element-wise scale.
    func scaled(by factor: Double) -> AxisTotals {
        mapValues { $0 * factor }
    }
}

/// A single scored connection between two notes — surfaced for graph views and
/// for explaining *why* a number moved.
public struct ScoredLink: Hashable, Sendable {
    public let a: UUID
    public let b: UUID
    public let titleA: String
    public let titleB: String
    public let axisA: String?
    public let axisB: String?
    public let isCrossAxis: Bool
    public let isInPerson: Bool
    /// Points credited to *each* involved axis. 0 when the link isn't counted.
    public let bonusPerAxis: Double
    /// False when either endpoint is untyped/unmapped (contributes zero growth).
    public let isCounted: Bool
}

/// The growth attributable to one logging session, before and after caps.
public struct SessionGrowth: Identifiable, Sendable {
    /// Session key: an explicit `session:` id, or `day:yyyy-MM-dd` fallback.
    public let id: String
    /// Earliest note date in the session (used for ordering and the day bucket).
    public let date: Date
    /// Uncapped per-axis growth earned in this session.
    public let rawDelta: AxisTotals
    /// Per-axis growth after session + soft-daily caps.
    public let cappedDelta: AxisTotals
    /// True for the most recent session — earned but not yet revealed (the
    /// reveal is deliberately delayed to the next session).
    public let isPending: Bool
}

/// The full output of the engine: a pure, recomputable function of the current
/// notes + categories + config. Nothing here is persisted incrementally, which
/// is exactly what lets a category→axis reassignment reflow all of history.
public struct ScoreResult: Sendable {
    /// Uncapped totals — the pure thesis value of the graph. Use for reasoning
    /// and tests (e.g. cross-axis links out-earn same-axis), not for display.
    public let rawTotals: AxisTotals
    /// What the avatar renders right now: all sessions except the pending one.
    public let revealedTotals: AxisTotals
    /// Earned in the latest session, revealed next time the app is opened.
    public let pendingTotals: AxisTotals
    /// Sessions in chronological order.
    public let sessions: [SessionGrowth]
    /// Every connection considered, counted or not.
    public let links: [ScoredLink]

    public var revealedTotal: Double { revealedTotals.total }
    public var pendingTotal: Double { pendingTotals.total }

    /// Normalized share of revealed growth per axis (sums to 1 when nonzero) —
    /// drives the avatar's subtle per-axis color cast.
    public func axisBalance(over axes: [Axis]) -> AxisTotals {
        let total = revealedTotals.total
        guard total > 0 else { return [:] }
        var balance: AxisTotals = [:]
        for axis in axes {
            balance[axis.id] = revealedTotals.points(axis.id) / total
        }
        return balance
    }
}
