import AppIntents
import SwiftUI

/// Shared trigger: set when the Quick-capture intent runs, observed by RootView to
/// present the capture sheet (survives a cold launch better than a notification).
@MainActor final class QuickCapture: ObservableObject {
    static let shared = QuickCapture()
    @Published var requested = false
    /// Set when the "Today's Diary" intent runs — RootView opens today's diary with the
    /// keyboard up, ready to dictate.
    @Published var diaryRequested = false
}

/// An App Shortcut for the Action Button (or Siri / Shortcuts) that opens straight into
/// today's diary with the editor focused, so you can tap the keyboard mic and talk.
struct TodaysDiaryIntent: AppIntent {
    static var title: LocalizedStringResource = "Dictate today's diary"
    static var description = IntentDescription("Open Numinous in today's diary, ready to dictate.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickCapture.shared.diaryRequested = true
        return .result()
    }
}

/// An App Shortcut you can bind to the iPhone Action Button (or run via Siri /
/// Shortcuts) to open Numinous straight into a voice capture.
struct QuickCaptureIntent: AppIntent {
    static var title: LocalizedStringResource = "Quick capture"
    static var description = IntentDescription("Open Numinous and start a quick voice note.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickCapture.shared.requested = true
        return .result()
    }
}

/// An App Shortcut you can bind to the iPhone Action Button (or run via Siri / Shortcuts)
/// to log where you are RIGHT NOW into today's diary — WITHOUT opening the app. One press,
/// a quick confirmation, back to your life. Needs location permission; the first run may
/// prompt for it.
struct LogLocationToDiaryIntent: AppIntent {
    static var title: LocalizedStringResource = "Log location to today's diary"
    static var description = IntentDescription("Save where you are right now into today's diary — no need to open the app.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if let name = await AppModel.shared.logCurrentLocationToTodayDiary() {
            return .result(dialog: "Logged 📍 \(name) to today's diary.")
        }
        return .result(dialog: "Couldn't get your location — check that Numinous has location access.")
    }
}

struct NuminousShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: QuickCaptureIntent(),
            phrases: [
                "Quick capture in \(.applicationName)",
                "New note in \(.applicationName)",
            ],
            shortTitle: "Quick capture",
            systemImageName: "mic"
        )
        AppShortcut(
            intent: TodaysDiaryIntent(),
            phrases: [
                "Dictate today's diary in \(.applicationName)",
                "Today's diary in \(.applicationName)",
            ],
            shortTitle: "Today's diary",
            systemImageName: "calendar.badge.plus"
        )
        AppShortcut(
            intent: LogLocationToDiaryIntent(),
            phrases: [
                "Log my location in \(.applicationName)",
                "Save where I am in \(.applicationName)",
            ],
            shortTitle: "Log location",
            systemImageName: "mappin.and.ellipse"
        )
    }
}
