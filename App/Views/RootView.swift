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
    @State private var showAvatar = false
    @State private var showCapture = false
    @State private var showDiary = false
    @State private var companionAction: CompanionAction = .idle
    @State private var companionActionStart = Date()
    @ObservedObject private var quickCapture = QuickCapture.shared

    var body: some View {
        let balance = model.score.axisBalance(over: model.axes)
        let tint = (model.axes.max { (balance[$0.id] ?? 0) < (balance[$1.id] ?? 0) })?.color ?? .accentColor

        // Four tabs, not six. You land on Home — the figure and one thing to do — and the
        // rest are places you go FROM there. Calendar and Health used to be tabs; they're
        // ways of slicing the same notes, so they moved behind Home rather than asking a
        // brand-new user to choose between six filing systems on first launch.
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
                    .onTapGesture { showAvatar = true }
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
        .fullScreenCover(isPresented: $showAvatar) { AvatarExpandedView() }
        // Quick-capture (from the Action Button / Siri / Shortcuts) opens here.
        .fullScreenCover(isPresented: $showCapture) { ComposeView(prefillTitle: nil, onSaved: { _ in selection = "notes" }) }
        // "Today's diary" (Action Button / Siri) opens the diary with the keyboard up.
        .fullScreenCover(isPresented: $showDiary) { ComposeView(prefillTitle: nil, diary: true, autofocus: true, onSaved: { _ in selection = "notes" }) }
        // The companion strolls when you change pages…
        .onChange(of: selection) { _ in
            trigger(.walk)
            #if DEBUG
            // Measure the actual hitch: how long the main thread stays busy between the tab
            // changing and the run loop coming back to us. That IS the stickiness, and it
            // tells us WHICH tab is expensive instead of us guessing.
            let t0 = CFAbsoluteTimeGetCurrent()
            let tab = selection
            DispatchQueue.main.async {
                let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                if ms > 16 { print(String(format: "⏱️[perf] tab → %@ blocked main thread %.0fms", tab, ms)) }
            }
            #endif
        }
        // …and does a joyful, heart-popping cheer when a new connection forms.
        .onChange(of: model.spark?.id) { id in if id != nil { trigger(.cheer) } }
        // "See in graph" from a note opens the avatar, spotlighting that note's connections.
        .onChange(of: model.avatarFocus) { if $0 != nil { showAvatar = true } }
        // Refresh already-connected sources (contacts, Readwise) when returning to the app.
        .onChange(of: scenePhase) {
            if $0 == .active { Task { await model.autoSync() } }
            else if $0 == .background { model.flush() }   // truly leaving → force-write pending save
        }
        .onChange(of: quickCapture.requested) { if $0 { showCapture = true; quickCapture.requested = false } }
        .onChange(of: quickCapture.diaryRequested) { if $0 { showDiary = true; quickCapture.diaryRequested = false } }
        .onAppear {
            if quickCapture.requested { showCapture = true; quickCapture.requested = false }
            if quickCapture.diaryRequested { showDiary = true; quickCapture.diaryRequested = false }
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
