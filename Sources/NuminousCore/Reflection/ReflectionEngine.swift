import Foundation

/// A single true thing worth telling you about your web, derived purely from the
/// scoring graph. The engine only decides *what* is true and worth saying; the
/// app decides *how* to say it (templated now, an on-device model later). Keeping
/// the facts here — grounded in real links — is what stops the voice layer from
/// inventing things about your life.
public struct Observation: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// Two axes are joined by exactly one connection — a fresh thread.
        case firstBridge
        /// One note sits at the crossroads of many connections.
        case hub
        /// An axis has notes but none of them reach into another part of life.
        case isolatedAxis
        /// An axis has grown least — a quiet corner.
        case quietAxis
        /// The axis you've been growing most lately.
        case momentum
    }

    public let kind: Kind
    public let axisIDs: [String]
    public let noteTitles: [String]
    /// Ranking weight within a kind (link count, point delta, …).
    public let magnitude: Double
    /// Stable key so the app can avoid repeating the same observation too soon
    /// and can notice when a past one has since changed.
    public let signature: String

    public init(kind: Kind, axisIDs: [String] = [], noteTitles: [String] = [],
                magnitude: Double, signature: String) {
        self.kind = kind
        self.axisIDs = axisIDs
        self.noteTitles = noteTitles
        self.magnitude = magnitude
        self.signature = signature
    }

    /// Emotional priority when several observations are available at once.
    var priority: Int {
        switch kind {
        case .firstBridge:  return 5
        case .hub:          return 4
        case .momentum:     return 3
        case .isolatedAxis: return 2
        case .quietAxis:    return 1
        }
    }
}

/// Reads the scored graph and surfaces the observations most worth reflecting
/// back — ranked, most resonant first. Pure and recomputable, like `ScoreEngine`.
public struct ReflectionEngine {

    public init() {}

    public func observe(
        notes: [Note],
        folders: [Folder],
        axes: [Axis],
        result: ScoreResult,
        now: Date = Date()
    ) -> [Observation] {

        let foldersByID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let axisIDs = Set(axes.map(\.id))
        func axisID(for note: Note) -> String? {
            let folderID = Folder.normalize(note.folderName)
            guard !folderID.isEmpty, let folder = foldersByID[folderID],
                  let axis = folder.axisID, axisIDs.contains(axis) else { return nil }
            return axis
        }

        // Only real, growth-bearing connections (both endpoints typed & engaged).
        let counted = result.links.filter { $0.isCounted }
        var observations: [Observation] = []

        // 1. Hub — the note at the crossroads of the most connections.
        var linkFreq: [String: Int] = [:]
        for link in counted {
            linkFreq[link.titleA, default: 0] += 1
            linkFreq[link.titleB, default: 0] += 1
        }
        if let (title, count) = linkFreq.max(by: { $0.value < $1.value }), count >= 3 {
            observations.append(Observation(
                kind: .hub, noteTitles: [title], magnitude: Double(count),
                signature: "hub:\(title.lowercased())"))
        }

        // 2. First bridge — an axis pair joined by exactly one counted connection.
        var pairLinks: [String: [ScoredLink]] = [:]
        for link in counted where link.isCrossAxis {
            guard let a = link.axisA, let b = link.axisB else { continue }
            pairLinks[[a, b].sorted().joined(separator: "|"), default: []].append(link)
        }
        if let (key, links) = pairLinks.filter({ $0.value.count == 1 })
            .min(by: { $0.key < $1.key }) {
            observations.append(Observation(
                kind: .firstBridge, axisIDs: key.split(separator: "|").map(String.init),
                noteTitles: [links[0].titleA, links[0].titleB], magnitude: 1,
                signature: "firstBridge:\(key)"))
        }

        // Per-axis: engaged notes, and whether any cross-axis link touches it.
        var noteCount: [String: Int] = [:]
        for note in notes where !note.isStub {
            if let axis = axisID(for: note) { noteCount[axis, default: 0] += 1 }
        }
        var axesWithCrossLink: Set<String> = []
        for link in counted where link.isCrossAxis {
            if let a = link.axisA { axesWithCrossLink.insert(a) }
            if let b = link.axisB { axesWithCrossLink.insert(b) }
        }

        // 3. Isolated axis — has notes, but none reach another part of life.
        let isolated = axes.filter { (noteCount[$0.id] ?? 0) >= 2 && !axesWithCrossLink.contains($0.id) }
        if let axis = isolated.max(by: { (noteCount[$0.id] ?? 0) < (noteCount[$1.id] ?? 0) }) {
            observations.append(Observation(
                kind: .isolatedAxis, axisIDs: [axis.id], magnitude: Double(noteCount[axis.id] ?? 0),
                signature: "isolatedAxis:\(axis.id)"))
        }

        // 4. Momentum — where the most recent session grew you most.
        if let latest = result.sessions.last {
            if let (axisID, points) = latest.cappedDelta.max(by: { $0.value < $1.value }), points > 0 {
                observations.append(Observation(
                    kind: .momentum, axisIDs: [axisID], magnitude: points,
                    signature: "momentum:\(axisID)"))
            }
        }

        // 5. Quiet axis — the engaged part of life that's grown least.
        let engagedAxes = axes.filter { (noteCount[$0.id] ?? 0) >= 1 }
        if engagedAxes.count >= 2,
           let quiet = engagedAxes.min(by: {
               result.revealedTotals.points($0.id) < result.revealedTotals.points($1.id)
           }) {
            observations.append(Observation(
                kind: .quietAxis, axisIDs: [quiet.id],
                magnitude: result.revealedTotals.points(quiet.id),
                signature: "quietAxis:\(quiet.id)"))
        }

        // Most resonant first; larger magnitude breaks ties within a kind.
        return observations.sorted {
            $0.priority != $1.priority ? $0.priority > $1.priority : $0.magnitude > $1.magnitude
        }
    }
}
