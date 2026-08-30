import Foundation

/// How much a place grows you — the travel half of the intensity dial.
///
/// Three signals, weighted the way the wellbeing research on travel weights them:
///
/// * **Distance.** The farther from home, the more the trip does for you — and it
///   saturates: crossing from your town to another region is a bigger step than
///   crossing from there to another continent.
/// * **A night away.** The gain arrives as soon as you sleep somewhere else. Two
///   weeks isn't fourteen one-nighters, so the credit is front-loaded on the first
///   night and barely moves after that.
/// * **New ground.** Novelty — an unfamiliar place you have to work out — is where
///   most of the benefit comes from. A first visit outscores a return at the same
///   distance.
///
/// Every term only ever adds, so a place can't score lower here than it would on
/// distance alone.
public enum TravelValue {

    /// How far a place must sit from anywhere you've already recorded before it
    /// counts as new ground, in kilometres. Roughly "a different region", not
    /// "a street you haven't walked".
    public static let newGroundRadiusKm = 250.0

    /// Map a place's distance from home, trip length, and novelty onto the 1–5
    /// intensity dial everything else uses. `days` is inclusive trip length —
    /// 1 when the note carries no trip range.
    public static func intensity(distanceKm: Double, days: Int, isNewGround: Bool) -> Int {
        var score = 3.0
        switch distanceKm {
        case ..<50:  score += 0     // around town
        case ..<800: score += 1     // regional
        default:     score += 2     // far afield
        }
        // One night away carries most of the effect; a long trip adds a little more.
        if days >= 5 { score += 0.85 } else if days >= 2 { score += 0.6 }
        if isNewGround { score += 0.6 }
        return min(5, max(1, Int(score.rounded())))
    }
}

extension TravelValue {

    /// The intensity plus the terms behind it, so a place can show its own reasoning instead
    /// of just a number. `reasons` holds only the terms that actually lifted the score,
    /// strongest first; distance is left as a number for the caller to format in the reader's
    /// own units.
    public struct Reading: Equatable {
        public let intensity: Int
        public let distanceKm: Double
        public let days: Int
        public let isNewGround: Bool
        public let reasons: [String]
    }

    public static func reading(distanceKm: Double, days: Int, isNewGround: Bool) -> Reading {
        var reasons: [String] = []
        if isNewGround { reasons.append("new ground") }
        switch distanceKm {
        case ..<50:  break
        case ..<800: reasons.append("another region")
        default:     reasons.append("far afield")
        }
        if days >= 5 { reasons.append("a long stay") } else if days >= 2 { reasons.append("a night away") }
        return Reading(intensity: intensity(distanceKm: distanceKm, days: days, isNewGround: isNewGround),
                       distanceKm: distanceKm, days: days, isNewGround: isNewGround, reasons: reasons)
    }
}

extension TravelValue {

    /// A point you recorded being at.
    public struct GeoPoint: Equatable {
        public let latitude: Double
        public let longitude: Double
        public let date: Date
        public init(latitude: Double, longitude: Double, date: Date) {
            self.latitude = latitude; self.longitude = longitude; self.date = date
        }
    }

    /// One patch of world — every point within `newGroundRadiusKm` of the first one you
    /// recorded there. `anchor` indexes that first point, so a region is named and dated by
    /// your first visit to it.
    public struct Region: Equatable {
        public let anchor: Int
        public let memberIndices: [Int]
    }

    /// Gather points into regions, oldest first, so each region anchors on your earliest visit.
    /// Greedy against the anchors: a point joins the first region whose anchor is within the
    /// radius, or starts one of its own. Indices refer to the array as passed in.
    public static func groupIntoRegions(_ points: [GeoPoint]) -> [Region] {
        var anchors: [(index: Int, point: GeoPoint, members: [Int])] = []
        for i in points.indices.sorted(by: { points[$0].date < points[$1].date }) {
            let p = points[i]
            if let a = anchors.firstIndex(where: {
                distanceKm($0.point.latitude, $0.point.longitude, p.latitude, p.longitude) <= newGroundRadiusKm
            }) {
                anchors[a].members.append(i)
            } else {
                anchors.append((i, p, [i]))
            }
        }
        return anchors.map { Region(anchor: $0.index, memberIndices: $0.members) }
    }

    /// Great-circle distance between two lat/long points, in kilometres (haversine).
    public static func distanceKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180, dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return r * 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
    }
}
