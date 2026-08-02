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
    @State private var showFollowUp = false
    @State private var followUpMessage: String?
    @State private var showRename = false
    @State private var titleDraft = ""

    var body: some View {
        if let note = model.note(id: noteID) {
            List {
                Section {
                    if note.origin?.source == "readwise" { bookHeader(note) }
                    if let folder = model.folder(named: note.folderName) {
                        let axis = model.axis(id: folder.axisID)
                        HStack(spacing: 12) {
                            AxisIconTile(symbol: folderSymbol(folder.name, folder.category),
                                         color: axis?.color ?? .secondary, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(folder.name).font(.system(.subheadline, design: .rounded).weight(.semibold))
                                Text(folder.category).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let axis {
                                Text(axis.name)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(axis.color)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(axis.color.opacity(0.15), in: Capsule())
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    if !note.isStub {
                        LabeledContent("Intensity") {
                            Text("⚡ \(note.intensity)").font(.callout.weight(.medium))
                        }
                    }
                    if let loc = note.location, !loc.isEmpty {
                        LabeledContent("Location", value: loc)
                    }
                    if note.origin?.source == "readwise" {
                        Toggle(isOn: Binding(get: { !note.isStub },
                                             set: { model.setFinished(note.id, $0) })) {
                            Label(note.isStub ? "Mark as finished" : "Finished reading",
                                  systemImage: note.isStub ? "book.closed" : "checkmark.seal.fill")
                        }
                        .tint(.green)
                        if note.isStub {
                            Text("A book grows Mind only once you finish it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else if note.isStub {
                        Label("Dormant — write about them or add a [[link]] to start growing.",
                              systemImage: "moon.zzz")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if note.origin?.source == "healthkit" {
                        Label("Verified activity", systemImage: "checkmark.seal.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                    if note.origin?.source == "followup" {
                        Label("Followed through", systemImage: "checkmark.seal.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                }

                Section {
                    Button { showFollowUp = true } label: {
                        Label("Remind me to follow up…", systemImage: "bell.badge")
                    }
                }

                let suggestions = model.connectionSuggestions(for: note)
                if !suggestions.isEmpty {
                    Section {
                        ForEach(suggestions) { suggestion in
                            let candidate = suggestion.note
                            HStack(spacing: 10) {
                                Circle().fill(model.axis(for: candidate)?.color ?? .gray).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(candidate.displayName)
                                    Text(suggestion.reason)
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
                        Text("People and moments from around this time. Linking one connects it into your web.")
                    }
                }

                Section("Note") {
                    LinkingEditor(text: $editedBody)
                    Text("Type [[ to link — pick an existing note, or create a new one.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                // A book already has its cover; no photo picker needed.
                if note.origin?.source != "readwise" {
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
                    Button {
                        titleDraft = note.title; showRename = true
                    } label: {
                        Label("Move or rename…", systemImage: "folder")
                    }
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
                    Button("Save") { model.updateBody(note.id, body: editedBody); dismiss() }
                        .disabled(editedBody == note.body)
                }
            }
            .sheet(isPresented: $showFollowUp) {
                FollowUpSheet(noteTitle: note.title, defaultTitle: defaultFollowUpTitle(note)) { message in
                    followUpMessage = message
                }
            }
            .alert("Follow-up", isPresented: Binding(get: { followUpMessage != nil },
                                                     set: { if !$0 { followUpMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(followUpMessage ?? "") }
            .alert("Move or rename", isPresented: $showRename) {
                TextField("folder/Name", text: $titleDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Save") { model.renameNote(note.id, to: titleDraft) }
            } message: {
                Text("Change its folder or name — every link to it updates automatically.")
            }
        } else {
            Text("This note no longer exists.").foregroundStyle(.secondary)
        }
    }

    /// A sensible default reminder title — person-aware ("Call Sam").
    private func defaultFollowUpTitle(_ note: Note) -> String {
        Folder.normalize(note.folderName) == "people"
            ? "Call \(note.displayName)"
            : "Follow up: \(note.displayName)"
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

    /// Cover + author + highlight count for an imported book (Readwise metadata).
    @ViewBuilder
    private func bookHeader(_ note: Note) -> some View {
        let author = note.details.first { $0.key == "Author" }?.value
        let cover = note.details.first { $0.key == "Cover" }?.value
        let highlightCount = note.body.split(separator: "\n").filter { $0.hasPrefix("> ") }.count
        HStack(spacing: 14) {
            Group {
                if let cover, let url = URL(string: cover) {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.secondary.opacity(0.12)
                    }
                } else {
                    Color.secondary.opacity(0.12)
                        .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
                }
            }
            .frame(width: 58, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.08)))

            VStack(alignment: .leading, spacing: 4) {
                Text(note.displayName).font(.headline)
                if let author { Text("by \(author)").font(.subheadline).foregroundStyle(.secondary) }
                if highlightCount > 0 {
                    Label("\(highlightCount) highlights", systemImage: "quote.opening")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}
