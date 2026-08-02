import SwiftUI
import NuminousCore

/// Quick capture: dictate (via the keyboard mic) or type a note, then let Numinous
/// find the people and things you mentioned and wire in the links.
struct CaptureView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var onSaved: (UUID) -> Void

    @State private var text = ""
    @State private var suggestions: [LinkSuggestion] = []
    @State private var didScan = false
    @State private var scanning = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 150)
                        .focused($focused)
                        .onChange(of: text) { _ in didScan = false }
                } header: {
                    Text("Speak or type")
                } footer: {
                    Text("Tap the 🎤 on your keyboard to dictate, then find the links.")
                }

                Section {
                    Button {
                        scanning = true
                        Task {
                            let found = await model.smartLinkSuggestions(in: text)
                            suggestions = found
                            didScan = true
                            scanning = false
                        }
                    } label: {
                        if scanning {
                            HStack { ProgressView(); Text("Finding links…") }
                        } else {
                            Label("Find links", systemImage: "link.badge.plus")
                        }
                    }
                    .disabled(scanning || text.trimmingCharacters(in: .whitespaces).count < 3)

                    if !suggestions.isEmpty {
                        ForEach(suggestions) { s in
                            Button { insert(s) } label: {
                                HStack(spacing: 8) {
                                    Circle().fill(color(for: s)).frame(width: 8, height: 8)
                                    Text(s.name).foregroundStyle(.primary)
                                    Text(s.folderLabel).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    if s.isNew {
                                        Text("New").font(.caption2.weight(.semibold))
                                            .foregroundStyle(.green)
                                        Image(systemName: "plus.circle.dashed").foregroundStyle(.green)
                                    } else {
                                        Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                                    }
                                }
                            }
                        }
                        Button { insertAll() } label: { Label("Add all links", systemImage: "checkmark.circle") }
                            .font(.callout.weight(.medium))
                    } else if didScan {
                        Text("Nothing to link yet — try a note that names a person, place, or thing.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Links the people, places, and things you mention — tap to add. “New” creates the note for you.")
                }
            }
            .navigationTitle("Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let id = model.createCapturedNote(body: text)
                        onSaved(id); dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
    }

    private func insert(_ s: LinkSuggestion) {
        applyLink(s)
        suggestions.removeAll { $0.target == s.target }
    }

    private func insertAll() {
        for s in suggestions { applyLink(s) }
        suggestions = []
    }

    /// Wire `[[target]]` into the note: replace the exact words in place when we can
    /// find them, otherwise append the link so it's never lost (spelling-corrected
    /// names may not match the dictated text verbatim).
    private func applyLink(_ s: LinkSuggestion) {
        let wikilink = "[[\(s.target)]]"
        if !s.surface.isEmpty, let r = AutoLinker.firstWordRange(of: s.surface, in: text) {
            text.replaceSubrange(r, with: wikilink)
        } else if let r = AutoLinker.firstWordRange(of: s.name, in: text) {
            text.replaceSubrange(r, with: wikilink)
        } else {
            text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + wikilink
        }
    }

    private func color(for s: LinkSuggestion) -> Color {
        model.note(titled: s.target).flatMap { model.axis(for: $0)?.color }
            ?? model.folder(named: s.folderLabel)?.axisID.flatMap { model.axis(id: $0)?.color }
            ?? .secondary
    }
}
