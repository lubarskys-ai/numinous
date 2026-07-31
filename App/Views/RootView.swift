import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel
    // Initial tab can be set via the NUMINOUS_TAB env var (used for headless
    // screenshots). The avatar is no longer a tab — it's the floating companion.
    @State private var selection: String =
        ProcessInfo.processInfo.environment["NUMINOUS_TAB"] ?? "folders"
    @State private var showAvatar = false
    @State private var showCapture = false
    @State private var companionAction: CompanionAction = .idle
    @State private var companionActionStart = Date()
    @ObservedObject private var quickCapture = QuickCapture.shared

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
            CompanionView(progress: model.maturity, tint: tint,
                          action: companionAction, actionStart: companionActionStart)
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
        // Quick-capture (from the Action Button / Siri / Shortcuts) opens here.
        .sheet(isPresented: $showCapture) { CaptureView(onSaved: { _ in selection = "folders" }) }
        // The companion strolls when you change pages…
        .onChange(of: selection) { _ in trigger(.walk) }
        // …and does a joyful, heart-popping cheer when a new connection forms.
        .onChange(of: model.spark?.id) { id in if id != nil { trigger(.cheer) } }
        .onChange(of: quickCapture.requested) { if $0 { showCapture = true; quickCapture.requested = false } }
        .onAppear { if quickCapture.requested { showCapture = true; quickCapture.requested = false } }
    }

    private func trigger(_ action: CompanionAction) {
        companionAction = action
        companionActionStart = Date()
    }
}
