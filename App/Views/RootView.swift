import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            NoteListView()
                .tabItem { Label("Notes", systemImage: "note.text") }
            GrowthView()
                .tabItem { Label("Growth", systemImage: "leaf") }
        }
    }
}
