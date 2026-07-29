import SwiftUI

@main
struct NuminousApp: App {
    @StateObject private var store = NoteStore()

    var body: some Scene {
        WindowGroup {
            NoteListView()
                .environmentObject(store)
        }
    }
}
