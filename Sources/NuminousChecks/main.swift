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

    h.eq(same.rawTotals.total - 20, 5, "same-axis link: one axis × 5")
    h.eq(cross.rawTotals.total - 20, 30, "cross-axis link: two axes × 15")
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

exit(Int32(h.summarize()))
