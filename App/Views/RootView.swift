import SwiftUI

struct RootView: View {
    // Initial tab can be set via the NUMINOUS_TAB env var (used for headless
    // screenshots); defaults to the Avatar tab.
    @State private var selection: String =
        ProcessInfo.processInfo.environment["NUMINOUS_TAB"] ?? "avatar"

    var body: some View {
        TabView(selection: $selection) {
            AvatarView()
                .tabItem { Label("Avatar", systemImage: "circle.circle") }
                .tag("avatar")
            GraphView()
                .tabItem { Label("Graph", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag("graph")
            FoldersView()
                .tabItem { Label("Folders", systemImage: "folder") }
                .tag("folders")
            CalendarView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag("calendar")
        }
    }
}
