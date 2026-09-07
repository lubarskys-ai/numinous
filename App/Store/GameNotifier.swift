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
///   A day before kickoff, and never before nine in the morning. A day is what a person needs to
///   actually do something about it — "want to watch it Saturday?" has to arrive while Saturday
///   is still free. Two hours' warning only ever produces "big game tonight", which is a nicer
///   message to receive than to be too late to act on. The 9am floor is there because an early
///   kickoff would otherwise be announced at six in the morning.
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

    /// How far ahead of kickoff the alert lands.
    static let leadTime: TimeInterval = 24 * 3600

    /// When to fire for a kickoff: a day before, never before nine, never in the past.
    static func fireDate(forKickoff kickoff: Date, now: Date = Date(),
                         calendar: Calendar = .current) -> Date? {
        var when = kickoff.addingTimeInterval(-leadTime)

        // THE DAY-BEFORE MOMENT MAY ALREADY BE GONE — you added the team this morning and they
        // play tonight. A day's notice is the intent, not a condition: better to say it soon
        // than to say nothing about a game that has not started. Not within three hours of
        // kickoff, though, because by then it is an interruption about something you can no
        // longer make a plan around.
        if when <= now, kickoff.timeIntervalSince(now) > 3 * 3600 {
            when = now.addingTimeInterval(30 * 60)
        }

        let nine = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: when) ?? when
        if when < nine { when = nine }
        // The floor must never push the alert past the game it is about — a game tomorrow
        // morning is better mentioned late tonight than after the final whistle.
        if when >= kickoff { when = kickoff.addingTimeInterval(-15 * 60) }
        return when > now.addingTimeInterval(60) ? when : nil
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

            // ARRIVING A DAY OUT MEANS THE ALERT HAS TO SAY WHEN. Two hours before, "their team
            // plays" could only mean tonight; a day before, a notification that does not name
            // the time is a notification you have to open the app to understand.
            let content = UNMutableNotificationContent()
            content.title = "\(game.name)'s team plays \(AppModel.gameWhen(game.kickoff).lowercased())"
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
