import SwiftUI
import NuminousCore

struct NoteDetailView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let noteID: UUID

    @State private var newKey = ""
    @State private var newValue = ""
    @State private var editedBody = ""
    @State private var loadedBodyFor: UUID?

    var body: some View {
        if let note = model.note(id: noteID) {
            List {
                Section {
                    if let folder = model.folder(named: note.folderName) {
                        HStack {
                            Circle().fill(model.axis(id: folder.axisID)?.color ?? .gray).frame(width: 9, height: 9)
                            Text("\(folder.name) · \(folder.category)")
                            Spacer()
                            Text(model.axis(id: folder.axisID)?.name ?? "—").foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                    if !note.isStub {
                        LabeledContent("Intensity", value: "⚡ \(note.intensity)")
                    }
                    if let loc = note.location, !loc.isEmpty {
                        LabeledContent("Location", value: loc)
                    }
                    if note.isStub {
                        Label("Dormant — write about them or add a [[link]] to start growing.",
                              systemImage: "moon.zzz")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Note") {
                    TextEditor(text: $editedBody).frame(minHeight: 120)
                    Text("Write freely. Link anything with [[double brackets]] — e.g. [[books/Dune]].")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Details") {
                    ForEach(note.details.indices, id: \.self) { index in
                        let detail = note.details[index]
                        HStack {
                            Text(detail.key).foregroundStyle(.secondary)
                            Spacer()
                            Text(detail.value)
                        }
                    }
                    .onDelete { offsets in offsets.forEach { model.removeDetail(from: note.id, at: $0) } }

                    HStack {
                        TextField("Field", text: $newKey)
                        TextField("Value", text: $newValue)
                        Button("Add") {
                            model.addDetail(to: note.id,
                                            key: newKey.trimmingCharacters(in: .whitespaces),
                                            value: newValue.trimmingCharacters(in: .whitespaces))
                            newKey = ""; newValue = ""
                        }
                        .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty
                                  || newValue.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section("Links to") {
                    let targets = note.linkTargets
                    if targets.isEmpty {
                        Text("No links yet.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(targets, id: \.self) { target in
                            if let other = model.note(titled: target) {
                                NavigationLink(value: other.id) { linkLabel(other) }
                            } else {
                                Label(target + " · new", systemImage: "plus.circle").foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Linked from") {
                    let back = model.backlinks(to: note)
                    if back.isEmpty {
                        Text("Nothing links here yet.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(back) { b in NavigationLink(value: b.id) { linkLabel(b) } }
                    }
                }

                Section {
                    Button("Delete note", role: .destructive) {
                        model.delete([note]); dismiss()
                    }
                }
            }
            .navigationTitle(note.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if loadedBodyFor != note.id { editedBody = note.body; loadedBodyFor = note.id }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { model.updateBody(note.id, body: editedBody) }
                        .disabled(editedBody == note.body)
                }
            }
        } else {
            Text("This note no longer exists.").foregroundStyle(.secondary)
        }
    }

    private func linkLabel(_ note: Note) -> some View {
        HStack(spacing: 10) {
            Circle().fill(model.axis(for: note)?.color ?? Color.gray.opacity(0.4)).frame(width: 8, height: 8)
            Text(note.title)
        }
    }
}
