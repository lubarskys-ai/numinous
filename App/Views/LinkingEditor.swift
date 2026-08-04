import SwiftUI
import UIKit
import NuminousCore

/// Bridges a UITextView's active `[[` token to SwiftUI: publishes the current
/// query and lets the suggestion UI insert a chosen link at that token.
@MainActor
final class LinkEditorController: ObservableObject {
    /// The text after an open, unclosed `[[` before the caret (nil when not linking).
    @Published var query: String?
    fileprivate var insertClosure: ((String) -> Void)?

    func insert(_ fullTitle: String) { insertClosure?(fullTitle) }
}

/// A note body editor with inline `[[wikilink]]` autocomplete. Suggests existing
/// *files* by name (the folder is filled in for you); a folder is only chosen
/// when you're creating a genuinely new link.
struct LinkingEditor: View {
    @EnvironmentObject var model: AppModel
    @Binding var text: String
    var minHeight: CGFloat = 130
    /// Called with the full text right after a link is inserted from the autocomplete,
    /// so a note can persist links automatically without a manual Save.
    var onCommit: ((String) -> Void)? = nil

    @StateObject private var controller = LinkEditorController()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LinkTextView(text: $text, controller: controller, onCommit: onCommit)
                .frame(minHeight: minHeight, maxHeight: .infinity)

            if let query = controller.query {
                suggestions(for: query)
            }
        }
    }

    @ViewBuilder
    private func suggestions(for query: String) -> some View {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = matchingNotes(q)

        VStack(alignment: .leading, spacing: 0) {
            ForEach(matches, id: \.id) { note in
                Button { controller.insert(note.title) } label: {
                    HStack(spacing: 9) {
                        Circle().fill(model.axis(for: note)?.color ?? Color.gray.opacity(0.5))
                            .frame(width: 8, height: 8)
                        Text(note.title).foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 9).padding(.horizontal, 10)
                }
                .buttonStyle(.plain)
                if note.id != matches.last?.id { Divider() }
            }

            if !q.isEmpty { createNew(query.trimmingCharacters(in: .whitespacesAndNewlines), hasMatches: !matches.isEmpty) }
        }
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15)))
    }

    private func matchingNotes(_ q: String) -> [Note] {
        var seen = Set<String>()
        var out: [Note] = []
        for note in model.notes where !note.title.isEmpty {
            let key = note.title.lowercased()
            let hit = q.isEmpty || key.contains(q) || note.displayName.lowercased().contains(q)
            if hit, seen.insert(key).inserted {
                out.append(note)
                if out.count == 6 { break }
            }
        }
        return out
    }

    @ViewBuilder
    private func createNew(_ raw: String, hasMatches: Bool) -> some View {
        if hasMatches { Divider() }
        if raw.contains("/") {
            Button { controller.insert(raw) } label: {
                Label("Create note \(raw)", systemImage: "folder.badge.plus").padding(10)
            }
            .buttonStyle(.plain)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                Text("Create “\(raw)” in…").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.folders) { folder in
                            Button { controller.insert("\(folder.name)/\(raw)") } label: {
                                Text(folder.name).font(.caption.weight(.medium))
                                    .padding(.horizontal, 11).padding(.vertical, 6)
                                    .background((model.axis(id: folder.axisID)?.color ?? .gray).opacity(0.16), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(10)
        }
    }
}

/// UITextView wrapped for SwiftUI, reporting its active `[[` token to a controller.
private struct LinkTextView: UIViewRepresentable {
    @Binding var text: String
    @ObservedObject var controller: LinkEditorController
    var onCommit: ((String) -> Void)? = nil

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = UIFont.preferredFont(forTextStyle: .body)
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 2, bottom: 8, right: 2)
        tv.text = text
        context.coordinator.textView = tv
        controller.insertClosure = { [weak c = context.coordinator] value in c?.insertLink(value) }
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // Keep the coordinator's write-back binding fresh. SwiftUI recreates this
        // struct on every parent re-render; without this, the coordinator keeps
        // writing keystrokes through the ORIGINAL (now stale) `text` binding, so the
        // text view and the @State drift apart and the caret jumps around wildly.
        context.coordinator.parent = self
        // NEVER reassign the text view while the user is typing in it. A re-render
        // mid-keystroke (e.g. the [[ autocomplete appearing) would otherwise push a
        // stale, one-bracket-behind value and snap the caret back. The binding catches
        // up via the delegate; programmatic inserts resign first responder first.
        guard !uiView.isFirstResponder else { return }
        // Otherwise sync external changes, preserving the caret across the swap.
        guard uiView.markedTextRange == nil, uiView.text != text else { return }
        let caretOffset = uiView.selectedTextRange.map {
            uiView.offset(from: uiView.beginningOfDocument, to: $0.start)
        }
        uiView.text = text
        if let caretOffset {
            let clamped = min(caretOffset, (text as NSString).length)
            if let pos = uiView.position(from: uiView.beginningOfDocument, offset: clamped) {
                uiView.selectedTextRange = uiView.textRange(from: pos, to: pos)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LinkTextView
        weak var textView: UITextView?
        init(_ parent: LinkTextView) { self.parent = parent }

        func textViewDidChange(_ tv: UITextView) { parent.text = tv.text; updateQuery() }
        func textViewDidChangeSelection(_ tv: UITextView) { updateQuery() }

        private func caretOffset(_ tv: UITextView) -> Int? {
            guard let range = tv.selectedTextRange else { return nil }
            return tv.offset(from: tv.beginningOfDocument, to: range.start)
        }

        func updateQuery() {
            guard let tv = textView, let caret = caretOffset(tv) else { return setQuery(nil) }
            let ns = tv.text as NSString
            let clamped = min(caret, ns.length)
            let before = ns.substring(to: clamped) as NSString
            let open = before.range(of: "[[", options: .backwards)
            guard open.location != NSNotFound else { return setQuery(nil) }
            let query = before.substring(from: open.location + 2)
            if query.contains("]]") || query.contains("\n") || query.contains("[") { return setQuery(nil) }
            setQuery(query)
        }

        private func setQuery(_ q: String?) {
            if parent.controller.query != q { parent.controller.query = q }
        }

        func insertLink(_ fullTitle: String) {
            guard let tv = textView, let caret = caretOffset(tv) else { return }
            let ns = tv.text as NSString
            let clamped = min(caret, ns.length)
            let before = ns.substring(to: clamped) as NSString
            let open = before.range(of: "[[", options: .backwards)
            guard open.location != NSNotFound else { return }
            let replace = NSRange(location: open.location, length: clamped - open.location)
            let insertText = "[[\(fullTitle)]] "
            let newText = ns.replacingCharacters(in: replace, with: insertText)
            tv.text = newText
            parent.text = newText
            let newCaret = open.location + (insertText as NSString).length
            if let pos = tv.position(from: tv.beginningOfDocument, offset: newCaret) {
                tv.selectedTextRange = tv.textRange(from: pos, to: pos)
            }
            setQuery(nil)
            parent.onCommit?(newText)      // persist the just-added link immediately
        }
    }
}
