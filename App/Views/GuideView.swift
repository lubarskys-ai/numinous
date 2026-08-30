import SwiftUI
import NuminousCore

/// The short answer to "what is this and what am I meant to do". Reached from Home.
///
/// Kept to one screenful of scrolling and written in sentences, not features — someone
/// opening this is confused, and a list of every capability is what confused them. It
/// mirrors the three movements the app is actually built around, so the story here is the
/// same one the app tells.
struct GuideView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private struct Step: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let body: String
    }

    private let moves: [Step] = [
        Step(icon: "square.and.pencil", title: "Capture",
             body: "Note something — a person, a place, a book, an evening. Tap the mic on the keyboard and just say it if that's easier. It's understood on your phone and filed for you."),
        Step(icon: "point.3.connected.trianglepath.dotted", title: "Connect",
             body: "Type [[ to link a note to anything else, or tap the link button and it writes the brackets for you. Numinous also spots connections you didn't make — that's when it's working."),
        Step(icon: "figure.stand", title: "Become",
             body: "Every note feeds one part of you: Body, Mind, Heart, Meaning, Spirit, Gut, Influences. Your figure on Home grows from what you actually did. There's no way to fake it fuller.")
    ]

    private let places: [Step] = [
        Step(icon: "note.text", title: "Notes",
             body: "Everything you've written, newest first. Search finds text and links."),
        Step(icon: "folder", title: "Folders",
             body: "The same notes by kind — people, books, travel, whatever you make. A folder decides which part of you a note grows."),
        Step(icon: "map", title: "Map",
             body: "Everywhere you've been that has a location, and how much ground you've covered.")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    opener
                    section("The three moves", moves)
                    section("Where things live", places)
                    plainSection("Places count for more than you'd think", """
                        A place grows you more the farther it is from home, more if you slept \
                        there, and more if you'd never been. Set where you live under Folders → \
                        the gear icon → Home, and the map starts weighing everywhere else \
                        against it.
                        """)
                    plainSection("Your week", """
                        Once a week Numinous shows what you tended and what went quiet, and \
                        who you've drifted from. It's a look back, not a scoreboard — there \
                        are no streaks to keep.
                        """)
                    plainSection("It stays on your phone", """
                        Your notes, your health data, your locations: all of it is read and \
                        kept on this device. Nothing is uploaded and nothing is sold.
                        """)
                    closer
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 50)
            }
            .navigationTitle("How Numinous works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var opener: some View {
        Text("Numinous holds the people, places, and things you care about, and quietly ties them together. It's built to be used for a minute and closed — the life it's about is the one happening off the screen.")
            .font(.title3)
            .fontDesign(.serif)
            .padding(.top, 10)
    }

    private var closer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Start with one note about someone who matters. The rest follows from there.")
                .font(.callout)
                .fontDesign(.serif)
                .foregroundStyle(.secondary)
        }
    }

    private func section(_ title: String, _ steps: [Step]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            heading(title)
            ForEach(steps) { step in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: step.icon)
                        .font(.body)
                        .foregroundStyle(.tint)
                        .frame(width: 26)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(step.title).font(.headline)
                        Text(step.body).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func plainSection(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            heading(title)
            Text(body).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .kerning(0.8)
            .foregroundStyle(.secondary)
    }
}
