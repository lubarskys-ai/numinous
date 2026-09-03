import SwiftUI
import NuminousCore

/// The places Find locations turned up, with checkmarks — because a trip note usually
/// resolves several at once and adding them one at a time re-ran the whole search between
/// each. Everything is pre-selected: the common case is "yes, all of these".
struct FoundPlacesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let places: [AppModel.NearbyPlace]
    let areaLabel: String?
    let onAdd: ([AppModel.NearbyPlace]) -> Void
    let onChangeArea: () -> Void

    @State private var chosen: Set<UUID> = []

    var body: some View {
        NavigationStack {
            List {
                if places.isEmpty {
                    Text(title).foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(places) { p in
                            Button { toggle(p) } label: {
                                HStack(alignment: .top, spacing: 11) {
                                    Image(systemName: chosen.contains(p.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(chosen.contains(p.id) ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(p.name).foregroundStyle(.primary)
                                        Text(p.subtitle).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: { Text("Tap to include or leave out") }
                }
                Section {
                    Button {
                        onChangeArea()
                    } label: {
                        Label(areaLabel.map { "Searching near \($0) — change" } ?? "Set the area to search…",
                              systemImage: "scope")
                    }
                } footer: {
                    Text("The area sticks to this note's folder, so a trip only needs telling once.")
                }
            }
            .navigationTitle(places.isEmpty ? "No places" : "\(places.count) found")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(chosen.count == places.count ? "Add all" : "Add \(chosen.count)") {
                        onAdd(places.filter { chosen.contains($0.id) })
                    }
                    .disabled(chosen.isEmpty)
                }
            }
            .onAppear { chosen = Set(places.map(\.id)) }
        }
    }

    private func toggle(_ p: AppModel.NearbyPlace) {
        if chosen.contains(p.id) { chosen.remove(p.id) } else { chosen.insert(p.id) }
    }
}
