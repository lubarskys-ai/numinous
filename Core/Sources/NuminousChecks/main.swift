import Foundation
import NuminousCore

func day(_ d: Int) -> Date {
    DateComponents(calendar: Calendar(identifier: .gregorian),
                   timeZone: TimeZone(identifier: "UTC"),
                   year: 2026, month: 1, day: d).date!
}

// Folders carry a category and map to an axis.
let people = Folder(name: "people", category: "Relationships", axisID: "heart")
let books  = Folder(name: "books",  category: "Cognition",     axisID: "mind")
let sport  = Folder(name: "sport",  category: "Fitness",       axisID: "body")
let diary  = Folder(name: "diary",  category: "Journal",       axisID: "spirit")
let allFolders = [people, books, sport, diary]

let h = Harness()

// MARK: - Parsing

h.group("Wikilink parsing") {
    h.eq(WikilinkParser.extract(from: "Golf with [[people/Sam]] after [[books/Atomic Habits]]."),
         ["people/Sam", "books/Atomic Habits"], "extracts folder-pathed links")
    h.eq(WikilinkParser.extract(from: "[[people/Sam]] [[People/sam]]"),
         ["people/Sam"], "dedupes case-insensitively")
    h.eq(WikilinkParser.extract(from: "[[people/Sam|Sammy]]"),
         ["people/Sam"], "drops alias after pipe")
}

h.group("Note folder + name") {
    let n = Note(title: "people/Sam")
    h.eq(n.folderName, "people", "folder is the path prefix")
    h.eq(n.displayName, "Sam", "display name is after the slash")
    let loose = Note(title: "Loose thought")
    h.eq(loose.folderName, "", "no slash → no folder")
    h.eq(loose.displayName, "Loose thought", "no slash → whole title is the name")
}

h.group("Note parsing") {
    let text = """
    ---
    title: people/Sam
    date: 2026-07-29
    intensity: 5
    location: Pebble Beach
    ---

    Met [[books/Atomic Habits]] discussion in person.
    """
    let note = NoteParser.parse(text, fallbackTitle: "x")
    h.eq(note.title, "people/Sam", "title parsed")
    h.eq(note.intensity, 5, "intensity parsed")
    h.eq(note.location, "Pebble Beach", "location parsed")
    h.eq(note.linkTargets, ["books/Atomic Habits"], "links parsed from body")
}

// MARK: - Base credit

h.group("Base credit + intensity") {
    let engine = ScoreEngine()
    // Intensity 3 is neutral (×1) → base 10.
    let n3 = Note(title: "sport/Run", date: day(1), body: "ok", intensity: 3, sessionID: "s")
    h.eq(engine.score(notes: [n3], folders: allFolders).rawTotals.points("body"), 10, "intensity 3 = ×1")
    // Intensity 5 (×2) → base 20.
    let n5 = Note(title: "sport/Run", date: day(1), body: "ok", intensity: 5, sessionID: "s")
    h.eq(engine.score(notes: [n5], folders: allFolders).rawTotals.points("body"), 20, "intensity 5 = ×2")
    // Intensity 1 (×0.5) → base 5.
    let n1 = Note(title: "sport/Run", date: day(1), body: "ok", intensity: 1, sessionID: "s")
    h.eq(engine.score(notes: [n1], folders: allFolders).rawTotals.points("body"), 5, "intensity 1 = ×0.5")

    // A note in an unmapped/unknown folder contributes nothing.
    let orphan = Note(title: "mystery/Thing", date: day(1), sessionID: "s")
    h.eq(engine.score(notes: [orphan], folders: allFolders).rawTotals.total, 0, "unknown folder = zero growth")
}

// MARK: - Links (the thesis) + folder-derived axes

h.group("Links — cross-axis beats same-axis") {
    let engine = ScoreEngine()
    // Same-axis: two Body notes (both in sport/) linked, neutral intensity.
    let a1 = Note(title: "sport/A", date: day(1), body: "with [[sport/B]]", intensity: 3, sessionID: "s")
    let b1 = Note(title: "sport/B", date: day(1), intensity: 3, sessionID: "s")
    let same = engine.score(notes: [a1, b1], folders: allFolders)

    // Cross-axis: Body ↔ Mind.
    let a2 = Note(title: "sport/A", date: day(1), body: "read [[books/Habit]]", intensity: 3, sessionID: "s")
    let b2 = Note(title: "books/Habit", date: day(1), intensity: 3, sessionID: "s")
    let cross = engine.score(notes: [a2, b2], folders: allFolders)

    h.eq(same.links.first?.bonusPerAxis ?? 0, 5, "same-axis edge bonus 5")
    h.eq(cross.links.first?.bonusPerAxis ?? 0, 15, "cross-axis edge bonus 15")
    h.eq(same.rawTotals.total - 20, 5, "same-axis link total (no breadth: only 1 axis)")
    h.check(cross.rawTotals.total > same.rawTotals.total, "cross-axis out-earns same-axis")
}

h.group("Links — intensity scales the bonus") {
    let engine = ScoreEngine()
    // Cross-axis link between two profound (×2) notes → bonus 15 × 2 = 30 per axis.
    let a = Note(title: "sport/A", date: day(1), body: "[[books/B]]", intensity: 5, sessionID: "s")
    let b = Note(title: "books/B", date: day(1), intensity: 5, sessionID: "s")
    let r = engine.score(notes: [a, b], folders: allFolders)
    h.eq(r.links.first?.bonusPerAxis ?? 0, 30, "cross bonus 15 × avg intensity 2 = 30")
}

h.group("Links — untyped endpoint not counted") {
    let engine = ScoreEngine()
    let a = Note(title: "sport/A", date: day(1), body: "[[mystery/Z]]", intensity: 3, sessionID: "s")
    let z = Note(title: "mystery/Z", date: day(1), intensity: 3, sessionID: "s", isStub: true)
    let r = engine.score(notes: [a, z], folders: allFolders)
    h.eq(r.rawTotals.total, 10, "only the mapped note's base counts")
    h.eq(r.links.first?.isCounted, false, "link to unknown folder not counted")
}

// MARK: - Retroactive reflow

h.group("Retroactive reflow (remap a folder's axis)") {
    let engine = ScoreEngine()
    let note = Note(title: "sport/Round", date: day(1), body: "solo", intensity: 3, sessionID: "s")
    let asBody = engine.score(notes: [note], folders: [Folder(name: "sport", category: "Fitness", axisID: "body")])
    let asMind = engine.score(notes: [note], folders: [Folder(name: "sport", category: "Fitness", axisID: "mind")])
    h.eq(asBody.rawTotals.points("body"), 10, "starts on Body")
    h.eq(asMind.rawTotals.points("mind"), 10, "remap moves growth to Mind")
    h.eq(asMind.rawTotals.points("body"), 0, "nothing left on old axis")
}

// MARK: - Sessions, caps, delayed reveal

h.group("Sessions — delayed reveal") {
    let engine = ScoreEngine()
    let n1 = Note(title: "sport/One", date: day(1), intensity: 3, sessionID: "s1")
    let n2 = Note(title: "sport/Two", date: day(2), intensity: 3, sessionID: "s2")
    let r = engine.score(notes: [n1, n2], folders: allFolders)
    h.eq(r.revealedTotals.points("body"), 10, "earlier session revealed")
    h.eq(r.pendingTotals.points("body"), 10, "latest session pending")
}

h.group("Caps — binge is clamped") {
    let engine = ScoreEngine() // sessionGrowthCap 90
    let binge = (0..<20).map { Note(title: "sport/n\($0)", date: day(1), intensity: 3, sessionID: "binge") }
    let r = engine.score(notes: binge, folders: allFolders)
    h.eq(r.rawTotals.points("body"), 200, "raw uncapped internally")
    h.eq(r.pendingTotals.total, 90, "session cap clamps to 90")
}

// MARK: - Stages

h.group("Stages") {
    let resolver = StageResolver()
    h.eq(resolver.stage(for: 0).id, "sketch", "starts as sketch")
    h.eq(resolver.stage(for: 60).id, "outline", "reaches outline")
    h.eq(resolver.stage(for: 1_000).id, "defined", "defined tier")
    h.eq(resolver.fidelity(for: 120), 0.5, "fidelity interpolates halfway")
}

// MARK: - Folder axis suggestion

h.group("Folder axis classifier") {
    let classifier = AxisClassifier()
    let axes = Axis.defaultSet
    h.eq(classifier.suggestAxis(forNewFolderNamed: "people", existingFolders: [], axes: axes),
         .askUser, "cold start asks the user")
    let existing = [
        Folder(name: "novels",  category: "Cognition", axisID: "mind"),
        Folder(name: "courses", category: "Learning",  axisID: "mind"),
        Folder(name: "gym",     category: "Fitness",   axisID: "body"),
        Folder(name: "family",  category: "Relationships", axisID: "heart"),
        Folder(name: "poetry",  category: "Meaning",   axisID: "meaning"),
        Folder(name: "meals",   category: "Nutrition", axisID: "gut"),
        Folder(name: "authors", category: "Authors",   axisID: "influences"),
    ]
    if case let .suggest(axisID, confidence) = classifier.suggestAxis(forNewFolderNamed: "courses-advanced", existingFolders: existing, axes: axes) {
        h.eq(axisID, "mind", "'courses-advanced' suggested onto Mind (matches 'courses')")
        h.check(confidence > 0, "suggestion has positive confidence")
    } else {
        h.check(false, "expected a suggestion")
    }
}

// MARK: - Markdown round-trip

h.group("Note serialization round-trips") {
    let original = Note(title: "people/Sam", date: day(29),
                        body: "Golf with [[sport/Back nine]] today.",
                        intensity: 4, location: "Pebble Beach", sessionID: "evening-1")
    let reparsed = NoteParser.parse(NoteSerializer.markdown(for: original), fallbackTitle: "x")
    h.eq(reparsed.title, original.title, "title survives")
    h.eq(reparsed.date, original.date, "date survives")
    h.eq(reparsed.intensity, original.intensity, "intensity survives")
    h.eq(reparsed.location, original.location, "location survives")
    h.eq(reparsed.sessionID, original.sessionID, "session survives")
    h.eq(reparsed.linkTargets, original.linkTargets, "links survive in body")
}

// MARK: - Import identity (origin)

h.group("Note origin (idempotent imports)") {
    let n = Note(title: "people/Sam", origin: NoteOrigin(source: "contacts", externalID: "ABC-123"))
    let back = try! JSONDecoder().decode(Note.self, from: JSONEncoder().encode(n))
    h.check(back.origin?.source == "contacts", "origin source survives Codable")
    h.check(back.origin?.externalID == "ABC-123", "origin id survives Codable")
    h.check(Note(title: "x").origin == nil, "hand-written notes have no origin")

    // Origin is metadata only — it must not change scoring.
    let engine = ScoreEngine()
    let withOrigin = engine.score(
        notes: [Note(title: "sport/A", date: day(1), body: "[[books/B]]", intensity: 3,
                     origin: NoteOrigin(source: "contacts", externalID: "1"), sessionID: "s"),
                Note(title: "books/B", date: day(1), intensity: 3, sessionID: "s")],
        folders: allFolders)
    let without = engine.score(
        notes: [Note(title: "sport/A", date: day(1), body: "[[books/B]]", intensity: 3, sessionID: "s"),
                Note(title: "books/B", date: day(1), intensity: 3, sessionID: "s")],
        folders: allFolders)
    h.eq(withOrigin.rawTotals.total, without.rawTotals.total, "origin doesn't affect scoring")
}

h.group("Connection complexity (bridging more axes grows more)") {
    let engine = ScoreEngine()
    // X (Body) bridges Mind + Heart via links → touches 3 distinct axes.
    let x = Note(title: "sport/X", date: day(1), body: "[[books/A]] and [[people/B]]", intensity: 3, sessionID: "s")
    let a = Note(title: "books/A", date: day(1), intensity: 3, sessionID: "s")
    let b = Note(title: "people/B", date: day(1), intensity: 3, sessionID: "s")
    let r = engine.score(notes: [x, a, b], folders: allFolders)
    // body: base 10 + edge(x-A)15 + edge(x-B)15 + breadth 6×C(3,2)=18 = 58
    h.eq(r.rawTotals.points("body"), 58, "hub bridging 3 axes earns breadth 6×C(3,2)=18")
    // A bridges Mind+Body (D=2): base 10 + edge 15 + breadth 6 = 31
    h.eq(r.rawTotals.points("mind"), 31, "2-axis note earns breadth 6×C(2,2)=6")

    // A note whose links stay within one axis bridges nothing → no breadth bonus.
    let p = Note(title: "sport/P", date: day(1), body: "[[sport/Q]]", intensity: 3, sessionID: "s")
    let q = Note(title: "sport/Q", date: day(1), intensity: 3, sessionID: "s")
    let same = engine.score(notes: [p, q], folders: allFolders)
    h.eq(same.rawTotals.points("body"), 25, "same-axis links earn no breadth (base 20 + edge 5)")
}

h.group("Reflection engine (grounded observations)") {
    let engine = ScoreEngine()
    let reflect = ReflectionEngine()
    let axes = Axis.defaultSet

    // Sam is a crossroads: linked from a Body note, a Mind note, and a diary note.
    let golf = Note(title: "sport/Golf", date: day(1), body: "[[people/Sam]] and [[books/Atomic Habits]]", intensity: 3, sessionID: "s")
    let read = Note(title: "books/Atomic Habits", date: day(1), body: "[[people/Sam]]", intensity: 3, sessionID: "s")
    let jrnl = Note(title: "diary/Evening", date: day(1), body: "grateful for [[people/Sam]]", intensity: 3, sessionID: "s")
    let sam  = Note(title: "people/Sam", date: day(1), intensity: 3, sessionID: "s")
    let notes = [golf, read, jrnl, sam]
    let result = engine.score(notes: notes, folders: allFolders, axes: axes)
    let obs = reflect.observe(notes: notes, folders: allFolders, axes: axes, result: result)

    h.check(!obs.isEmpty, "produces at least one observation")
    h.check(obs.contains { $0.kind == .hub && $0.noteTitles.contains("people/Sam") },
            "spots the hub note (Sam)")
    h.check(obs.contains { $0.kind == .firstBridge }, "spots a fresh axis bridge")

    // Observations are grounded: an empty graph says nothing.
    let empty = reflect.observe(notes: [], folders: allFolders, axes: axes,
                                result: engine.score(notes: [], folders: allFolders, axes: axes))
    h.check(empty.isEmpty, "no graph → no observations (never invents)")

    // A dormant note contributes no hub/observation weight.
    let stub = Note(title: "people/Ghost", intensity: 3, isStub: true)
    let withStub = notes + [stub]
    let obs2 = reflect.observe(notes: withStub, folders: allFolders, axes: axes,
                               result: engine.score(notes: withStub, folders: allFolders, axes: axes))
    h.check(!obs2.contains { $0.noteTitles.contains("people/Ghost") },
            "dormant notes don't drive reflections")
}

h.group("Auto-linking (deterministic)") {
    let linker = AutoLinker()
    let cands = [("Sam", "people/Sam"), ("Atomic Habits", "books/Atomic Habits"), ("Deep Work", "books/Deep Work")]
    let s1 = linker.suggest(in: "had coffee with Sam and talked about Atomic Habits", candidates: cands)
    h.eq(s1.map(\.target).sorted(), ["books/Atomic Habits", "people/Sam"], "finds mentioned notes")
    h.check(!s1.map(\.target).contains("books/Deep Work"), "doesn't invent unmentioned links")

    let s2 = linker.suggest(in: "met Samuel for lunch", candidates: [("Sam", "people/Sam")])
    h.check(s2.isEmpty, "'Sam' doesn't match inside 'Samuel'")

    let s3 = linker.suggest(in: "coffee with [[people/Sam]] today", candidates: cands)
    h.check(!s3.map(\.target).contains("people/Sam"), "skips names already linked")

    let s4 = linker.suggest(in: "reading Atomic Habits", candidates: [("Atomic", "x/Atomic"), ("Atomic Habits", "books/Atomic Habits")])
    h.eq(s4.map(\.target), ["books/Atomic Habits"], "prefers the longer match over a substring")

    // Flexible (punctuation/case-tolerant) matching for cleaned-name replacement.
    let text = "breakfast at Dunkin' Donuts"
    if let r = AutoLinker.flexibleRange(of: "dunkin donuts", in: text) {
        h.eq(String(text[r]), "Dunkin' Donuts", "flexibleRange spans the apostrophe'd words")
    } else {
        h.check(false, "flexibleRange finds 'dunkin donuts' in \"Dunkin' Donuts\"")
    }
    h.check(AutoLinker.flexibleRange(of: "Sam", in: "met Samuel today") == nil, "flexibleRange respects word boundaries (not inside Samuel)")
    h.check(AutoLinker.flexibleRange(of: "san francisco", in: "flew to San Francisco") != nil, "flexibleRange matches across a plain space + case")
}

h.group("Multi-axis folders (split growth)") {
    let engine = ScoreEngine()
    // A "golf" folder set to grow Body + Mind + Spirit splits each note 3 ways.
    let golf = Folder(name: "golf", category: "Recreation", axisIDs: ["body", "mind", "spirit"])
    let note = Note(title: "golf/Round", date: day(1), intensity: 3, sessionID: "s")
    let r = engine.score(notes: [note], folders: [golf], axes: Axis.defaultSet)
    h.eq(r.rawTotals.points("body"), 10.0 / 3, "base credit split across 3 axes (body)")
    h.eq(r.rawTotals.points("mind"), 10.0 / 3, "base credit split across 3 axes (mind)")
    h.eq(r.rawTotals.points("spirit"), 10.0 / 3, "base credit split across 3 axes (spirit)")
    h.eq(r.rawTotals.total, 10, "total is unchanged — just divided among axes")

    // A single-axis folder still behaves exactly as before.
    let single = Folder(name: "sport", category: "Fitness", axisID: "body")
    let s = engine.score(notes: [Note(title: "sport/Run", date: day(1), intensity: 3, sessionID: "s")], folders: [single])
    h.eq(s.rawTotals.points("body"), 10, "single-axis folder unchanged (full credit)")
}

h.group("Wikilink rewrite (rename/move propagation)") {
    let body = "breakfast at [[entertainment/restaurant/dunkin donuts]] with [[people/Sam]]"
    let moved = WikilinkParser.rewrite(in: body) {
        $0.lowercased() == "entertainment/restaurant/dunkin donuts" ? "travel/restaurant/dunkin donuts" : $0
    }
    h.eq(moved, "breakfast at [[travel/restaurant/dunkin donuts]] with [[people/Sam]]", "rewrites the moved link, leaves others")
    h.check(WikilinkParser.extract(from: moved).contains("travel/restaurant/dunkin donuts"), "new target is now linked")
    h.check(!WikilinkParser.extract(from: moved).contains("entertainment/restaurant/dunkin donuts"), "old target no longer linked")

    // Aliases are preserved.
    let aliased = WikilinkParser.rewrite(in: "see [[old/Name|nickname]]") { $0 == "old/Name" ? "new/Name" : $0 }
    h.eq(aliased, "see [[new/Name|nickname]]", "keeps the |alias when retargeting")
    // Unchanged links are left byte-for-byte.
    let same = "[[a/B]] and [[c/D]]"
    h.eq(WikilinkParser.rewrite(in: same) { $0 }, same, "unchanged links untouched")
}

h.group("Wikilink sanitize (link quality control)") {
    // The exact malformed case reported: a nested link collapses to the inner one.
    h.eq(WikilinkParser.sanitize("[[contacts/[[contacts/Ken]]"), "[[contacts/Ken]]", "nested link → innermost wins")
    // A clean body is left byte-for-byte.
    let clean = "dinner with [[people/Sam]] at [[food/Lazy Bear]]"
    h.eq(WikilinkParser.sanitize(clean), clean, "clean links untouched")
    // Stray brackets inside a link are dropped.
    h.eq(WikilinkParser.sanitize("[[peo[ple/Sam]]"), "[[people/Sam]]", "stray bracket inside a link dropped")
    // An unterminated link becomes plain text, not a bogus link.
    h.eq(WikilinkParser.sanitize("meeting [[people/Sam"), "meeting people/Sam", "unterminated link → plain text")
    // Nesting doesn't corrupt following text.
    h.eq(WikilinkParser.sanitize("[[a/[[b/C]] then more"), "[[b/C]] then more", "text after a repaired link survives")
}

exit(Int32(h.summarize()))
