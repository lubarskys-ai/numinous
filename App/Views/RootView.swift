import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var keyboardVisible = false
    // Initial tab can be set via the NUMINOUS_TAB env var (used for headless
    // screenshots). The avatar is no longer a tab — it's the floating companion.
    @State private var selection: String =
        ProcessInfo.processInfo.environment["NUMINOUS_TAB"] ?? "notes"
    @State private var showAvatar = false
    @State private var showCapture = false
    @State private var companionAction: CompanionAction = .idle
    @State private var companionActionStart = Date()
    @ObservedObject private var quickCapture = QuickCapture.shared

    var body: some View {
        let balance = model.score.axisBalance(over: model.axes)
        let tint = (model.axes.max { (balance[$0.id] ?? 0) < (balance[$1.id] ?? 0) })?.color ?? .accentColor

        TabView(selection: $selection) {
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
            HealthView()
                .tabItem { Label("Health", systemImage: "heart.text.square") }
                .tag("health")
        }
        // The companion follows you across every tab; tap it for the full avatar. It
        // hides while the keyboard is up so it never sits over a note's editing controls
        // (e.g. the "Done" button in the bottom-right).
        .overlay(alignment: .bottomTrailing) {
            if !keyboardVisible {
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
        .fullScreenCover(isPresented: $showAvatar) { AvatarExpandedView() }
        // Quick-capture (from the Action Button / Siri / Shortcuts) opens here.
        .fullScreenCover(isPresented: $showCapture) { ComposeView(prefillTitle: nil, onSaved: { _ in selection = "notes" }) }
        // The companion strolls when you change pages…
        .onChange(of: selection) { _ in trigger(.walk) }
        // …and does a joyful, heart-popping cheer when a new connection forms.
        .onChange(of: model.spark?.id) { id in if id != nil { trigger(.cheer) } }
        // Refresh already-connected sources (contacts, Readwise) when returning to the app.
        .onChange(of: scenePhase) { if $0 == .active { Task { await model.autoSync() } } }
        .onChange(of: quickCapture.requested) { if $0 { showCapture = true; quickCapture.requested = false } }
        .onAppear { if quickCapture.requested { showCapture = true; quickCapture.requested = false } }
    }

    private func trigger(_ action: CompanionAction) {
        companionAction = action
        companionActionStart = Date()
    }
}
