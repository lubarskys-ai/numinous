import Foundation
import NuminousCore

/// A small seeded world so the app opens with something alive — a few notes that
/// already connect across axes, so the growth mechanic is visible on first run.
enum SampleData {
    private static func daysAgo(_ n: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -n, to: Date()) ?? Date()
    }

    static let categories: [Category] = [
        Category(id: "golf",    name: "Golf",          axisID: "body"),
        Category(id: "novels",  name: "Novels",        axisID: "mind"),
        Category(id: "friends", name: "Close friends", axisID: "heart"),
        Category(id: "diary",   name: "Diary",         axisID: "spirit"),
    ]

    static let notes: [Note] = [
        Note(title: "Sam", categoryID: "friends", date: daysAgo(6),
             body: "Old friend from college. We can talk for hours.",
             interaction: .inPerson),

        Note(title: "Atomic Habits", categoryID: "novels", date: daysAgo(6),
             body: "Finished it — the idea of habit stacking really stuck with me."),

        Note(title: "Back nine with Sam", categoryID: "golf", date: daysAgo(5),
             body: """
             Played 18 holes with [[Sam]] today, still buzzing from finishing
             [[Atomic Habits]] last week — our whole back nine turned into
             talking about habit stacking.
             """,
             interaction: .inPerson, depth: 4),

        Note(title: "Evening reflection", categoryID: "diary", date: daysAgo(3),
             body: """
             Quiet night. Thinking about how much better I feel when I actually
             see [[Sam]] in person instead of just texting.
             """,
             depth: 5),
    ]
}
