import SwiftUI
import NuminousCore

struct NoteListView: View {
    @EnvironmentObject var store: NoteStore
    @State private var editingNote: Note?
    @State private var composingNew = false
    @State private var showingCategories = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    GrowthHeaderView()
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                Section("Notes") {
                    ForEach(store.sortedNotes) { note in
                        Button {
                            editingNote = note
                        } label: {
                            NoteRowView(note: note)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        store.delete(offsets.map { store.sortedNotes[$0] })
                    }
                }
            }
            .navigationTitle("Numinous")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingCategories = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Categories")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        composingNew = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New note")
                }
            }
            .sheet(item: $editingNote) { note in
                NoteEditorView(note: note)
            }
            .sheet(isPresented: $composingNew) {
                NoteEditorView(note: nil)
            }
            .sheet(isPresented: $showingCategories) {
                CategoriesView()
            }
        }
    }
}
