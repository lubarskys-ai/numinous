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
    /// Focus the editor as soon as it appears (bring the keyboard up).
    var autofocus: Bool = false
    /// Called with the full text right after a link is inserted from the autocomplete,
    /// so a note can persist links automatically without a manual Save.
    var onCommit: ((String) -> Void)? = nil

    @StateObject private var controller = LinkEditorController()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LinkTextView(text: $text, controller: controller, autofocus: autofocus, onCommit: onCommit,
                         colorForTarget: { target in
                             let folder = target.lastIndex(of: "/").map { String(target[..<$0]) } ?? target
                             return UIColor(model.axis(id: model.folder(named: folder)?.axisID ?? "")?.color ?? .accentColor)
                         })
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
        // Nothing typed yet — which is the instant the link button fires, since it lands the
        // caret inside empty brackets. Offer the notes you touched MOST RECENTLY rather than
        // whichever six happen to sit first in storage: those are arbitrary, and reading six
        // unrelated names is worse than reading none. Selected in one pass, not by sorting
        // several thousand notes on every keystroke.
        if q.isEmpty {
            var top: [Note] = []
            for note in model.notes where !note.title.isEmpty {
                if top.count < 6 {
                    top.append(note)
                    top.sort { $0.date > $1.date }
                } else if let oldest = top.last, note.date > oldest.date {
                    top[top.count - 1] = note
                    top.sort { $0.date > $1.date }
                }
            }
            return top
        }
        var seen = Set<String>()
        var out: [Note] = []
        for note in model.notes where !note.title.isEmpty {
            let key = note.title.lowercased()
            if key.contains(q) || note.displayName.lowercased().contains(q),
               seen.insert(key).inserted {
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
/// Renders completed `[[folder/Name]]` links live: brackets + folder are folded away and
/// only "Name" shows — axis-colored and underlined — while the link your cursor is inside
/// expands back to the raw `[[ ]]` so you can edit it (Obsidian-style live preview).
private struct LinkTextView: UIViewRepresentable {
    @Binding var text: String
    @ObservedObject var controller: LinkEditorController
    var autofocus: Bool = false
    var onCommit: ((String) -> Void)? = nil
    var colorForTarget: ((String) -> UIColor)? = nil

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView(usingTextLayoutManager: false)   // TextKit 1 for glyph folding
        tv.delegate = context.coordinator
        tv.layoutManager.delegate = context.coordinator
        let font = UIFont.preferredFont(forTextStyle: .body)
        tv.font = font
        tv.textColor = .label
        tv.typingAttributes = [.font: font, .foregroundColor: UIColor.label]
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 2, bottom: 8, right: 2)
        tv.text = text
        // A keyboard toolbar: a one-tap "Link" that inserts a `[[` token and pops the
        // file autocomplete (so linking needs no knowledge of the `[[` shortcut), plus
        // Done to dismiss the keyboard and reach the buttons it covers.
        let bar = UIToolbar(); bar.sizeToFit()
        let linkItem = UIBarButtonItem(image: UIImage(systemName: "link"),
                                       style: .plain, target: context.coordinator,
                                       action: #selector(Coordinator.insertLinkToken))
        linkItem.title = " Insert link"
        // Text, not a symbol: there's no unambiguous "unlink" glyph, and a missing SF Symbol
        // renders as an empty button.
        let unlinkItem = UIBarButtonItem(title: "Unlink", style: .plain, target: context.coordinator,
                                         action: #selector(Coordinator.unlinkAtCaret))
        bar.items = [
            linkItem,
            unlinkItem,
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(barButtonSystemItem: .done, target: tv, action: #selector(UIResponder.resignFirstResponder)),
        ]
        tv.inputAccessoryView = bar
        context.coordinator.textView = tv
        controller.insertClosure = { [weak c = context.coordinator] value in c?.insertLink(value) }
        context.coordinator.restyle()
        // Bring the keyboard up on appear (Action Button → today's diary), so you can tap
        // the keyboard mic and dictate right away.
        if autofocus {
            DispatchQueue.main.async { tv.becomeFirstResponder() }
        }
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // Keep the coordinator's write-back binding fresh. SwiftUI recreates this
        // struct on every parent re-render; without this, the coordinator keeps
        // writing keystrokes through the ORIGINAL (now stale) `text` binding, so the
        // text view and the @State drift apart and the caret jumps around wildly.
        context.coordinator.parent = self
        // Sync external changes (Summarize, Find links) into the view, preserving the caret.
        guard uiView.markedTextRange == nil, uiView.text != text else { return }
        // While the user is actively typing, the text view is the source of truth. The `[[`
        // autocomplete triggers a SwiftUI re-render whose `text` binding can lag one keystroke
        // behind; pushing that stale value back here dropped a character (e.g. "concierge" →
        // "cncierge"). External edits happen only after the field resigns first responder, so
        // they still flow through — but live typing is left alone.
        guard !uiView.isFirstResponder else { return }
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
        context.coordinator.restyle()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// One rendered link in the raw text: what to hide (`[[`, `folder/`, `]]`), what to
    /// show (`name`), and the target it points at (for the axis color).
    struct LinkPiece { let full: NSRange; let name: NSRange; let hidden: [NSRange]; let target: String }

    static func linkPieces(in text: NSString) -> [LinkPiece] {
        guard let re = try? NSRegularExpression(pattern: "\\[\\[([^\\[\\]]+)\\]\\]") else { return [] }
        var out: [LinkPiece] = []
        for m in re.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
            let full = m.range, inner = m.range(at: 1)
            let innerStr = text.substring(with: inner) as NSString
            let pipe = innerStr.range(of: "|")
            let target = pipe.location != NSNotFound ? innerStr.substring(to: pipe.location) : (innerStr as String)
            let name: NSRange
            if pipe.location != NSNotFound {
                name = NSRange(location: inner.location + pipe.location + 1, length: inner.length - pipe.location - 1)
            } else {
                let slash = innerStr.range(of: "/", options: .backwards)
                name = slash.location != NSNotFound
                    ? NSRange(location: inner.location + slash.location + 1, length: inner.length - slash.location - 1)
                    : inner
            }
            let prefix = NSRange(location: full.location, length: name.location - full.location)
            let sufStart = name.location + name.length
            let suffix = NSRange(location: sufStart, length: full.location + full.length - sufStart)
            out.append(LinkPiece(full: full, name: name, hidden: [prefix, suffix], target: target))
        }
        return out
    }

    final class Coordinator: NSObject, UITextViewDelegate, NSLayoutManagerDelegate {
        var parent: LinkTextView
        weak var textView: UITextView?
        var hiddenRanges: [NSRange] = []
        /// Fingerprint of the last applied fold/color state. Restyle mutates the whole text
        /// storage and invalidates every glyph — far too heavy to run on each keystroke and
        /// caret move (it was jittering the caret). We only pay that cost when this changes.
        private var lastStyleSignature: String?
        /// Coalesces caret-driven restyles. While you DRAG the insertion point, the selection
        /// changes many times a second; folding a link mid-drag reflows the text under your
        /// finger and the caret fights you. We hold off folding until the drag settles.
        private var pendingRestyle: DispatchWorkItem?
        init(_ parent: LinkTextView) { self.parent = parent }

        /// Restyle after the caret stops moving, so a drag doesn't reflow links under the finger.
        private func scheduleRestyle() {
            pendingRestyle?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.restyle() }
            pendingRestyle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
        }

        private func isHidden(_ i: Int) -> Bool { hiddenRanges.contains { NSLocationInRange(i, $0) } }

        /// Recompute which links fold vs. stay raw (the one the cursor is in), restyle the
        /// visible names, and re-run glyph generation so the hiding takes effect. Skips the
        /// expensive storage rewrite whenever the fold/color state is unchanged — i.e. plain
        /// typing, or a caret move that doesn't cross a link edge — which is what stops the
        /// caret from bouncing.
        func restyle() {
            guard let tv = textView, tv.markedTextRange == nil else { return }
            let ns = tv.text as NSString
            let sel = tv.selectedRange
            let full = NSRange(location: 0, length: ns.length)
            let font = tv.font ?? UIFont.preferredFont(forTextStyle: .body)

            var hidden: [NSRange] = []
            var names: [(range: NSRange, color: UIColor)] = []
            for p in LinkTextView.linkPieces(in: ns) {
                // The link the cursor is inside (or touching) stays raw & editable.
                let expanded = NSRange(location: p.full.location, length: p.full.length + 1)
                if NSLocationInRange(sel.location, expanded) || NSIntersectionRange(sel, expanded).length > 0 { continue }
                hidden.append(contentsOf: p.hidden)
                names.append((p.name, parent.colorForTarget?(p.target) ?? .tintColor))
            }

            // Nothing about folding/coloring changed → don't touch the text storage or glyphs.
            // (Newly typed plain text already inherits `typingAttributes`, so it looks right
            // without a rewrite.) This early-out is the whole fix for the bouncing caret.
            var sig = ""
            for r in hidden { sig += "h\(r.location).\(r.length)" }
            for n in names { sig += "n\(n.range.location).\(n.range.length).\(n.color.hashValue)" }
            if sig == lastStyleSignature { return }
            lastStyleSignature = sig

            let storage = tv.textStorage
            // Rewriting the whole text storage moves the insertion point — UIKit re-resolves
            // the selection against the new attribute runs. Capture it and put it back, or
            // the caret hops every time the fold state changes (which is every time you move
            // in or out of a link — i.e. constantly, while editing one).
            let selBefore = tv.selectedRange
            storage.beginEditing()
            storage.setAttributes([.font: font, .foregroundColor: UIColor.label], range: full)
            for n in names {
                storage.addAttribute(.foregroundColor, value: n.color, range: n.range)
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: n.range)
            }
            storage.endEditing()
            if tv.selectedRange != selBefore, selBefore.location + selBefore.length <= ns.length {
                tv.selectedRange = selBefore
            }
            hiddenRanges = hidden
            tv.typingAttributes = [.font: font, .foregroundColor: UIColor.label]
            let lm = tv.layoutManager
            lm.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
            lm.invalidateDisplay(forCharacterRange: full)
        }

        // MARK: NSLayoutManagerDelegate — fold hidden ranges to zero-width, undrawn glyphs.
        func layoutManager(_ layoutManager: NSLayoutManager,
                           shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                           properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                           characterIndexes charIndexes: UnsafePointer<Int>,
                           font: UIFont, forGlyphRange glyphRange: NSRange) -> Int {
            guard !hiddenRanges.isEmpty else { return 0 }
            var newProps = [NSLayoutManager.GlyphProperty](repeating: [], count: glyphRange.length)
            var changed = false
            for i in 0..<glyphRange.length {
                if isHidden(charIndexes[i]) { newProps[i] = .controlCharacter; changed = true }
                else { newProps[i] = props[i] }
            }
            guard changed else { return 0 }
            layoutManager.setGlyphs(glyphs, properties: &newProps, characterIndexes: charIndexes,
                                    font: font, forGlyphRange: glyphRange)
            return glyphRange.length
        }

        func layoutManager(_ layoutManager: NSLayoutManager,
                           shouldUse action: NSLayoutManager.ControlCharacterAction,
                           forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
            isHidden(charIndex) ? .zeroAdvancement : action
        }

        /// Toolbar "Unlink": turn the link the caret is in back into plain text, keeping what
        /// it read as. Deleting a link by hand means getting a caret between four brackets and
        /// backspacing precisely — which is exactly where the editor is hardest to control.
        @objc func unlinkAtCaret() {
            guard let tv = textView else { return }
            let ns = tv.text as NSString
            let caret = tv.selectedRange.location
            let pieces = LinkTextView.linkPieces(in: ns)
            // The link the caret sits in, or touches on either edge.
            guard let piece = pieces.first(where: {
                caret >= $0.full.location && caret <= $0.full.location + $0.full.length
            }) else { return }
            let visible = ns.substring(with: piece.name)
            tv.text = ns.replacingCharacters(in: piece.full, with: visible)
            let end = piece.full.location + (visible as NSString).length
            tv.selectedRange = NSRange(location: end, length: 0)
            parent.text = tv.text
            setQuery(nil)
            restyle()
            parent.onCommit?(tv.text)      // the link is gone from the graph straight away
        }

        /// Toolbar "Link": insert a `[[` token at the caret and show the file picker.
        @objc func insertLinkToken() {
            guard let tv = textView else { return }
            if !tv.isFirstResponder { tv.becomeFirstResponder() }
            let range = tv.selectedRange
            let ns = tv.text as NSString
            // If we're already inside an open, unclosed `[[`, don't stack another — just
            // re-show the picker. (This is what made repeated taps pile up "[[".)
            let before = ns.substring(to: min(range.location, ns.length)) as NSString
            let open = before.range(of: "[[", options: .backwards)
            if open.location != NSNotFound,
               !before.substring(from: open.location + 2).contains("]]") {
                updateQuery(); return
            }
            // A leading space keeps the token clean when inserted mid-word.
            let needsSpace = range.location > 0 && !ns.substring(with: NSRange(location: range.location - 1, length: 1)).allSatisfy({ $0 == " " || $0 == "\n" })
            // Write the whole `[[]]` and land the caret between the brackets, so you can
            // just type the name — and so abandoning the picker leaves a closed link, not a
            // dangling `[[`. (An empty `[[]]` doesn't match the link regex, so it stays
            // visible and unfolded while you type into it.)
            let insert = (needsSpace ? " [[]]" : "[[]]")
            tv.text = ns.replacingCharacters(in: range, with: insert)
            let loc = range.location + (insert as NSString).length - 2
            tv.selectedRange = NSRange(location: loc, length: 0)
            parent.text = tv.text
            updateQuery()
        }

        func textViewDidChange(_ tv: UITextView) {
            pendingRestyle?.cancel()   // typing supersedes a pending caret-move restyle
            parent.text = tv.text; updateQuery(); restyle()
        }
        func textViewDidChangeSelection(_ tv: UITextView) {
            // Sync the binding BEFORE updateQuery re-renders (showing the [[ suggestions),
            // so updateUIView never sees a stale, one-behind value to snap the caret to.
            if parent.text != tv.text { parent.text = tv.text }
            updateQuery()
            // Fold/unfold the link the caret moved into or out of — but DEFER it so dragging
            // the insertion point doesn't reflow links mid-gesture and yank the caret around.
            scheduleRestyle()
        }

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
            // Swallow the closing `]]` sitting just past the caret — the toolbar button
            // writes one, and without this the finished link would trail a stray `]]`.
            var end = clamped
            if ns.length >= end + 2, ns.substring(with: NSRange(location: end, length: 2)) == "]]" { end += 2 }
            let replace = NSRange(location: open.location, length: end - open.location)
            let insertText = "[[\(fullTitle)]] "
            let newText = ns.replacingCharacters(in: replace, with: insertText)
            tv.text = newText
            parent.text = newText
            let newCaret = open.location + (insertText as NSString).length
            if let pos = tv.position(from: tv.beginningOfDocument, offset: newCaret) {
                tv.selectedTextRange = tv.textRange(from: pos, to: pos)
            }
            setQuery(nil)
            restyle()                      // fold the just-completed link right away
            parent.onCommit?(newText)      // persist the just-added link immediately
        }
    }
}
