import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel
    // Initial tab can be set via the NUMINOUS_TAB env var (used for headless
    // screenshots). The avatar is no longer a tab — it's the floating companion.
    @State private var selection: String =
        ProcessInfo.processInfo.environment["NUMINOUS_TAB"] ?? "folders"
    @State private var showAvatar = false

    var body: some View {
        let balance = model.score.axisBalance(over: model.axes)
        let tint = (model.axes.max { (balance[$0.id] ?? 0) < (balance[$1.id] ?? 0) })?.color ?? .accentColor

        TabView(selection: $selection) {
            FoldersView()
                .tabItem { Label("Folders", systemImage: "folder") }
                .tag("folders")
            CalendarView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag("calendar")
            HealthView()
                .tabItem { Label("Health", systemImage: "heart.text.square") }
                .tag("health")
        }
        // The companion follows you across every tab; tap it for the full avatar.
        .overlay(alignment: .bottomTrailing) {
            CompanionView(progress: model.score.fidelity(), tint: tint)
                .frame(width: 100, height: 116)
                .contentShape(Rectangle())
                .onTapGesture { showAvatar = true }
                .padding(.trailing, 8)
                .padding(.bottom, 54)
                .accessibilityLabel("Open avatar")
        }
        // A full-screen flourish whenever a new connection forms.
        .overlay { ConnectionSparkOverlay() }
        .fullScreenCover(isPresented: $showAvatar) { AvatarExpandedView() }
    }
}
