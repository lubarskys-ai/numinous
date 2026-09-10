import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var keyboardVisible = false
    // Initial tab can be set via the NUMINOUS_TAB env var (used for headless
    // screenshots). The avatar is no longer a tab — it's the floating companion.
    @State private var selection: String =
        ProcessInfo.processInfo.environment["NUMINOUS_TAB"] ?? "home"
    /// ONE COVER, DRIVEN BY AN ENUM. There were four `.fullScreenCover` modifiers stacked on
    /// this same view — onboarding, avatar, capture, diary — and SwiftUI honours only one of a
    /// stack reliably: the rest silently fail to present. FoldersView already learned this the
    /// hard way ("stacking several .sheet(item:) on one view let some, like Merge, silently
    /// fail to present") and collapsed to a single enum-driven sheet. This is the same fix,
    /// and it is why the Action Button appeared to need pressing twice.
    private enum Cover: Identifiable {
        case avatar(AvatarMode)
        case capture
        case diary
        var id: String {
            switch self {
            case .avatar(let m): return "avatar-\(m)"
            case .capture:       return "capture"
            case .diary:         return "diary"
            }
        }
    }
    @State private var cover: Cover?
    @State private var companionAction: CompanionAction = .idle
    @State private var companionActionStart = Date()
    @ObservedObject private var quickCapture = QuickCapture.shared

    var body: some View {
        let balance = model.score.axisBalance(over: model.lifeAxes)
        let tint = (model.lifeAxes.max { (balance[$0.id] ?? 0) < (balance[$1.id] ?? 0) })?.color ?? .accentColor

        // You land on Home — the figure and one thing to do. Health is no longer a tab: it's
        // a line on Home that speaks only when it has something to import. Calendar keeps
        // its tab; it's a place you go on purpose, not a slice of the same notes.
        TabView(selection: $selection) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
                .tag("home")
            NotesView()
                .tabItem { Label("Notes", systemImage: "note.text") }
                .tag("notes")
            FoldersView()
                .tabItem { Label("Folders", systemImage: "folder") }
                .tag("folders")
            CalendarView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag("calendar")
            MapView()
                .tabItem { Label("Map", systemImage: "map") }
                .tag("map")
        }
        // The companion follows you across every tab; tap it for the full avatar. It
        // hides while the keyboard is up so it never sits over a note's editing controls
        // (e.g. the "Done" button in the bottom-right).
        .overlay(alignment: .bottomTrailing) {
            if !keyboardVisible && selection != "home" {   // Home shows the figure full-size already
                CompanionView(progress: model.maturity, tint: tint,
                              action: companionAction, actionStart: companionActionStart)
                    .frame(width: 100, height: 116)
                    .contentShape(Rectangle())
                    .onTapGesture { cover = .avatar(.avatar) }
                    .padding(.trailing, 8)
                    .padding(.bottom, 54)
                    .accessibilityLabel("Open avatar")
                    .transition(.opacity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { keyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { keyboardVisible = false }
        }
        // A full-screen flourish whenever a new connection forms.
        .overlay { ConnectionSparkOverlay() }
        // Guided first capture on a brand-new vault — the first thing a new user sees instead
        // of an empty app. Dismisses itself once the reveal's "Enter Numinous" is tapped.
        .fullScreenCover(isPresented: Binding(
            get: { model.needsOnboarding },
            set: { if !$0 { model.dismissOnboarding() } }
        )) { OnboardingView() }
        // The avatar, quick-capture (Action Button / Siri / Shortcuts) and "Today's diary"
        // all present through this one cover — see `Cover`.
        .fullScreenCover(item: $cover) { which in
            switch which {
            case .avatar(let mode):
                AvatarExpandedView(mode: mode)
            case .capture:
                ComposeView(prefillTitle: nil, onSaved: { _ in selection = "notes" })
            case .diary:
                ComposeView(prefillTitle: nil, diary: true, autofocus: true,
                            onSaved: { _ in selection = "notes" })
            }
        }
        // The companion strolls when you change pages…
        .onChange(of: selection) { _ in trigger(.walk) }
        // …and does a joyful, heart-popping cheer when a new connection forms.
        .onChange(of: model.spark?.id) { id in if id != nil { trigger(.cheer) } }
        // "See in graph" from a note opens the avatar, spotlighting that note's connections.
        // "See in graph" is about connections, so it opens the graph and not the figure.
        .onChange(of: model.avatarFocus) { if $0 != nil { cover = .avatar(.graph) } }
        // Refresh already-connected sources (contacts, Readwise) when returning to the app.
        .onChange(of: scenePhase) {
            if $0 == .active {
                Task { await model.autoSync() }
                // Top the notification queue back up. iOS holds only so many pending alerts, and
                // the app cannot wake itself to look at fixtures, so every time you open it is
                // the chance to schedule the next week.
                Task { await model.refreshGameNotifications() }
                // A press that arrived before the scene was live is still waiting.
                presentPending()
            }
            else if $0 == .background { model.flush() }   // truly leaving → force-write pending save
        }
        .onChange(of: quickCapture.requested) { _ in presentPending() }
        .onChange(of: quickCapture.diaryRequested) { _ in presentPending() }
        .onAppear { presentPending() }
    }

    /// Raise whatever the Action Button asked for — but only once there is a live scene to
    /// raise it into.
    ///
    /// THE OTHER HALF OF THE DOUBLE PRESS. An App Intent with `openAppWhenRun` sets its flag
    /// and hands the app to the system to foreground, so on a cold launch the request arrives
    /// while the scene is still `.inactive` — and a cover presented then is dropped on the
    /// floor by UIKit. The flag was being cleared in the same breath, so that press was simply
    /// gone, and the app only responded to the second one, by which time it was already
    /// running. Holding the request until `.active` means the first press is the one that
    /// works.
    private func presentPending() {
        guard scenePhase == .active, cover == nil else { return }
        if quickCapture.requested {
            quickCapture.requested = false
            cover = .capture
        } else if quickCapture.diaryRequested {
            quickCapture.diaryRequested = false
            cover = .diary
        }
    }

    private func trigger(_ action: CompanionAction) {
        guard action != .idle else { return }
        let start = Date()
        companionAction = action
        companionActionStart = start
        // Fall back to idle after the action plays, so the companion's animation pauses
        // again (see CompanionView) instead of redrawing forever. Skipped if a newer
        // action started meanwhile.
        let duration: Double = action == .walk ? 1.6 : (action == .cheer ? 1.9 : 2.2)
        Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if companionActionStart == start { companionAction = .idle }
        }
    }
}
