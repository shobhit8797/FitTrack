import SwiftUI

// The in-app weekly weigh-in prompt (spec: weight reminders). Surfaced by
// MainTabView the first time the app opens on/after a weigh-in day when the
// user hasn't logged a weight for the current cycle. It's a gentle intro — the
// actual entry happens in WeightLogSheet, presented from the "Log weight"
// button — so a foreground doesn't drop the user straight into a form.
struct WeightCheckInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showLog = false

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            Spacer(minLength: 0)

            Text("⚖️")
                .font(.system(size: 56))
                .accessibilityHidden(true)

            VStack(spacing: Theme.Spacing.sm) {
                Text("Time for your weekly weigh-in")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("Logging your weight once a week keeps your progress and calorie targets on track.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Theme.Spacing.m)

            Spacer(minLength: 0)

            VStack(spacing: Theme.Spacing.sm) {
                Button {
                    Haptics.tap()
                    showLog = true
                } label: {
                    Text("Log weight")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Theme.accentTeal)

                Button("Maybe later") { dismiss() }
                    .font(.subheadline)
                    .tint(.secondary)
            }
        }
        .padding(Theme.Spacing.l)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        // Logging succeeds → dismiss the whole prompt; the weight stream then
        // clears the daily follow-up notifications for this cycle.
        .sheet(isPresented: $showLog, onDismiss: { dismiss() }) {
            WeightLogSheet()
        }
    }
}

/// Once-a-day throttle for the in-app weigh-in prompt, so it doesn't reappear on
/// every foreground while a weight is still unlogged. Stored in the App Group so
/// it's shared with the widget process and survives relaunch.
enum WeightCheckIn {
    private static let key = "weightCheckInLastPromptedDay"
    private static var store: UserDefaults? { UserDefaults(suiteName: WidgetStore.appGroupId) }

    private static func todayKey() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    static func promptedToday() -> Bool { store?.string(forKey: key) == todayKey() }
    static func markPromptedToday() { store?.set(todayKey(), forKey: key) }
}
