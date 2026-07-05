import AppIntents
import WidgetKit

/// Starts the shared gym clock from the widget's interactive Start button.
/// Runs in the extension process — no app launch. GymClock.start() persists
/// the start time to the App Group and schedules the clock-out reminder.
struct StartGymSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Gym Session"
    static let description = IntentDescription("Clock in at the gym and start the elapsed timer.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        if !GymClock.isActive {
            GymClock.start()
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
