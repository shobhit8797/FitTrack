import Foundation
import UserNotifications

// Schedules local notifications for supplement/medication reminders. Everything
// is on-device — no push server, no Firebase Messaging — because these are
// fixed, user-defined daily/weekly alerts that iOS can fire on a repeating
// calendar trigger even when the app is closed.
//
// Reminder definitions live in Firestore (Repository+Reminders); this service is
// the projection of those records onto the system notification center. The app
// calls `sync(reminders:)` whenever the list changes, which wipes our previously
// scheduled requests and re-adds one repeating trigger per (reminder × time ×
// weekday).

@Observable
@MainActor
final class NotificationService {
    /// Current system authorization, refreshed on launch and after any request.
    var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// Every request we schedule is prefixed with this, so a re-sync only clears
    /// our own reminders and never any future notification the app might add.
    private static let idPrefix = "rem_"

    private let center = UNUserNotificationCenter.current()

    var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional
    }
    var isDenied: Bool { authorizationStatus == .denied }

    func refreshAuthorizationStatus() async {
        authorizationStatus = await center.notificationSettings().authorizationStatus
    }

    /// Ask for alert/sound/badge permission. Returns whether it's now usable.
    /// Safe to call repeatedly — iOS only shows the system prompt once; later
    /// calls just return the standing decision.
    @discardableResult
    func requestAuthorization() async -> Bool {
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshAuthorizationStatus()
        return granted
    }

    /// Quiet provisional grant so app-scheduled alerts (e.g. the gym clock-out
    /// reminder started from the widget) can deliver before the user has ever
    /// hit a flow that shows the full permission dialog. Never prompts, and
    /// doesn't spend the one-time system alert — a later `requestAuthorization`
    /// still upgrades to full authorization in context.
    func requestProvisionalAuthorizationIfNeeded() async {
        await refreshAuthorizationStatus()
        guard authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge, .provisional])
        await refreshAuthorizationStatus()
    }

    /// Reschedule all reminder notifications from the given list. Removes our
    /// previously scheduled requests first so edits/deletes take effect and we
    /// never accumulate stale alerts. No-op work is cheap, so callers can invoke
    /// this liberally (on launch, on every Firestore change).
    func sync(reminders: [SupplementReminder]) async {
        // Clear only the requests we own.
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)

        // Nothing to (re)schedule unless the user has actually granted permission.
        await refreshAuthorizationStatus()
        guard isAuthorized else { return }

        for reminder in reminders where reminder.enabled {
            for request in requests(for: reminder) {
                try? await center.add(request)
            }
        }
    }

    /// Build one repeating calendar request per (time × weekday). An empty
    /// weekday list means "every day", which is a single daily trigger per time.
    private func requests(for reminder: SupplementReminder) -> [UNNotificationRequest] {
        let content = UNMutableNotificationContent()
        content.title = "Time for your \(reminder.kind.label.lowercased())"
        content.body = [reminder.name, reminder.dosage?.trimmed]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
        if content.body.isEmpty { content.body = reminder.name }
        content.sound = .default
        content.userInfo = ["reminderId": reminder.id]

        // Calendar weekdays are 1=Sun..7=Sat; our model stores 0=Sun..6=Sat.
        let weekdays: [Int?] = reminder.isEveryDay ? [nil] : reminder.weekdays.map { $0 + 1 }

        var requests: [UNNotificationRequest] = []
        for time in reminder.times {
            for weekday in weekdays {
                var comps = DateComponents()
                comps.hour = time.hour
                comps.minute = time.minute
                if let weekday { comps.weekday = weekday }
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
                // Stable, collision-free id: prefix + reminder + time + weekday.
                let id = "\(Self.idPrefix)\(reminder.id)_\(time.id)_\(weekday.map(String.init) ?? "all")"
                requests.append(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            }
        }
        return requests
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
