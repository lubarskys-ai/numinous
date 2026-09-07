import Foundation

/// When a friend's team next plays.
///
/// The point is not sport. It is that "how are you" is a hard message to start and "big game
/// tonight" is an easy one — so the app watches for the moment when there is an obvious reason
/// to call someone, and says so. A fixture list is the rare piece of public information that
/// tells you something about a PERSON.
///
/// WHERE THIS COMES FROM, AND WHAT IT COSTS. ESPN publish the fixtures behind their own site as
/// plain JSON, with no key and no account. Two calls: the league's teams, and one team's
/// schedule. Both are cached — teams for a week (they change once a year), a schedule for six
/// hours — so a vault full of fans costs a handful of requests a day.
///
/// What leaves the phone is a team name and nothing else: not who supports them, not that
/// anybody supports them, not a note, not a location. It is the same request a browser makes
/// when anyone looks up a fixture list — and unlike the Readwise import, the other place this
/// app reaches the network, it carries no account and no credential of any kind.
///
/// The endpoints are public but undocumented, which means they can change without warning.
/// Everything here fails quietly and returns nil when it does: a missing nudge is a
/// disappointment, a crash is a bug.
enum SportsService {

    /// A fixture, already resolved to the thing worth saying out loud.
    struct Game: Equatable {
        let date: Date
        let team: String        // the friend's team, as ESPN names it
        let opponent: String
        let home: Bool
        let league: String      // "NFL", "College Football" — for the nudge's wording

        /// "Alabama vs Kentucky" / "Alabama at Kentucky".
        var line: String { "\(team) \(home ? "vs" : "at") \(opponent)" }
    }

    /// The leagues searched for a professional team, in the order a city name should resolve.
    /// A typed "Chicago" matches a team in several of these; the soonest game wins, which is
    /// the right answer to "is there a game on".
    private static let proLeagues: [(path: String, name: String)] = [
        ("football/nfl", "NFL"), ("basketball/nba", "NBA"), ("baseball/mlb", "MLB"),
        ("hockey/nhl", "NHL"), ("soccer/usa.1", "MLS"),
    ]

    /// And for a college. Football first: it is what "my college team" usually means.
    private static let collegeLeagues: [(path: String, name: String)] = [
        ("football/college-football", "College Football"),
        ("basketball/mens-college-basketball", "College Basketball"),
    ]

    // MARK: - The one thing this is for

    /// The soonest game within `days` for whatever the user typed, or nil.
    ///
    /// `query` is deliberately forgiving because people do not write team names the way a
    /// database does. "Bears", "Chicago Bears", "Chicago", "Alabama", "Roll Tide" — the first
    /// four resolve; the fifth does not, and returning nothing is the correct answer to a
    /// nickname nobody indexed.
    static func nextGame(for query: String, college: Bool, withinDays days: Int = 3) async -> Game? {
        let q = normalize(query)
        guard q.count >= 3 else { return nil }
        let deadline = Date().addingTimeInterval(Double(days) * 86_400)

        var soonest: Game?
        for league in (college ? collegeLeagues : proLeagues) {
            guard let team = await team(matching: q, in: league.path) else { continue }
            guard let game = await nextGame(teamID: team.id, teamName: team.name,
                                            league: league) else { continue }
            guard game.date <= deadline else { continue }
            if soonest == nil || game.date < soonest!.date { soonest = game }
        }
        return soonest
    }

    // MARK: - The list you choose from

    /// One choosable team. `league` is what the picker groups by; `name` is what gets stored,
    /// and is exactly a string `nextGame(for:)` will resolve, so choosing from the list can
    /// never produce a team that then fails to be found.
    struct TeamOption: Identifiable, Hashable, Comparable {
        let id: String          // league path + team id, unique across leagues
        let name: String
        let league: String
        static func < (a: TeamOption, b: TeamOption) -> Bool { a.name < b.name }
    }

    /// Every team you might support, for the picker.
    ///
    /// A COLLEGE IS LISTED AS A SCHOOL, not as a team. Somebody supports Alabama, not "Alabama
    /// Crimson Tide" as distinct from "Alabama Crimson Tide" the basketball side — so the two
    /// college leagues are folded into one list of schools, and the stored name resolves in
    /// both. Whichever plays first is the one you hear about.
    ///
    /// Everything is listed, including the small schools. Searching makes the size free, and
    /// leaving out somebody's alma mater because it plays in Division III would be worse than
    /// a long list nobody has to read.
    static func options(college: Bool) async -> [TeamOption] {
        var seen = Set<String>()
        var out: [TeamOption] = []
        for league in (college ? collegeLeagues : proLeagues) {
            for (id, team) in await rawTeams(in: league.path) {
                let name = college ? team.location : team.display
                guard !name.isEmpty else { continue }
                // ESPN NUMBERS TEAMS PER LEAGUE, so ids collide across them — the Bears are 3
                // and so is somebody in the NBA. Keying the dedupe on the bare id quietly threw
                // away most of four leagues: searching "Chicago" returned the Bears and the Fire
                // and no Bulls, Cubs, White Sox or Blackhawks. The league is part of the key.
                let key = college ? normalize(name) : "\(league.path)|\(id)"
                guard seen.insert(key).inserted else { continue }
                out.append(TeamOption(id: "\(league.path)|\(id)", name: name,
                                      league: college ? "Colleges" : league.name))
            }
        }
        return out.sorted()
    }

    // MARK: - Teams

    private struct Team { let id: String; let name: String }

    private struct RawTeam { let display: String; let location: String; let names: [String] }

    /// A league's teams, straight off the cached JSON. One reader for both the picker and the
    /// matcher, so what you can choose and what can be resolved are the same set by construction.
    private static func rawTeams(in leaguePath: String) async -> [(String, RawTeam)] {
        guard let data = await cached(
            url: "https://site.api.espn.com/apis/site/v2/sports/\(leaguePath)/teams?limit=1000",
            as: "teams-\(leaguePath.replacingOccurrences(of: "/", with: "-"))",
            staleAfter: 7 * 86_400),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sports = root["sports"] as? [[String: Any]],
              let leagues = sports.first?["leagues"] as? [[String: Any]],
              let entries = leagues.first?["teams"] as? [[String: Any]] else { return [] }

        return entries.compactMap { entry in
            guard let t = entry["team"] as? [String: Any], let id = t["id"] as? String else { return nil }
            let display = (t["displayName"] as? String) ?? ""
            let location = (t["location"] as? String) ?? ""
            let names = [display, (t["name"] as? String) ?? "", location,
                         (t["shortDisplayName"] as? String) ?? "",
                         (t["abbreviation"] as? String) ?? ""].map(normalize)
            return (id, RawTeam(display: display, location: location, names: names))
        }
    }

    private static func team(matching q: String, in leaguePath: String) async -> Team? {
        // An exact hit on any of a team's names beats a partial one anywhere. Without that,
        // "Chicago" matched "Chicago Bears" and also, by substring, nothing sensible at all —
        // and a typed "Jets" would have taken whichever team happened to be listed first.
        var partial: Team?
        for (id, t) in await rawTeams(in: leaguePath) {
            if t.names.contains(q) { return Team(id: id, name: t.display) }
            if partial == nil, t.names.contains(where: { !$0.isEmpty && $0.contains(q) }) {
                partial = Team(id: id, name: t.display)
            }
        }
        return partial
    }

    // MARK: - Schedule

    private static func nextGame(teamID: String, teamName: String,
                                 league: (path: String, name: String)) async -> Game? {
        guard let data = await cached(
            url: "https://site.api.espn.com/apis/site/v2/sports/\(league.path)/teams/\(teamID)/schedule",
            as: "sched-\(league.path.replacingOccurrences(of: "/", with: "-"))-\(teamID)",
            staleAfter: 6 * 3600),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else { return nil }

        let now = Date()
        var best: Game?
        for event in events {
            guard let iso = event["date"] as? String,
                  let date = isoDate(iso), date > now,
                  let comps = event["competitions"] as? [[String: Any]],
                  let competitors = comps.first?["competitors"] as? [[String: Any]] else { continue }

            var mine: String?, theirs: String?, atHome = false
            for c in competitors {
                guard let t = c["team"] as? [String: Any],
                      let name = t["displayName"] as? String else { continue }
                if (t["id"] as? String) == teamID {
                    mine = name
                    atHome = (c["homeAway"] as? String) == "home"
                } else {
                    theirs = name
                }
            }
            guard let mine, let theirs else { continue }
            if best == nil || date < best!.date {
                best = Game(date: date, team: mine, opponent: theirs, home: atHome, league: league.name)
            }
        }
        return best
    }

    // MARK: - Plumbing

    private static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    private static var folder: URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            .appendingPathComponent("sports", isDirectory: true)
    }

    /// Fetch, or reuse what is on disk while it is still fresh.
    ///
    /// A stale copy is served when the network fails, deliberately: last week's fixture list is
    /// a far better answer on a plane than no answer, and the only cost of being wrong is a
    /// nudge about a game that has already happened.
    private static func cached(url: String, as key: String, staleAfter: TimeInterval) async -> Data? {
        guard let folder, let remote = URL(string: url) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(key + ".json")

        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < staleAfter,
           let data = try? Data(contentsOf: file) {
            return data
        }

        var request = URLRequest(url: remote)
        request.timeoutInterval = 12
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
            try? data.write(to: file, options: .atomic)
            return data
        }
        return try? Data(contentsOf: file)      // stale beats nothing
    }
}
