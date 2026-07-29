import Foundation
import NuminousCore

// Deterministic UTC dates for reproducible scoring.
func day(_ d: Int) -> Date {
    DateComponents(calendar: Calendar(identifier: .gregorian),
                   timeZone: TimeZone(identifier: "UTC"),
                   year: 2026, month: 1, day: d).date!
}

let golf    = Category(id: "golf",    name: "Golf",          axisID: "body")
let novels  = Category(id: "novels",  name: "Novels",        axisID: "mind")
let friends = Category(id: "friends", name: "Close friends", axisID: "heart")

let h = Harness()

// MARK: - Parsing

h.group("Wikilink parsing") {
    h.eq(WikilinkParser.extract(from: "Golf with [[Sam]] after [[Atomic Habits]]."),
         ["Sam", "Atomic Habits"], "extracts multiple links")
    h.eq(WikilinkParser.extract(from: "[[Sam]] [[sam]] [[SAM]]"),
         ["Sam"], "dedupes case-insensitively, keeps first spelling")
    h.eq(WikilinkParser.extract(from: "[[Portugal trip|summer]]"),
         ["Portugal trip"], "drops alias after pipe")
    h.eq(WikilinkParser.extract(from: "[[  Spaced  ]] not [[]]"),
         ["Spaced"], "trims whitespace, ignores empty")
}

h.group("Note parsing") {
    let text = """
    ---
    category: Golf
    date: 2026-07-29
    interaction: in-person
    depth: 3
    ---

    Played 18 holes with [[Sam]] today.
    """
    let note = NoteParser.parse(text, fallbackTitle: "Untitled")
    h.eq(note.categoryID, "golf", "category slugified")
    h.eq(note.interaction, .inPerson, "interaction 'in-person' normalized")
    h.eq(note.depth, 3, "depth parsed")
    h.eq(note.linkTargets, ["Sam"], "links parsed from body")
    h.check(!note.body.contains("---"), "frontmatter fences stripped from body")

    let titled = NoteParser.parse("---\ntitle: Real\ncategory: diary\n---\nBody", fallbackTitle: "file")
    h.eq(titled.title, "Real", "frontmatter title beats fallback")

    let plain = NoteParser.parse("Plain note with [[Sam]].", fallbackTitle: "p")
    h.check(plain.categoryID == nil, "no frontmatter → untyped")
    h.eq(plain.linkTargets, ["Sam"], "links still parsed without frontmatter")
}

// MARK: - Base credit

h.group("Base credit") {
    let engine = ScoreEngine()
    let note = Note(title: "Round 1", categoryID: "golf", date: day(1), body: "Nice.", sessionID: "s1")
    h.eq(engine.score(notes: [note], categories: [golf]).rawTotals.points("body"),
         10, "manual note credits its axis")

    let stub = Note(title: "Portugal trip", date: day(1), sessionID: "s1", isStub: true)
    h.eq(engine.score(notes: [stub], categories: []).rawTotals.total,
         0, "untyped note contributes nothing")

    let workout = Note(title: "Run", categoryID: "golf", date: day(1),
                       body: "Ran with [[Sam]].", source: .healthKit, sessionID: "s1")
    let sam = Note(title: "Sam", categoryID: "friends", date: day(1), sessionID: "s1")
    let passive = engine.score(notes: [workout, sam], categories: [golf, friends])
    h.eq(passive.rawTotals.points("body"), 4, "passive note earns reduced base credit")
    h.eq(passive.rawTotals.points("heart"), 10, "linked person still earns base")
    h.check(passive.links.isEmpty, "passive notes create no counted edges")
}

// MARK: - The core mechanic: links

h.group("Links — cross-axis beats same-axis (the thesis)") {
    let engine = ScoreEngine()

    let a1 = Note(title: "Round A", categoryID: "golf", date: day(1), body: "With [[Round B]].", sessionID: "s")
    let b1 = Note(title: "Round B", categoryID: "golf", date: day(1), sessionID: "s")
    let same = engine.score(notes: [a1, b1], categories: [golf])

    let a2 = Note(title: "Round A", categoryID: "golf", date: day(1), body: "Discussed [[Atomic Habits]].", sessionID: "s")
    let b2 = Note(title: "Atomic Habits", categoryID: "novels", date: day(1), sessionID: "s")
    let cross = engine.score(notes: [a2, b2], categories: [golf, novels])

    let sameBonus = same.rawTotals.total - 20
    let crossBonus = cross.rawTotals.total - 20
    h.eq(sameBonus, 5, "same-axis link: one axis × 5")
    h.eq(crossBonus, 30, "cross-axis link: two axes × 15")
    h.check(crossBonus > sameBonus, "cross-axis out-earns same-axis")
}

h.group("Links — in-person weighting") {
    let engine = ScoreEngine()
    let round = Note(title: "Round", categoryID: "golf", date: day(1), body: "Golf with [[Sam]].", sessionID: "s")
    let inPerson = Note(title: "Sam", categoryID: "friends", date: day(1), interaction: .inPerson, sessionID: "s")
    let text = Note(title: "Sam", categoryID: "friends", date: day(1), interaction: .text, sessionID: "s")
    let ip = engine.score(notes: [round, inPerson], categories: [golf, friends])
    let tx = engine.score(notes: [round, text], categories: [golf, friends])
    h.check(ip.rawTotals.total > tx.rawTotals.total, "in-person interaction earns more")
    h.eq(ip.links.first?.bonusPerAxis ?? 0, 22.5, "cross bonus 15 × 1.5 in-person multiplier")
}

h.group("Links — untyped endpoints and uniqueness") {
    let engine = ScoreEngine()
    let round = Note(title: "Round", categoryID: "golf", date: day(1), body: "Booked [[Portugal trip]].", sessionID: "s")
    let stub = Note(title: "Portugal trip", date: day(1), sessionID: "s", isStub: true)
    let r = engine.score(notes: [round, stub], categories: [golf])
    h.eq(r.rawTotals.total, 10, "link to untyped note earns no bonus")
    h.eq(r.links.first?.isCounted, false, "untyped link marked not counted")

    let a = Note(title: "A", categoryID: "golf", date: day(1), body: "See [[B]] and [[B]].", sessionID: "s")
    let b = Note(title: "B", categoryID: "novels", date: day(1), body: "Back to [[A]].", sessionID: "s")
    let counted = engine.score(notes: [a, b], categories: [golf, novels]).links.filter(\.isCounted)
    h.eq(counted.count, 1, "reciprocal / repeated links count once")
}

// MARK: - Retroactive reflow

h.group("Retroactive reflow") {
    let engine = ScoreEngine()
    let note = Note(title: "Round", categoryID: "golf", date: day(1), body: "Solo.", sessionID: "s")
    let asBody = engine.score(notes: [note], categories: [Category(id: "golf", name: "Golf", axisID: "body")])
    let asMind = engine.score(notes: [note], categories: [Category(id: "golf", name: "Golf", axisID: "mind")])
    h.eq(asBody.rawTotals.points("body"), 10, "starts on Body")
    h.eq(asMind.rawTotals.points("mind"), 10, "remap moves growth to Mind")
    h.eq(asMind.rawTotals.points("body"), 0, "no growth left on old axis")
}

// MARK: - Sessions, caps, delayed reveal

h.group("Sessions — delayed reveal") {
    let engine = ScoreEngine()
    let n1 = Note(title: "Day one", categoryID: "golf", date: day(1), sessionID: "s1")
    let n2 = Note(title: "Day two", categoryID: "golf", date: day(2), sessionID: "s2")
    let r = engine.score(notes: [n1, n2], categories: [golf])
    h.eq(r.revealedTotals.points("body"), 10, "earlier session revealed")
    h.eq(r.pendingTotals.points("body"), 10, "latest session pending until next open")

    let a = Note(title: "A", categoryID: "golf", date: day(1), body: "Later read [[B]].", sessionID: "s1")
    let b = Note(title: "B", categoryID: "novels", date: day(2), sessionID: "s2")
    let r2 = engine.score(notes: [a, b], categories: [golf, novels])
    h.eq(r2.revealedTotals.points("body"), 10, "reveal excludes later cross-link")
    h.eq(r2.pendingTotals.points("mind"), 25, "pending has B base + cross bonus")
    h.eq(r2.pendingTotals.points("body"), 15, "cross bonus also credits body, pending")
}

h.group("Caps — consistency beats binge") {
    let engine = ScoreEngine()
    let binge = (0..<20).map { Note(title: "n\($0)", categoryID: "golf", date: day(1), sessionID: "binge") }
    let r = engine.score(notes: binge, categories: [golf])
    h.eq(r.rawTotals.points("body"), 200, "raw growth uncapped internally")
    h.eq(r.pendingTotals.total, 60, "session cap clamps a binge to 60")

    var cfg = ScoringConfig.default
    cfg.sessionGrowthCap = 10_000
    cfg.softDailyCap = 100
    cfg.softCapScale = 0.25
    let soft = ScoreEngine(config: cfg)
        .score(notes: (0..<20).map { Note(title: "n\($0)", categoryID: "golf", date: day(1), sessionID: "s") },
               categories: [golf])
    h.eq(soft.pendingTotals.total, 125, "soft daily cap: 100 full + 100×0.25, nothing lost")
}

// MARK: - Stages

h.group("Stages") {
    let r = StageResolver()
    h.eq(r.stage(for: 0).id, "sketch", "starts as sketch")
    h.eq(r.stage(for: 59).id, "sketch", "just below outline threshold")
    h.eq(r.stage(for: 60).id, "outline", "reaches outline")
    h.eq(r.stage(for: 1_000).id, "defined", "defined tier")
    h.eq(r.stage(for: 5_000).id, "realized", "final likeness")
    h.eq(r.fidelity(for: 120), 0.5, "fidelity interpolates halfway")
    h.eq(r.fidelity(for: 10_000), 1, "fidelity caps at 1 at final stage")
}

// MARK: - New-category axis suggestion

h.group("Axis classifier") {
    let classifier = AxisClassifier()
    let axes = Axis.defaultSet

    // Too little data → ask the user directly (nothing to compare against).
    let cold = classifier.suggestAxis(forNewCategoryNamed: "Golf",
                                      existingCategories: [], axes: axes)
    h.eq(cold, .askUser, "cold start asks the user to pick")

    // With enough mapped categories, suggest by similarity to the user's own set.
    let existing = [
        Category(id: "novels",  name: "Novels",         axisID: "mind"),
        Category(id: "courses", name: "Online courses", axisID: "mind"),
        Category(id: "gym",     name: "Gym workouts",    axisID: "body"),
        Category(id: "family",  name: "Family",          axisID: "heart"),
    ]
    let suggestion = classifier.suggestAxis(forNewCategoryNamed: "Gym classes",
                                            existingCategories: existing, axes: axes)
    if case let .suggest(axisID, confidence) = suggestion {
        h.eq(axisID, "body", "new 'Gym classes' suggested onto Body (matches 'Gym workouts')")
        h.check(confidence > 0, "suggestion carries a positive confidence")
    } else {
        h.check(false, "expected a suggestion, got \(suggestion)")
    }
}

// MARK: - Markdown round-trip

h.group("Note serialization round-trips") {
    let original = Note(
        title: "Golf: back nine", categoryID: "golf", date: day(29),
        body: "Played with [[Sam]] after [[Atomic Habits]].",
        interaction: .inPerson, depth: 4, source: .manual, sessionID: "evening-1"
    )
    let text = NoteSerializer.markdown(for: original)
    let reparsed = NoteParser.parse(text, fallbackTitle: "wrong")

    h.eq(reparsed.title, original.title, "title survives (even with a colon)")
    h.eq(reparsed.categoryID, original.categoryID, "category survives")
    h.eq(reparsed.date, original.date, "date survives")
    h.eq(reparsed.interaction, original.interaction, "interaction survives")
    h.eq(reparsed.depth, original.depth, "depth survives")
    h.eq(reparsed.sessionID, original.sessionID, "session survives")
    h.eq(reparsed.linkTargets, original.linkTargets, "links survive in the body")
}

exit(Int32(h.summarize()))
