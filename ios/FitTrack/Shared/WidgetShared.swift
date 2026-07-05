import Foundation
import UserNotifications

/// Daily summary the app writes to the App Group so the home-screen widgets
/// can render without Firebase access. Compiled into both the app and the
/// FitTrackWidgets extension.
struct WidgetSnapshot: Codable, Equatable {
    /// "yyyy-MM-dd" of the day this snapshot describes (local timezone).
    var dayId: String
    var updatedAt: Date
    var isSignedIn: Bool

    // Meals / nutrition
    var caloriesEaten: Int
    var calorieTarget: Int
    var proteinG: Double
    var proteinTargetG: Double
    var carbsG: Double
    var carbTargetG: Double
    var fatG: Double
    var fatTargetG: Double
    var mealsLoggedToday: Int
    var lastMealName: String?

    // Workout
    var isWorkoutDay: Bool
    var todayWorkoutLabel: String?
    var workoutLoggedToday: Bool
    var workoutStreak: Int

    static func empty(isSignedIn: Bool = false) -> WidgetSnapshot {
        WidgetSnapshot(
            dayId: WidgetStore.dayId(),
            updatedAt: Date(),
            isSignedIn: isSignedIn,
            caloriesEaten: 0, calorieTarget: 0,
            proteinG: 0, proteinTargetG: 0,
            carbsG: 0, carbTargetG: 0,
            fatG: 0, fatTargetG: 0,
            mealsLoggedToday: 0, lastMealName: nil,
            isWorkoutDay: false, todayWorkoutLabel: nil,
            workoutLoggedToday: false, workoutStreak: 0
        )
    }

    /// True when the snapshot describes a day other than `date`'s — the
    /// widget should treat counters as zero rather than show stale numbers.
    func isStale(relativeTo date: Date = Date()) -> Bool {
        dayId != WidgetStore.dayId(for: date)
    }
}

enum WidgetStore {
    static let appGroupId = "group.com.shobhit.fittrack"
    static let snapshotKey = "widgetSnapshot.v1"

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = .current
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayId(for date: Date = Date()) -> String {
        dayFormatter.string(from: date)
    }

    static func load() -> WidgetSnapshot? {
        guard let defaults = UserDefaults(suiteName: appGroupId),
              let data = defaults.data(forKey: snapshotKey)
        else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    static func save(_ snapshot: WidgetSnapshot) {
        guard let defaults = UserDefaults(suiteName: appGroupId),
              let data = try? JSONEncoder().encode(snapshot)
        else { return }
        defaults.set(data, forKey: snapshotKey)
    }
}

/// Gym clock-in state, shared through the App Group so the workout widget's
/// interactive Start button (running in the extension process) and the app
/// agree on whether a gym session is running. Starting the clock schedules a
/// local "forgot to clock out?" reminder an hour later; ending it cancels it.
enum GymClock {
    static let startKey = "gymClock.startedAt.v1"
    static let notificationId = "gymClockOutReminder"
    static let reminderDelay: TimeInterval = 3600
    /// A clock left running this long is abandoned, not a workout.
    static let staleAfter: TimeInterval = 12 * 3600

    static var startedAt: Date? {
        guard let defaults = UserDefaults(suiteName: WidgetStore.appGroupId) else { return nil }
        let t = defaults.double(forKey: startKey)
        guard t > 0 else { return nil }
        let started = Date(timeIntervalSince1970: t)
        return Date().timeIntervalSince(started) < staleAfter ? started : nil
    }

    static var isActive: Bool { startedAt != nil }

    static func start(at date: Date = Date()) {
        UserDefaults(suiteName: WidgetStore.appGroupId)?
            .set(date.timeIntervalSince1970, forKey: startKey)
        scheduleClockOutReminder(startedAt: date)
    }

    static func end() {
        UserDefaults(suiteName: WidgetStore.appGroupId)?.removeObject(forKey: startKey)
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [notificationId])
    }

    static func scheduleClockOutReminder(startedAt: Date) {
        let fireIn = startedAt.addingTimeInterval(reminderDelay).timeIntervalSinceNow
        guard fireIn > 1 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Still at the gym?"
        content.body = "You clocked in an hour ago — don't forget to clock out and log your workout."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fireIn, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: notificationId, content: content, trigger: trigger)
        )
    }
}

/// Deep-link contract between the widgets and the app.
/// The app registers the `fittrack` URL scheme and routes these in `onOpenURL`.
enum WidgetDeepLink {
    /// fittrack://log/meal — open the meal logging hub.
    /// fittrack://log/meal?type=breakfast|lunch|dinner|snack — hub with meal type preselected.
    static func logMeal(type: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "fittrack"
        components.host = "log"
        components.path = "/meal"
        if let type { components.queryItems = [URLQueryItem(name: "type", value: type)] }
        return components.url!
    }

    /// fittrack://log/workout — start logging today's workout.
    static var logWorkout: URL { URL(string: "fittrack://log/workout")! }
}
