import Foundation

/// Computes avatar growth from a set of notes.
///
/// The engine is a **pure function**: `score(...)` reads the current notes,
/// folders, and axes and returns everything derivable from them. There is no
/// incremental state, which is what makes retroactive reflow (remapping a
/// folder to a new axis) free — you just score again.
///
/// The thesis lives here: base credit rewards logging, but *links* — especially
/// links that span two different axes — are where growth really comes from, and
/// a note's `intensity` scales how fast it develops you.
public struct ScoreEngine {

    public var config: ScoringConfig

    public init(config: ScoringConfig = .default) {
        self.config = config
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public func score(
        notes: [Note],
        folders: [Folder],
        axes: [Axis] = Axis.defaultSet
    ) -> ScoreResult {

        let foldersByID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let axisIDs = Set(axes.map(\.id))

        // A note's axis comes from its folder's mapping.
        func axisID(for note: Note) -> String? {
            let folderID = Folder.normalize(note.folderName)
            guard !folderID.isEmpty,
                  let folder = foldersByID[folderID],
                  let axisID = folder.axisID,
                  axisIDs.contains(axisID) else { return nil }
            return axisID
        }

        func factor(_ note: Note) -> Double { config.factor(forIntensity: note.intensity) }

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

        var sessionRaw: [String: AxisTotals] = [:]
        var sessionDate: [String: Date] = [:]
        func addToSession(_ key: String, date: Date, _ delta: AxisTotals) {
            sessionRaw[key, default: [:]] += delta
            if let existing = sessionDate[key] { if date < existing { sessionDate[key] = date } }
            else { sessionDate[key] = date }
        }

        // MARK: 1. Base credit — one credit per note to its own axis, scaled by intensity.
        for note in notes {
            guard !note.isStub, let axis = axisID(for: note) else { continue }
            let credit = note.source == .healthKit
                ? config.passiveBaseCredit
                : config.basePerNote * factor(note)
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
                if let axisA, let axisB, counted {
                    cross = axisA != axisB
                    let base = cross ? config.crossAxisLinkBonus : config.sameAxisLinkBonus
                    // Intensity of a connection = average of its endpoints.
                    bonus = base * ((factor(a) + factor(b)) / 2)

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
                    isCrossAxis: cross, bonusPerAxis: bonus, isCounted: counted
                ))
            }
        }

        // MARK: 2b. Connection complexity — reward notes that bridge many
        // distinct axes (super-linear in the number of axis-pairs bridged).
        if config.breadthBonus != 0 {
            var neighborAxes: [UUID: Set<String>] = [:]
            for link in links where link.isCounted {
                if let axisA = link.axisA { neighborAxes[link.b, default: []].insert(axisA) }
                if let axisB = link.axisB { neighborAxes[link.a, default: []].insert(axisB) }
            }
            for note in notes {
                guard !note.isStub, note.source == .manual, let axis = axisID(for: note) else { continue }
                var touched = neighborAxes[note.id] ?? []
                touched.insert(axis)
                let d = touched.count
                guard d >= 2 else { continue }
                let bonus = config.breadthBonus * Double(d * (d - 1) / 2)
                addToSession(sessionKey(for: note), date: note.date, [axis: bonus])
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
        var dayRaw: [String: Double] = [:]
        var rawTotals: AxisTotals = [:]

        for (index, key) in orderedKeys.enumerated() {
            let raw = sessionRaw[key] ?? [:]
            let date = sessionDate[key] ?? Date()
            rawTotals += raw

            let rawSum = raw.total
            let sessionScale = rawSum > config.sessionGrowthCap && rawSum > 0
                ? config.sessionGrowthCap / rawSum : 1
            let afterSession = rawSum * sessionScale

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

    /// Full credit up to remaining headroom under `threshold`, then `scale`
    /// credit beyond. Never punishes — over-threshold growth is diminished, not lost.
    static func softened(amount: Double, already: Double, threshold: Double, scale: Double) -> Double {
        guard amount > 0 else { return amount }
        let remainingFull = max(0, threshold - already)
        let full = min(amount, remainingFull)
        let over = amount - full
        return full + over * scale
    }
}
