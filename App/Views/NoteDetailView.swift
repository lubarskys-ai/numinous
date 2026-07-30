import SwiftUI
import PhotosUI
import NuminousCore

struct NoteDetailView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let noteID: UUID

    @State private var editedBody = ""
    @State private var loadedBodyFor: UUID?
    @State private var photoItem: PhotosPickerItem?

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
                    if note.origin?.source == "healthkit" {
                        Label("Verified activity", systemImage: "checkmark.seal.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                }

                let suggestions = model.suggestedConnections(for: note)
                if !suggestions.isEmpty {
                    Section {
                        ForEach(suggestions) { candidate in
                            HStack(spacing: 10) {
                                Circle().fill(model.axis(for: candidate)?.color ?? .gray).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(candidate.displayName)
                                    Text(candidate.folderName.isEmpty ? "around the same time" : "\(candidate.folderName) · around the same time")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Link") { link(to: candidate.title) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    } header: {
                        Text("Suggested connections")
                    } footer: {
                        Text("Things that happened around the same time. Linking one connects it into your web.")
                    }
                }

                Section("Note") {
                    LinkingEditor(text: $editedBody)
                    Text("Type [[ to link — pick an existing note, or create a new one.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Photos") {
                    let photos = note.photos ?? []
                    if !photos.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(photos, id: \.self) { name in
                                    if let image = ImageStore.load(name) {
                                        Image(uiImage: image)
                                            .resizable().scaledToFill()
                                            .frame(width: 84, height: 84)
                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                            .overlay(alignment: .topTrailing) {
                                                Button {
                                                    model.removePhoto(from: note.id, name: name)
                                                } label: {
                                                    Image(systemName: "xmark.circle.fill")
                                                        .foregroundStyle(.white, .black.opacity(0.5))
                                                }
                                                .padding(3)
                                            }
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Add photo", systemImage: "photo.badge.plus")
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
            .onChange(of: photoItem) { newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self) {
                        model.addPhoto(to: note.id, data: data)
                    }
                    photoItem = nil
                }
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

    private func link(to title: String) {
        let sep = editedBody.isEmpty || editedBody.hasSuffix("\n") || editedBody.hasSuffix(" ") ? "" : " "
        editedBody += sep + "[[\(title)]]"
        model.updateBody(noteID, body: editedBody)
    }

    private func linkLabel(_ note: Note) -> some View {
        HStack(spacing: 10) {
            Circle().fill(model.axis(for: note)?.color ?? Color.gray.opacity(0.4)).frame(width: 8, height: 8)
            Text(note.title)
        }
    }
}
