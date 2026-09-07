import Foundation
import UserNotifications

/// The one thing in Numinous allowed to interrupt you.
///
/// Everything else here waits until you open the app, on purpose — an app whose measure of
/// success is that you use it less has no business buzzing. This is the deliberate exception,
/// and it earns it by being the only notification that arrives with a message already written:
/// somebody's team is playing in two hours, and "big game tonight" is a text you can send in
/// four seconds to a person you have not spoken to in a year.
///
/// THE RULES THAT KEEP IT FROM BECOMING NOISE:
///
///   Nothing is scheduled until you have chosen a team for somebody. Permission is asked at that
///   moment and not at launch, so the question arrives with a reason attached.
///
///   Two hours before kickoff, and never before nine in the morning. Two hours is late enough to
///   be about tonight and early enough to still make a plan; the floor is there because a
///   European kickoff would otherwise wake you at six.
///
///   One per person per game, and at most one a day. A season ticket holder would otherwise be
///   an alarm clock.
///
/// iOS holds sixty-four pending local notifications per app, and no more, so this schedules the
/// soonest few and refills whenever the app is opened.
enum GameNotifier {

    /// Shared with the Setup toggle's @AppStorage, so there is one key and no mirror.
    static let enabledKey = "game_notifications_enabled"
    private static let prefix = "game-"

    /// Off until somebody turns it on. A notification nobody asked for is the thing this app is
    /// supposed to be an alternative to.
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Ask for permission, and report whether we have it. Safe to call repeatedly: iOS shows the
    /// system prompt once and answers from its own record afterwards.
    @discardableResult
    static func requestPermission() async -> Bool {
        let centre = UNUserNotificationCenter.current()
        let settings = await centre.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        default:
            return (try? await centre.requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }

    /// When to fire for a kickoff: two hours before, never before nine, never in the past.
    static func fireDate(forKickoff kickoff: Date, calendar: Calendar = .current) -> Date? {
        var when = kickoff.addingTimeInterval(-2 * 3600)
        let nine = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: when) ?? when
        if when < nine { when = nine }
        // A 9am floor must not push the alert PAST the game it is about — an 8am kickoff is
        // better mentioned late than mentioned after the final whistle.
        if when >= kickoff { when = kickoff.addingTimeInterval(-15 * 60) }
        return when > Date().addingTimeInterval(60) ? when : nil
    }

    /// Replace everything pending with the soonest games we know about.
    ///
    /// Rebuilt wholesale rather than added to, because fixtures move: a postponed game whose
    /// notification was scheduled last week would otherwise still fire.
    static func reschedule(_ upcoming: [(personID: UUID, name: String, line: String,
                                         league: String, kickoff: Date)]) async {
        let centre = UNUserNotificationCenter.current()
        let pending = await centre.pendingNotificationRequests()
        centre.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })

        guard enabled, await requestPermission() else { return }

        var perDay: [Date: Int] = [:]
        var made = 0
        let calendar = Calendar.current
        for game in upcoming.sorted(by: { $0.kickoff < $1.kickoff }) {
            guard made < 20, let when = fireDate(forKickoff: game.kickoff) else { continue }
            // At most one a day. Somebody with four teams has a game most evenings, and four
            // notifications on a Saturday is the behaviour this app exists to avoid.
            let day = calendar.startOfDay(for: when)
            guard perDay[day, default: 0] < 1 else { continue }
            perDay[day] = perDay[day, default: 0] + 1

            let content = UNMutableNotificationContent()
            content.title = "\(game.name)'s team plays"
            content.body = "\(game.line) · \(game.league)"
            content.sound = .default
            content.userInfo = ["noteID": game.personID.uuidString]

            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: when)
            let request = UNNotificationRequest(
                identifier: prefix + game.personID.uuidString + "-" + String(Int(game.kickoff.timeIntervalSince1970)),
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
            try? await centre.add(request)
            made += 1
        }
    }

    /// Drop everything pending — for switching the feature off.
    static func cancelAll() async {
        let centre = UNUserNotificationCenter.current()
        let pending = await centre.pendingNotificationRequests()
        centre.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
    }
}
