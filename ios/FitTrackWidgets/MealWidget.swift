import SwiftUI
import WidgetKit

// Home-screen meal widget: today's calorie ring + macros, with one-tap
// deep links into meal logging. Mirrors the app's CalorieRing / MacroBar
// styling (DesignSystem/CalorieRing.swift) using WidgetTheme tokens.

// MARK: - Meal schedule

/// Local meal windows shared by Smart Stack relevance and the small-family
/// quick-log pill: breakfast 07–10, lunch 12–14, dinner 18–21, snack between.
private enum MealSchedule {
    static let windows: [(type: String, hours: Range<Int>)] = [
        ("breakfast", 7 ..< 10),
        ("lunch", 12 ..< 14),
        ("dinner", 18 ..< 21),
    ]

    /// Hours-of-day where relevance flips; the timeline emits an entry at each.
    static var boundaryHours: [Int] {
        windows.flatMap { [$0.hours.lowerBound, $0.hours.upperBound] }
    }

    /// Meal type to quick-log at `date`: the window it falls in, else snack.
    static func mealType(at date: Date, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        return windows.first { $0.hours.contains(hour) }?.type ?? "snack"
    }

    /// High inside a meal window so the Smart Stack rotates this widget on
    /// top around meals; low in between.
    static func relevance(at date: Date, calendar: Calendar = .current) -> TimelineEntryRelevance {
        let hour = calendar.component(.hour, from: date)
        let inWindow = windows.contains { $0.hours.contains(hour) }
        return TimelineEntryRelevance(score: inWindow ? 80 : 10)
    }
}

// MARK: - Timeline

struct MealEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let isPlaceholder: Bool
    var relevance: TimelineEntryRelevance? = nil

    static var sample: MealEntry {
        MealEntry(
            date: Date(),
            snapshot: WidgetSnapshot(
                dayId: WidgetStore.dayId(),
                updatedAt: Date(),
                isSignedIn: true,
                caloriesEaten: 1450, calorieTarget: 2200,
                proteinG: 82, proteinTargetG: 140,
                carbsG: 160, carbTargetG: 240,
                fatG: 48, fatTargetG: 70,
                mealsLoggedToday: 2, lastMealName: "Chicken salad",
                isWorkoutDay: true, todayWorkoutLabel: nil,
                workoutLoggedToday: false, workoutStreak: 4
            ),
            isPlaceholder: false
        )
    }

    static var overTarget: MealEntry {
        var entry = MealEntry.sample
        var snapshot = entry.snapshot
        snapshot.caloriesEaten = 2430
        snapshot.proteinG = 145
        snapshot.mealsLoggedToday = 4
        entry = MealEntry(date: entry.date, snapshot: snapshot, isPlaceholder: false)
        return entry
    }

    static var signedOut: MealEntry {
        MealEntry(date: Date(), snapshot: .empty(isSignedIn: false), isPlaceholder: false)
    }
}

struct MealTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> MealEntry {
        MealEntry(date: Date(), snapshot: MealEntry.sample.snapshot, isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (MealEntry) -> Void) {
        completion(context.isPreview ? .sample : currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MealEntry>) -> Void) {
        let now = Date()
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        let nextMidnight = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        )
        // One entry now plus one at each remaining meal-window boundary today,
        // scored so the Smart Stack surfaces this widget around meals. All
        // entries share one snapshot load — the app reloads the timeline on
        // every logged meal, and currentEntry re-zeroes stale days per entry.
        let snapshot = WidgetStore.load() ?? .empty()
        let boundaries = MealSchedule.boundaryHours
            .compactMap { calendar.date(byAdding: .hour, value: $0, to: startOfDay) }
            .filter { $0 > now && $0 < nextMidnight }
        let entries = ([now] + boundaries).sorted()
            .map { currentEntry(at: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(nextMidnight)))
    }

    private func currentEntry(at date: Date = Date(), snapshot: WidgetSnapshot? = nil) -> MealEntry {
        var snapshot = snapshot ?? WidgetStore.load() ?? .empty()
        if snapshot.isStale(relativeTo: date) {
            // New day: keep targets, zero the counters.
            snapshot.dayId = WidgetStore.dayId(for: date)
            snapshot.caloriesEaten = 0
            snapshot.proteinG = 0
            snapshot.carbsG = 0
            snapshot.fatG = 0
            snapshot.mealsLoggedToday = 0
            snapshot.lastMealName = nil
        }
        return MealEntry(
            date: date, snapshot: snapshot, isPlaceholder: false,
            relevance: MealSchedule.relevance(at: date)
        )
    }
}

// MARK: - Widget

struct MealLogWidget: Widget {
    let kind = "MealLogWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MealTimelineProvider()) { entry in
            MealWidgetView(entry: entry)
        }
        .configurationDisplayName("Log Meals")
        .description("Today's calories and macros, with one-tap meal logging.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Views

struct MealWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MealEntry

    var body: some View {
        Group {
            if !entry.snapshot.isSignedIn && !entry.isPlaceholder {
                MealSignedOutView()
            } else if family == .systemMedium {
                MealMediumView(snapshot: entry.snapshot)
            } else {
                let mealType = MealSchedule.mealType(at: entry.date)
                MealSmallView(snapshot: entry.snapshot, mealType: mealType)
                    .widgetURL(WidgetDeepLink.logMeal(type: mealType))
            }
        }
        .containerBackground(for: .widget) {
            ZStack {
                Color(.systemBackground)
                LinearGradient(
                    colors: [WidgetTheme.accentTeal.opacity(0.10), .clear],
                    startPoint: .topLeading, endPoint: .center
                )
            }
        }
    }
}

private struct MealSmallView: View {
    let snapshot: WidgetSnapshot
    /// Upcoming/current meal by hour; the whole widget deep-links to its log flow.
    let mealType: String

    var body: some View {
        VStack(spacing: 5) {
            MealCalorieRing(eaten: snapshot.caloriesEaten, target: snapshot.calorieTarget)
            HStack(spacing: 4) {
                Image(systemName: WidgetTheme.mealIcon(mealType))
                Text(mealType.capitalized)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(WidgetTheme.mealColor(mealType))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(WidgetTheme.mealColor(mealType).opacity(0.14)))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Log \(mealType)")
        }
    }
}

private struct MealMediumView: View {
    let snapshot: WidgetSnapshot
    private let mealTypes = ["breakfast", "lunch", "dinner", "snack"]

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 8) {
                MealCalorieRing(eaten: snapshot.caloriesEaten, target: snapshot.calorieTarget)
                    .frame(maxHeight: .infinity)
                VStack(spacing: 5) {
                    MealMacroBar(label: "P", current: snapshot.proteinG, target: snapshot.proteinTargetG, color: WidgetTheme.protein)
                    MealMacroBar(label: "C", current: snapshot.carbsG, target: snapshot.carbTargetG, color: WidgetTheme.carbs)
                    MealMacroBar(label: "F", current: snapshot.fatG, target: snapshot.fatTargetG, color: WidgetTheme.fat)
                }
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    mealTile(mealTypes[0])
                    mealTile(mealTypes[1])
                }
                HStack(spacing: 8) {
                    mealTile(mealTypes[2])
                    mealTile(mealTypes[3])
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func mealTile(_ type: String) -> some View {
        Link(destination: WidgetDeepLink.logMeal(type: type)) {
            HStack(spacing: 6) {
                Image(systemName: WidgetTheme.mealIcon(type))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WidgetTheme.mealColor(type))
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(WidgetTheme.mealColor(type).opacity(0.14))
                    )
                Text(type.capitalized)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
            )
        }
        .accessibilityLabel("Log \(type)")
    }
}

private struct MealSignedOutView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "fork.knife.circle.fill")
                .font(.title2)
                .foregroundStyle(WidgetTheme.accentTeal)
            Text("Open FitTrack to sign in")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

/// Compact widget mirror of the app's CalorieRing: 0.088 line ratio, round
/// caps, accent gradient that flips to the protein red when over target.
private struct MealCalorieRing: View {
    let eaten: Int
    let target: Int

    private var progress: Double {
        guard target > 0 else { return 0 }
        return min(Double(eaten) / Double(target), 1.0)
    }
    private var over: Bool { target > 0 && eaten > target }
    private var heroNumber: Int { over ? eaten - target : max(target - eaten, 0) }
    private var ringStyle: AnyShapeStyle {
        over ? AnyShapeStyle(WidgetTheme.protein.gradient) : AnyShapeStyle(WidgetTheme.accentGradient)
    }

    var body: some View {
        GeometryReader { geo in
            let diameter = min(geo.size.width, geo.size.height)
            let lineWidth = diameter * 0.088
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(ringStyle, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                center(diameter: diameter)
            }
            .frame(width: diameter, height: diameter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Calories")
        .accessibilityValue(
            target > 0
                ? "\(eaten) of \(target) kilocalories eaten, \(over ? "\(eaten - target) over target" : "\(heroNumber) remaining")"
                : "\(eaten) kilocalories eaten"
        )
    }

    @ViewBuilder
    private func center(diameter: CGFloat) -> some View {
        VStack(spacing: 0) {
            if target > 0 {
                Text(heroNumber, format: .number)
                    .font(.system(size: diameter * 0.23, weight: .bold, design: .rounded))
                    .foregroundStyle(over ? WidgetTheme.protein : Color.primary)
                    .contentTransition(.numericText(value: Double(heroNumber)))
                Text(over ? "over" : "left")
                    .font(.system(size: diameter * 0.095, weight: .medium))
                    .foregroundStyle(over ? WidgetTheme.protein : Color.secondary)
                Text("of \(target.formatted())")
                    .font(.system(size: diameter * 0.08))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 1)
            } else {
                Text(eaten, format: .number)
                    .font(.system(size: diameter * 0.23, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(value: Double(eaten)))
                Text("kcal eaten")
                    .font(.system(size: diameter * 0.09, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(.horizontal, diameter * 0.16)
    }
}

/// Thin widget mirror of the app's MacroBar capsule style.
private struct MealMacroBar: View {
    let label: String
    let current: Double
    let target: Double
    let color: Color

    private var progress: Double {
        guard target > 0 else { return 0 }
        return min(current / target, 1.0)
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 10, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.18))
                    Capsule().fill(color.gradient)
                        .frame(width: max(0, geo.size.width * progress))
                }
            }
            .frame(height: 5)
            Text("\(Int(current.rounded()))/\(Int(target.rounded()))")
                .font(.system(size: 9, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(value: current))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(Int(current.rounded())) of \(Int(target.rounded())) grams")
    }
}

// MARK: - Previews

#Preview(as: .systemSmall) {
    MealLogWidget()
} timeline: {
    MealEntry.sample
    MealEntry.overTarget
    MealEntry.signedOut
}

#Preview(as: .systemMedium) {
    MealLogWidget()
} timeline: {
    MealEntry.sample
    MealEntry.overTarget
    MealEntry.signedOut
}
