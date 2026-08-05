import SwiftUI
import NuminousCore

/// Type a category and it autocompletes to folders you already have — pick an existing
/// one or create the typed name. Replaces the old tap-through menu + blank "new category"
/// prompt so filing a note is a single, forgiving type-ahead.
struct CategoryPickerView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Binding var category: String

    @State private var query: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List {
                if canCreate {
                    Button { choose(cleaned) } label: {
                        Label { Text("Create “\(cleaned)”").foregroundStyle(.primary) }
                        icon: { Image(systemName: "plus.circle.fill").foregroundStyle(.tint) }
                    }
                }
                Section {
                    ForEach(matches, id: \.self) { name in
                        Button { choose(name) } label: {
                            HStack(spacing: 10) {
                                Circle().fill(dot(name)).frame(width: 9, height: 9)
                                Text(displayName(name)).foregroundStyle(.primary)
                                if isNested(name) {
                                    Text(name).font(.caption2).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if name.lowercased() == category.lowercased() {
                                    Image(systemName: "checkmark").foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                    }
                } header: {
                    Text(matches.isEmpty ? "No matching folders" : "Your folders")
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Type a category — e.g. people, health/workouts")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onSubmit(of: .search) { if canCreate { choose(cleaned) } else if let first = matches.first { choose(first) } }
            .navigationTitle("Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    // MARK: - Data

    private var allNames: [String] {
        var seen = Set<String>(); var out: [String] = []
        for n in (["notes", "diary"] + model.folders.map(\.name)) where seen.insert(n.lowercased()).inserted {
            out.append(n)
        }
        return out
    }

    private var matches: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return allNames.sorted() }
        return allNames
            .filter { $0.lowercased().contains(q) }
            .sorted {
                let a = $0.lowercased().hasPrefix(q), b = $1.lowercased().hasPrefix(q)
                return a == b ? $0.localizedCaseInsensitiveCompare($1) == .orderedAscending : a
            }
    }

    private var cleaned: String { query.trimmingCharacters(in: CharacterSet(charactersIn: " /")) }
    private var canCreate: Bool {
        !cleaned.isEmpty && !allNames.contains { $0.lowercased() == cleaned.lowercased() }
    }

    private func choose(_ name: String) { category = name; dismiss() }

    private func dot(_ name: String) -> Color {
        model.axis(id: model.folder(named: name)?.axisID ?? "")?.color ?? .secondary
    }
    private func isNested(_ name: String) -> Bool { name.contains("/") }
    private func displayName(_ name: String) -> String {
        guard let slash = name.lastIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }
}
