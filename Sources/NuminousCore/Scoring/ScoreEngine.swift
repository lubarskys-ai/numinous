import Foundation

/// Computes avatar growth from a set of notes.
///
/// The engine is a **pure function**: `score(...)` reads the current notes,
/// categories, and axes and returns everything derivable from them. There is no
/// incremental state, which is what makes retroactive reflow (reassigning a
/// category to a new axis) free — you just score again.
///
/// The thesis lives here: base credit rewards logging, but *links* — especially
/// links that span two different axes, and interactions that happened in person
/// — are where growth really comes from.
public struct ScoreEngine {

    public var config: ScoringConfig

    public init(config: ScoringConfig = .default) {
        self.config = config
    }

    // Day bucketing uses UTC so results are deterministic regardless of the
    // machine's timezone (important for reproducible scoring + tests).
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public func score(
        notes: [Note],
        categories: [Category],
        axes: [Axis] = Axis.defaultSet
    ) -> ScoreResult {

        let categoriesByID = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let axisIDs = Set(axes.map(\.id))

        // Resolve a note's axis: category exists, is mapped, and the axis exists.
        func axisID(for note: Note) -> String? {
            guard let categoryID = note.categoryID,
                  let category = categoriesByID[categoryID],
                  let axisID = category.axisID,
                  axisIDs.contains(axisID) else { return nil }
            return axisID
        }

        // Title index for wikilink resolution (case-insensitive, first wins).
        var notesByTitle: [String: Note] = [:]
        for note in notes {
            let key = note.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if notesByTitle[key] == nil { notesByTitle[key] = note }
        }
        let notesByID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        func sessionKey(for note: Note) -> String {
            if let explicit = note.sessionID { return "session:\(explicit)" }
            return "day:\(Self.dayFormatter.string(from: note.date))"
        }

        // Accumulators keyed by session.
        var sessionRaw: [String: AxisTotals] = [:]
        var sessionDate: [String: Date] = [:]
        func addToSession(_ key: String, date: Date, _ delta: AxisTotals) {
            sessionRaw[key, default: [:]] += delta
            if let existing = sessionDate[key] {
                if date < existing { sessionDate[key] = date }
            } else {
                sessionDate[key] = date
            }
            // Ensure a session with only base credit still registers its date.
        }

        // MARK: 1. Base credit — one credit per note to its own axis.
        for note in notes {
            guard !note.isStub, let axis = axisID(for: note) else { continue }
            let credit = note.source == .healthKit ? config.passiveBaseCredit : config.basePerNote
            guard credit != 0 else { continue }
            addToSession(sessionKey(for: note), date: note.date, [axis: credit])
        }

        // MARK: 2. Links — the core mechanic. Unique undirected edges from
        // manual note bodies. Passive notes have no bodies, so earn no bonuses.
        var seenEdges = Set<String>()
        var links: [ScoredLink] = []

        for note in notes where note.source == .manual {
            for target in note.linkTargets {
                let key = target.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard let other = notesByTitle[key], other.id != note.id else { continue }

                // Undirected uniqueness by the pair of ids.
                let ids = [note.id.uuidString, other.id.uuidString].sorted()
                let edgeKey = ids.joined(separator: "~")
                guard seenEdges.insert(edgeKey).inserted else { continue }

                let a = notesByID[UUID(uuidString: ids[0])!]!
                let b = notesByID[UUID(uuidString: ids[1])!]!
                let axisA = axisID(for: a)
                let axisB = axisID(for: b)
                let counted = axisA != nil && axisB != nil

                var bonus = 0.0
                var cross = false
                let inPerson = a.interaction == .inPerson || b.interaction == .inPerson
                if let axisA, let axisB, counted {
                    cross = axisA != axisB
                    bonus = cross ? config.crossAxisLinkBonus : config.sameAxisLinkBonus
                    if inPerson { bonus *= config.inPersonMultiplier }

                    // Credit each *distinct* involved axis. Cross-axis links thus
                    // pay out twice over (once per axis); same-axis links once.
                    let laterDate = max(a.date, b.date)
                    let laterNote = a.date >= b.date ? a : b
                    let sKey = sessionKey(for: laterNote)
                    var delta: AxisTotals = [:]
                    for axis in Set([axisA, axisB]) { delta[axis, default: 0] += bonus }
                    addToSession(sKey, date: laterDate, delta)
                }

                links.append(ScoredLink(
                    a: a.id, b: b.id, titleA: a.title, titleB: b.title,
                    axisA: axisA, axisB: axisB,
                    isCrossAxis: cross, isInPerson: inPerson,
                    bonusPerAxis: bonus, isCounted: counted
                ))
            }
        }

        // MARK: 3. Order sessions, apply caps, split revealed vs pending.
        let orderedKeys = sessionRaw.keys.sorted { lhs, rhs in
            let dl = sessionDate[lhs] ?? .distantFuture
            let dr = sessionDate[rhs] ?? .distantFuture
            if dl != dr { return dl < dr }
            return lhs < rhs
        }

        var sessions: [SessionGrowth] = []
        var dayRaw: [String: Double] = [:]      // pre-soft growth applied per day
        var rawTotals: AxisTotals = [:]

        for (index, key) in orderedKeys.enumerated() {
            let raw = sessionRaw[key] ?? [:]
            let date = sessionDate[key] ?? Date()
            rawTotals += raw

            let rawSum = raw.total
            // Session cap (hard): scale the whole session down to fit.
            let sessionScale = rawSum > config.sessionGrowthCap && rawSum > 0
                ? config.sessionGrowthCap / rawSum : 1
            let afterSession = rawSum * sessionScale

            // Soft daily cap: growth beyond the day's threshold earns reduced credit.
            let day = Self.dayFormatter.string(from: date)
            let already = dayRaw[day] ?? 0
            let effective = Self.softened(
                amount: afterSession, already: already,
                threshold: config.softDailyCap, scale: config.softCapScale
            )
            dayRaw[day] = already + afterSession

            let totalScale = rawSum > 0 ? effective / rawSum : 0
            let capped = raw.scaled(by: totalScale)
            let isPending = index == orderedKeys.count - 1

            sessions.append(SessionGrowth(
                id: key, date: date, rawDelta: raw,
                cappedDelta: capped, isPending: isPending
            ))
        }

        var revealed: AxisTotals = [:]
        var pending: AxisTotals = [:]
        for session in sessions {
            if session.isPending { pending += session.cappedDelta }
            else { revealed += session.cappedDelta }
        }

        return ScoreResult(
            rawTotals: rawTotals,
            revealedTotals: revealed,
            pendingTotals: pending,
            sessions: sessions,
            links: links
        )
    }

    /// Applies a soft cap: full credit up to the remaining headroom under
    /// `threshold`, then `scale` credit for anything beyond. Never punishes —
    /// over-threshold growth is diminished, not lost.
    static func softened(amount: Double, already: Double, threshold: Double, scale: Double) -> Double {
        guard amount > 0 else { return amount }
        let remainingFull = max(0, threshold - already)
        let full = min(amount, remainingFull)
        let over = amount - full
        return full + over * scale
    }
}
