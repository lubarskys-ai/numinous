import SwiftUI
import NuminousCore

/// Quick capture: dictate (via the keyboard mic) or type a note, then let Numinous
/// find the people and things you mentioned and wire in the links.
struct CaptureView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var onSaved: (UUID) -> Void

    @State private var text = ""
    @State private var suggestions: [AutoLinker.Suggestion] = []
    @State private var didScan = false
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
                        suggestions = model.autolinkSuggestions(in: text)
                        didScan = true
                    } label: {
                        Label("Find links", systemImage: "link.badge.plus")
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).count < 3)

                    if !suggestions.isEmpty {
                        ForEach(suggestions, id: \.target) { s in
                            Button { insert(s) } label: {
                                HStack {
                                    Circle().fill(color(for: s.target)).frame(width: 8, height: 8)
                                    Text(s.name).foregroundStyle(.primary)
                                    Text(folder(of: s.target)).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                                }
                            }
                        }
                        Button { insertAll() } label: { Label("Add all links", systemImage: "checkmark.circle") }
                            .font(.callout.weight(.medium))
                    } else if didScan {
                        Text("No matches to your existing notes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Links to the people, books, and moments you already track — tap to add, or add all.")
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

    private func insert(_ s: AutoLinker.Suggestion) {
        if let r = AutoLinker.firstWordRange(of: s.name, in: text) {
            text.replaceSubrange(r, with: "[[\(s.target)]]")
        }
        suggestions.removeAll { $0.target == s.target }
    }

    private func insertAll() {
        for s in suggestions {
            if let r = AutoLinker.firstWordRange(of: s.name, in: text) {
                text.replaceSubrange(r, with: "[[\(s.target)]]")
            }
        }
        suggestions = []
    }

    private func folder(of target: String) -> String {
        target.contains("/") ? String(target.split(separator: "/").dropLast().joined(separator: "/")) : ""
    }
    private func color(for target: String) -> Color {
        model.note(titled: target).flatMap { model.axis(for: $0)?.color } ?? .secondary
    }
}
