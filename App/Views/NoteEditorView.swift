import SwiftUI
import NuminousCore

struct NoteEditorView: View {
    @EnvironmentObject var store: NoteStore
    @Environment(\.dismiss) private var dismiss

    private let original: Note?

    @State private var title: String
    @State private var categoryID: String?
    @State private var text: String
    @State private var interaction: InteractionMode?
    @State private var depthValue: Int
    @State private var showingNewCategory = false

    init(note: Note?) {
        original = note
        _title = State(initialValue: note?.title ?? "")
        _categoryID = State(initialValue: note?.categoryID)
        _text = State(initialValue: note?.body ?? "")
        _interaction = State(initialValue: note?.interaction)
        _depthValue = State(initialValue: note?.depth ?? 0)
    }

    private var detectedLinks: [String] { WikilinkParser.extract(from: text) }
    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("A person, book, place, or moment", text: $title)
                }

                Section("Category") {
                    categoryMenu
                }

                Section("Note") {
                    TextEditor(text: $text)
                        .frame(minHeight: 140)
                        .font(.body)
                    Text("Tip: link with [[double brackets]] — e.g. mention [[Sam]] or [[Atomic Habits]].")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                linksSection

                Section("Details (optional)") {
                    Picker("Interaction", selection: $interaction) {
                        Text("—").tag(Optional<InteractionMode>.none)
                        Text("In person").tag(Optional(InteractionMode.inPerson))
                        Text("Call").tag(Optional(InteractionMode.call))
                        Text("Text").tag(Optional(InteractionMode.text))
                        Text("Social").tag(Optional(InteractionMode.social))
                    }
                    Picker("Depth", selection: $depthValue) {
                        Text("—").tag(0)
                        ForEach(1..<6, id: \.self) { Text("\($0)").tag($0) }
                    }
                }
            }
            .navigationTitle(original == nil ? "New Note" : "Edit Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(trimmedTitle.isEmpty)
                }
            }
            .sheet(isPresented: $showingNewCategory) {
                NewCategoryView { newID in categoryID = newID }
            }
        }
    }

    private var categoryMenu: some View {
        Menu {
            ForEach(store.categories) { category in
                Button {
                    categoryID = category.id
                } label: {
                    if categoryID == category.id {
                        Label(category.name, systemImage: "checkmark")
                    } else {
                        Text(category.name)
                    }
                }
            }
            if categoryID != nil {
                Button(role: .destructive) { categoryID = nil } label: {
                    Label("Clear", systemImage: "xmark")
                }
            }
            Divider()
            Button {
                showingNewCategory = true
            } label: {
                Label("New Category…", systemImage: "plus")
            }
        } label: {
            HStack {
                Text("Category")
                    .foregroundStyle(.primary)
                Spacer()
                if let category = store.category(categoryID) {
                    TagView(text: category.name,
                            color: store.axis(forCategory: categoryID)?.color ?? .gray)
                } else {
                    Text("Choose").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var linksSection: some View {
        if !detectedLinks.isEmpty {
            Section("Connections in this note") {
                ForEach(detectedLinks, id: \.self) { link in
                    HStack {
                        Image(systemName: store.noteExists(titled: link) ? "link" : "plus.circle")
                            .foregroundStyle(store.noteExists(titled: link) ? Color.accentColor : .secondary)
                        Text(link)
                        Spacer()
                        if store.noteExists(titled: link) {
                            if let axis = store.axis(forCategory: existingCategoryID(for: link)) {
                                Circle().fill(axis.color).frame(width: 8, height: 8)
                            }
                        } else {
                            Text("will be created")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func existingCategoryID(for title: String) -> String? {
        let key = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return store.notes.first {
            $0.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == key
        }?.categoryID
    }

    private func save() {
        guard !trimmedTitle.isEmpty else { return }
        let note = Note(
            id: original?.id ?? UUID(),
            title: trimmedTitle,
            categoryID: categoryID,
            date: original?.date ?? Date(),
            body: text,
            interaction: interaction,
            depth: depthValue == 0 ? nil : depthValue,
            source: original?.source ?? .manual,
            sessionID: original?.sessionID,
            isStub: false
        )
        store.save(note)
        dismiss()
    }
}
