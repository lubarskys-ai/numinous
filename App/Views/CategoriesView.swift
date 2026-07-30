import SwiftUI
import NuminousCore

/// Manage which axis each category grows. Changing a category's axis instantly
/// reflows all past notes' contributions (the engine recomputes from scratch) —
/// nothing in your journal history changes.
struct CategoriesView: View {
    @EnvironmentObject var store: NoteStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.axes) { axis in
                    let categories = store.categories.filter { $0.axisID == axis.id }
                    Section {
                        if categories.isEmpty {
                            Text("No categories yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(categories) { CategoryAxisRow(category: $0) }
                        }
                    } header: {
                        HStack(spacing: 8) {
                            Circle().fill(axis.color).frame(width: 8, height: 8)
                            Text(axis.name)
                        }
                    }
                }

                let unmapped = store.categories.filter { $0.axisID == nil }
                if !unmapped.isEmpty {
                    Section("Not yet mapped") {
                        ForEach(unmapped) { CategoryAxisRow(category: $0) }
                    }
                }
            }
            .navigationTitle("Categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct CategoryAxisRow: View {
    @EnvironmentObject var store: NoteStore
    let category: Category

    var body: some View {
        HStack {
            Text(category.name)
            Spacer()
            Menu {
                ForEach(store.axes) { axis in
                    Button {
                        store.setAxis(axis.id, forCategory: category.id)
                    } label: {
                        if category.axisID == axis.id {
                            Label(axis.name, systemImage: "checkmark")
                        } else {
                            Text(axis.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(store.axis(category.axisID)?.color ?? Color.gray.opacity(0.4))
                        .frame(width: 8, height: 8)
                    Text(store.axis(category.axisID)?.name ?? "Choose")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
