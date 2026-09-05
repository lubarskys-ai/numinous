import SwiftUI

/// A note opened in a sheet, with its links still working.
///
/// `NoteDetailView` is full of `NavigationLink(value:)` — the wiki links, the "Mentioned in"
/// backlinks, the places. A `NavigationLink(value:)` does nothing at all unless some enclosing
/// stack has registered a `navigationDestination` for that value's type, and it fails SILENTLY:
/// the row highlights on tap and then nothing happens.
///
/// Three places presented the note in a bare `NavigationStack` — the map, the Reconnect list,
/// and a note opened from inside another note. In every one of them, tapping a name under
/// "Mentioned in" did nothing, which looked like a broken list and was actually a missing line.
///
/// One wrapper, used everywhere a note is presented outside the main tab stacks, so the
/// registration cannot be forgotten again.
struct NoteSheet: View {
    let noteID: UUID

    var body: some View {
        NavigationStack {
            NoteDetailView(noteID: noteID)
                .navigationDestination(for: UUID.self) { NoteDetailView(noteID: $0) }
        }
    }
}
