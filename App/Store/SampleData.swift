import Foundation
import NuminousCore

/// A small seeded world so the app opens with something alive — notes already
/// connected across folders/axes, so growth is visible on first run.
enum SampleData {
    private static func daysAgo(_ n: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -n, to: Date()) ?? Date()
    }

    static let folders: [Folder] = [
        Folder(name: "people", category: "Relationships", axisID: "heart"),
        Folder(name: "books",  category: "Cognition",     axisID: "mind"),
        Folder(name: "sport",  category: "Fitness",       axisID: "body"),
        Folder(name: "notes",       category: "Notes",   axisID: nil),
        Folder(name: "notes/diary", category: "Journal", axisID: "spirit", defaultIntensity: 4),
    ]

    static let notes: [Note] = [
        Note(title: "people/Sam", date: daysAgo(6),
             body: "Old friend from college. We can talk for hours.",
             intensity: 5,
             details: [NoteDetail(key: "Phone", value: "555-0192"),
                       NoteDetail(key: "Favorite team", value: "Warriors")]),

        Note(title: "books/Atomic Habits", date: daysAgo(6),
             body: "Finished it — habit stacking really stuck with me.",
             intensity: 3),

        Note(title: "sport/Back nine with Sam", date: daysAgo(5),
             body: """
             Played 18 holes with [[people/Sam]] today, still buzzing from finishing
             [[books/Atomic Habits]] last week — our back nine turned into talking
             about habit stacking.
             """,
             intensity: 4, location: "Pebble Beach"),

        Note(title: "notes/diary/Evening reflection", date: daysAgo(3),
             body: "Quiet night. I feel better when I actually see [[people/Sam]] in person instead of just texting.",
             intensity: 4),
    ]
}
