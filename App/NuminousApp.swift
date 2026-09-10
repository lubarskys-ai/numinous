import AppIntents
import SwiftUI

@main
struct NuminousApp: App {
    @StateObject private var model = AppModel.shared

    init() {
        // ASK THE SYSTEM TO RE-INDEX THE ACTION BUTTON'S SHORTCUTS, EVERY LAUNCH.
        //
        // App Shortcuts are registered from the bundle's App Intents metadata at install
        // time, and that index can go stale on its own: an update lands, the phone never
        // re-reads it, and the app stops appearing in Settings → Action Button while its
        // shortcuts are still sitting in the build, intact. Nothing in an app can force a
        // re-registration, but this is the documented nudge, it costs nothing when the index
        // is already right, and it means the fix for a vanished Action Button is "open the
        // app once" rather than "delete and reinstall".
        NuminousShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
    }
}
