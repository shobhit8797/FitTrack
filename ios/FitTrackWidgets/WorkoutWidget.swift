import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Timeline

struct WorkoutEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    var gymStartedAt: Date? = nil

    /// Bubble to the top of a Smart Stack while the gym clock runs,
    /// stay visible on unlogged workout days, fade otherwise.
    var relevance: TimelineEntryRelevance? {
        if gymStartedAt != nil {
            return TimelineEntryRelevance(score: 100)
        }
        if snapshot.isSignedIn, snapshot.isWorkoutDay, !snapshot.workoutLoggedToday {
            return TimelineEntryRelevance(score: 60)
        }
        return TimelineEntryRelevance(score: 10)
    }
}

struct WorkoutTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> WorkoutEntry {
        WorkoutEntry(date: Date(), snapshot: .workoutSample())
    }

    func getSnapshot(in context: Context, completion: @escaping (WorkoutEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
        } else {
            completion(WorkoutEntry(date: Date(), snapshot: currentSnapshot(), gymStartedAt: GymClock.startedAt))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WorkoutEntry>) -> Void) {
        let now = Date()
        let entry = WorkoutEntry(date: now, snapshot: currentSnapshot(at: now), gymStartedAt: GymClock.startedAt)
        let startOfToday = Calendar.current.startOfDay(for: now)
        let nextMidnight = Calendar.current.date(byAdding: .day, value: 1, to: startOfToday)
            ?? now.addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(nextMidnight)))
    }

    private func currentSnapshot(at date: Date = Date()) -> WidgetSnapshot {
        guard var snapshot = WidgetStore.load() else { return .empty() }
        if snapshot.isStale(relativeTo: date) {
            // New day: nothing logged yet, but keep streak and plan label.
            snapshot.workoutLoggedToday = false
        }
        return snapshot
    }
}

// MARK: - Display state

private enum WorkoutDisplayState {
    case signedOut
    case restDay
    case pending(label: String)
    case done(label: String)
    case active(startedAt: Date)

    init(_ snapshot: WidgetSnapshot, gymStartedAt: Date?) {
        if !snapshot.isSignedIn {
            self = .signedOut
        } else if let gymStartedAt {
            self = .active(startedAt: gymStartedAt)
        } else if snapshot.workoutLoggedToday {
            self = .done(label: snapshot.todayWorkoutLabel ?? "Workout")
        } else if !snapshot.isWorkoutDay, snapshot.todayWorkoutLabel == nil {
            self = .restDay
        } else {
            self = .pending(label: snapshot.todayWorkoutLabel ?? "Workout")
        }
    }

    var badgeColor: Color {
        switch self {
        case .pending, .done, .active: WidgetTheme.accentTeal
        case .restDay, .signedOut: .secondary
        }
    }

    var badgeIcon: String {
        switch self {
        case .active: "timer"
        default: "dumbbell.fill"
        }
    }

    var title: String {
        switch self {
        case .signedOut: "Not signed in"
        case .restDay: "Rest day"
        case .active: "At the gym"
        case .pending(let label), .done(let label): label
        }
    }

    var titleStyle: Color {
        switch self {
        case .signedOut, .restDay: .secondary
        case .pending, .done, .active: .primary
        }
    }
}

// MARK: - Shared pieces

private struct IconBadge: View {
    var systemImage: String
    var color: Color
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.48, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(
                color.opacity(0.14),
                in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            )
    }
}

private struct StreakBadge: View {
    var count: Int
    var expanded = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "flame.fill")
                .font(.caption2.weight(.semibold))
            Text(expanded ? "\(count) day streak" : "\(count)")
                .font(.system(.caption, design: .rounded).weight(.bold))
                .privacySensitive()
        }
        .foregroundStyle(WidgetTheme.energy)
    }
}

private struct StatusLine: View {
    let state: WorkoutDisplayState

    var body: some View {
        switch state {
        case .signedOut:
            Text("Open FitTrack to sign in")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .restDay:
            HStack(spacing: 4) {
                Image(systemName: "plus.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(WidgetTheme.accentTeal.opacity(0.7))
                Text("Log anyway")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        case .pending:
            Text("Not logged yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .done:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                Text("Done today")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(WidgetTheme.accentTeal)
        case .active:
            EmptyView() // Active state renders the elapsed timer instead.
        }
    }
}

/// Live elapsed time since clock-in; updates without new timeline entries.
private struct ElapsedTimer: View {
    let startedAt: Date

    var body: some View {
        Text(startedAt, style: .timer)
            .font(.system(.title3, design: .rounded).weight(.bold))
            .monospacedDigit()
            .multilineTextAlignment(.leading)
            .foregroundStyle(.primary)
            .privacySensitive()
    }
}

/// Compact interactive clock-in button for the small family.
private struct StartGymButton: View {
    var title = "Start Gym"
    var quiet = false

    var body: some View {
        Button(intent: StartGymSessionIntent()) {
            HStack(spacing: 4) {
                Image(systemName: "play.fill")
                    .font(.caption2.weight(.bold))
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(quiet ? WidgetTheme.accentTeal : Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                quiet
                    ? AnyShapeStyle(WidgetTheme.accentTeal.opacity(0.14))
                    : AnyShapeStyle(WidgetTheme.accentGradient),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Small

private struct WorkoutSmallView: View {
    let entry: WorkoutEntry

    private var snapshot: WidgetSnapshot { entry.snapshot }
    private var state: WorkoutDisplayState { WorkoutDisplayState(snapshot, gymStartedAt: entry.gymStartedAt) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top) {
                IconBadge(systemImage: state.badgeIcon, color: state.badgeColor)
                Spacer(minLength: 0)
                if snapshot.isSignedIn, snapshot.workoutStreak > 0 {
                    StreakBadge(count: snapshot.workoutStreak)
                }
            }
            Spacer(minLength: 0)
            Text(state.title)
                .font(.system(.headline, design: .rounded).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(state.titleStyle)
                .privacySensitive()
            switch state {
            case .active(let startedAt):
                ElapsedTimer(startedAt: startedAt)
                // The whole small widget already deep-links; this just makes
                // the tap target visible.
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                        .font(.caption2.weight(.bold))
                    Text("Add workout")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(WidgetTheme.accentGradient, in: Capsule())
                .padding(.top, 2)
            case .pending, .restDay:
                StatusLine(state: state)
                StartGymButton()
                    .padding(.top, 2)
            case .done:
                StatusLine(state: state)
                StartGymButton(title: "Start again", quiet: true)
                    .padding(.top, 2)
            case .signedOut:
                StatusLine(state: state)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - Medium

private struct WorkoutMediumView: View {
    let entry: WorkoutEntry

    private var snapshot: WidgetSnapshot { entry.snapshot }
    private var state: WorkoutDisplayState { WorkoutDisplayState(snapshot, gymStartedAt: entry.gymStartedAt) }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                IconBadge(systemImage: state.badgeIcon, color: state.badgeColor, size: 44)
                Spacer(minLength: 0)
                Text(state.title)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(state.titleStyle)
                    .privacySensitive()
                if case .active(let startedAt) = state {
                    ElapsedTimer(startedAt: startedAt)
                } else {
                    StatusLine(state: state)
                }
            }
            Spacer(minLength: 8)
            if snapshot.isSignedIn {
                VStack(alignment: .trailing, spacing: 10) {
                    if snapshot.workoutStreak > 0 {
                        StreakBadge(count: snapshot.workoutStreak, expanded: true)
                    }
                    Spacer(minLength: 0)
                    action
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .active:
            Link(destination: WidgetDeepLink.logWorkout) {
                capsuleLabel("Add Workout", systemImage: "plus.circle.fill", prominent: true)
            }
        case .pending, .restDay:
            Button(intent: StartGymSessionIntent()) {
                capsuleLabel("Start Gym", systemImage: "play.fill", prominent: true)
            }
            .buttonStyle(.plain)
        case .done:
            Button(intent: StartGymSessionIntent()) {
                capsuleLabel("Start again", systemImage: "play.fill", prominent: false)
            }
            .buttonStyle(.plain)
        case .signedOut:
            EmptyView()
        }
    }

    private func capsuleLabel(_ title: String, systemImage: String, prominent: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
            Text(title)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
        }
        .foregroundStyle(prominent ? Color.white : WidgetTheme.accentTeal)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            prominent
                ? AnyShapeStyle(WidgetTheme.accentGradient)
                : AnyShapeStyle(WidgetTheme.accentTeal.opacity(0.14)),
            in: Capsule()
        )
    }
}

// MARK: - Widget

struct WorkoutWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: WorkoutEntry

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                WorkoutMediumView(entry: entry)
            default:
                WorkoutSmallView(entry: entry)
            }
        }
        .widgetURL(WidgetDeepLink.logWorkout)
        .containerBackground(for: .widget) {
            ZStack {
                Color(.systemBackground)
                LinearGradient(
                    colors: [WidgetTheme.accentTeal.opacity(0.10), .clear],
                    startPoint: .topLeading,
                    endPoint: .center
                )
            }
        }
    }
}

struct WorkoutLogWidget: Widget {
    let kind = "WorkoutLogWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WorkoutTimelineProvider()) { entry in
            WorkoutWidgetView(entry: entry)
        }
        .configurationDisplayName("Log Workout")
        .description("Today's workout at a glance — clock in at the gym with one tap.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Previews

private extension WidgetSnapshot {
    static func workoutSample(
        label: String? = "Push Day",
        isWorkoutDay: Bool = true,
        logged: Bool = false,
        streak: Int = 4,
        signedIn: Bool = true
    ) -> WidgetSnapshot {
        var snapshot = WidgetSnapshot.empty(isSignedIn: signedIn)
        snapshot.isWorkoutDay = isWorkoutDay
        snapshot.todayWorkoutLabel = label
        snapshot.workoutLoggedToday = logged
        snapshot.workoutStreak = streak
        return snapshot
    }
}

#Preview("Workout — small", as: .systemSmall) {
    WorkoutLogWidget()
} timeline: {
    WorkoutEntry(date: .now, snapshot: .workoutSample())
    WorkoutEntry(date: .now, snapshot: .workoutSample(), gymStartedAt: .now.addingTimeInterval(-1520))
    WorkoutEntry(date: .now, snapshot: .workoutSample(logged: true, streak: 5))
    WorkoutEntry(date: .now, snapshot: .workoutSample(label: nil, isWorkoutDay: false, streak: 3))
    WorkoutEntry(date: .now, snapshot: .empty())
}

#Preview("Workout — medium", as: .systemMedium) {
    WorkoutLogWidget()
} timeline: {
    WorkoutEntry(date: .now, snapshot: .workoutSample())
    WorkoutEntry(date: .now, snapshot: .workoutSample(), gymStartedAt: .now.addingTimeInterval(-1520))
    WorkoutEntry(date: .now, snapshot: .workoutSample(logged: true, streak: 5))
    WorkoutEntry(date: .now, snapshot: .workoutSample(label: nil, isWorkoutDay: false, streak: 3))
    WorkoutEntry(date: .now, snapshot: .empty())
}
