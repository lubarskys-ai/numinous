import SwiftUI
import NuminousCore

/// Quick capture: dictate (via the keyboard mic) or type a note, then let Numinous
/// find the people and things you mentioned and wire in the links.
struct CaptureView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var onSaved: (UUID) -> Void

    @State private var text = ""
    @State private var linkedNames: [String] = []
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
                        .onChange(of: text) { _ in didScan = false; linkedNames = [] }
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
                            for s in found { applyLink(s) }   // write the links right into the note
                            linkedNames = found.map(\.name)
                            didScan = true
                            scanning = false
                        }
                    } label: {
                        if scanning {
                            HStack { ProgressView(); Text("Finding links…") }
                        } else {
                            Label("Find & add links", systemImage: "link.badge.plus")
                        }
                    }
                    .disabled(scanning || text.trimmingCharacters(in: .whitespaces).count < 3)

                    if didScan {
                        if linkedNames.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Nothing to link yet — try naming a person, place, or thing.")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let hint = model.onDeviceAIHint {
                                    Label(hint, systemImage: "sparkles")
                                        .font(.caption2).foregroundStyle(.orange)
                                }
                            }
                        } else {
                            Label("Linked \(linkedNames.joined(separator: " · "))", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                        }
                    }
                } footer: {
                    Text("Finds the people, places, and things you mention and links them right in your note.")
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
}
