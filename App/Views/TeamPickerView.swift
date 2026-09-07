import SwiftUI
import NuminousCore

/// Choose who somebody supports, from the actual list.
///
/// This replaced a text box, and the reason is not tidiness. A typed team either resolves or
/// silently does not, and a person who wrote "Man U" or misspelt Cincinnati got no nudge, ever,
/// with nothing on screen to say why. Every name here comes from the same list the fixture
/// lookup searches, so a chosen team can never fail to be found.
///
/// SEARCHABLE, BECAUSE THE LISTS ARE LONG — seven hundred and fifty colleges, and every one of
/// them is somebody's. Excluding the small schools would make the list shorter and the app
/// worse; typing three letters makes the length free.
///
/// MULTIPLE, BECAUSE PEOPLE SUPPORT SEVERAL: a football team, a baseball team, the school they
/// went to. Tap to add, tap again to remove.
struct TeamPickerView: View {
    let college: Bool
    let chosen: [String]
    let onDone: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var options: [SportsService.TeamOption] = []
    @State private var picked: Set<String> = []
    @State private var query = ""
    @State private var loading = true
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if loading { loadingState }
                else if failed && options.isEmpty { failedState }
                else { list }
            }
            .navigationTitle(college ? "Colleges" : "Pro teams")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: college ? "Search colleges" : "Search teams")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onDone(Array(picked).sorted()); dismiss() }
                        .font(.body.weight(.semibold))
                }
            }
        }
        .task {
            picked = Set(chosen)
            options = await SportsService.options(college: college)
            failed = options.isEmpty
            loading = false
        }
    }

    private var matches: [SportsService.TeamOption] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return options }
        return options.filter { $0.name.lowercased().contains(q) }
    }

    /// Chosen teams that the current search has hidden.
    ///
    /// Only the hidden ones. A "Supporting" section listing everything picked put Chicago Bears
    /// on screen twice — once at the top and once under NFL, both ticked — which reads as a bug
    /// rather than a summary. Its job is to stop a second search looking like it unpicked the
    /// first team, so it only needs the ones you can no longer see.
    private var offscreenPicks: [String] {
        let visible = Set(matches.map(\.name))
        return picked.subtracting(visible).sorted()
    }

    /// Leagues in the order they were listed, not alphabetically: "MLS, MLB, NBA, NFL, NHL" put
    /// soccer at the top of an American team picker, which is nobody's expectation.
    private static let leagueOrder = ["NFL", "NBA", "MLB", "NHL", "MLS", "Colleges"]

    private var grouped: [(league: String, teams: [SportsService.TeamOption])] {
        Dictionary(grouping: matches, by: \.league)
            .map { (league: $0.key, teams: $0.value) }
            .sorted {
                let a = Self.leagueOrder.firstIndex(of: $0.league) ?? .max
                let b = Self.leagueOrder.firstIndex(of: $1.league) ?? .max
                return a == b ? $0.league < $1.league : a < b
            }
    }

    private var list: some View {
        List {
            if !offscreenPicks.isEmpty {
                Section("Also supporting") {
                    ForEach(offscreenPicks, id: \.self) { name in
                        Button { picked.remove(name) } label: {
                            HStack {
                                Text(name).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            ForEach(grouped, id: \.league) { group in
                Section(group.league) {
                    ForEach(group.teams) { option in
                        Button {
                            if picked.contains(option.name) { picked.remove(option.name) }
                            else { picked.insert(option.name) }
                        } label: {
                            HStack {
                                Text(option.name).foregroundStyle(.primary)
                                Spacer()
                                if picked.contains(option.name) {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Fetching the teams…").font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The list is fetched once and then kept for a week, so this is a first-run-offline
    /// problem rather than a recurring one — which is worth saying, so it doesn't read as
    /// "this feature is broken".
    private var failedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
            Text("Couldn't fetch the team list").font(.headline)
            Text("It needs the network once, then keeps it for a week.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Try again") {
                loading = true; failed = false
                Task {
                    options = await SportsService.options(college: college)
                    failed = options.isEmpty
                    loading = false
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
