import Charts
import SwiftUI

// Progress & charts (spec §7.6): weight trend + 7-day MA, daily calories vs
// target, macro adherence over time, workout-adherence heatmap, and per-lift
// progression. One range selector drives every series. Color-blind-safe palette
// (color is always paired with shape/symbol or a label), VoiceOver labels on
// every chart, and EmptyStateView whenever a series has no data.
struct ProgressDashboardView: View {
    @Environment(Repository.self) private var repo
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var weights: [WeightEntry] = []
    @State private var dayLogs: [DayLog] = []
    @State private var sessions: [WorkoutSession] = []
    @State private var profile: UserProfile?
    @State private var plan: WorkoutPlan?
    @State private var range: ChartRange = .month
    @State private var selectedLift: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    Picker("Range", selection: $range) {
                        ForEach(ChartRange.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: range) { Haptics.selection() }

                    weightCard
                    caloriesCard
                    macrosCard
                    workoutHeatmapCard
                    liftProgressionCard
                }
                .padding(Theme.Spacing.m)
            }
            .background(ScreenBackground())
            .navigationTitle("Progress")
            .task {
                do { for try await w in repo.weightStream() { weights = w } } catch {}
            }
            .task {
                do { for try await logs in repo.dayLogsStream() { dayLogs = logs } } catch {}
            }
            .task {
                do { for try await s in repo.sessionsStream() { sessions = s } } catch {}
            }
            .task {
                profile = try? await repo.fetchProfile()
                plan = try? await repo.fetchCurrentPlan()
            }
        }
    }

    // MARK: Weight

    private var weightCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                SectionHeader("Weight")
                if filteredWeights.isEmpty {
                    EmptyStateView(systemImage: "scalemass", title: "No weight data",
                                   message: "Log your weight to see trends.")
                } else {
                    weightChart
                }
            }
        }
    }

    private var filteredWeights: [WeightEntry] {
        guard let cutoff = range.cutoff else { return weights }
        return weights.filter { $0.date >= cutoff }
    }

    private var weightChart: some View {
        Chart {
            ForEach(filteredWeights) { entry in
                LineMark(x: .value("Date", entry.date), y: .value("kg", entry.weightKg))
                    .foregroundStyle(Theme.accentTeal)
                    .symbol(.circle) // shape + color for color-blind safety
            }
            ForEach(movingAverage(), id: \.0) { date, avg in
                LineMark(x: .value("Date", date), y: .value("7-day avg", avg))
                    .foregroundStyle(Theme.fat)
                    .lineStyle(StrokeStyle(dash: [4, 3]))
            }
        }
        .frame(height: 220)
        .chartYScale(domain: .automatic(includesZero: false))
        .accessibilityLabel("Weight trend with 7-day moving average")
    }

    private func movingAverage(window: Int = 7) -> [(Date, Double)] {
        let sorted = filteredWeights.sorted { $0.date < $1.date }
        guard sorted.count >= window else { return [] }
        var result: [(Date, Double)] = []
        for i in (window - 1)..<sorted.count {
            let slice = sorted[(i - window + 1)...i]
            let avg = slice.reduce(0) { $0 + $1.weightKg } / Double(window)
            result.append((sorted[i].date, avg))
        }
        return result
    }

    // MARK: Daily calories vs target

    private var filteredLogs: [DayLog] {
        let logs: [DayLog]
        if let cutoff = range.cutoff {
            logs = dayLogs.filter { $0.date >= cutoff }
        } else {
            logs = dayLogs
        }
        return logs.sorted { $0.date < $1.date }
    }

    private var caloriesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                SectionHeader("Calories vs target")
                if filteredLogs.isEmpty {
                    EmptyStateView(systemImage: "flame", title: "No calorie data",
                                   message: "Log meals to see daily calories against your target.")
                } else {
                    caloriesChart
                }
            }
        }
    }

    private var caloriesChart: some View {
        Chart {
            ForEach(filteredLogs, id: \.date) { log in
                BarMark(
                    x: .value("Date", log.date, unit: .day),
                    y: .value("Calories", log.totalCalories)
                )
                .foregroundStyle(Theme.accentTeal)
            }
            ForEach(weeklyAverage(filteredLogs, value: { Double($0.totalCalories) }), id: \.0) { week, avg in
                LineMark(x: .value("Week", week, unit: .day), y: .value("Weekly avg", avg))
                    .foregroundStyle(Theme.carbs)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .symbol(.diamond) // shape + color for color-blind safety
            }
            if let target = profile?.calorieTarget {
                RuleMark(y: .value("Target", target))
                    .foregroundStyle(Theme.fat)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("Target \(target) kcal")
                            .font(.caption2)
                            .foregroundStyle(Theme.fat)
                    }
            }
        }
        .frame(height: 220)
        .accessibilityLabel("Daily calories as bars, weekly average line, and target line at \(profile?.calorieTarget.map { "\($0) kilocalories" } ?? "no target set")")
    }

    // MARK: Macro adherence over time

    private var macrosCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                SectionHeader("Macro adherence")
                Text("Protein highlighted; carbs and fat shown for context.")
                    .font(.caption).foregroundStyle(.secondary)
                if filteredLogs.isEmpty {
                    EmptyStateView(systemImage: "chart.line.uptrend.xyaxis", title: "No macro data",
                                   message: "Log meals to track protein, carbs, and fat vs your targets.")
                } else {
                    macrosChart
                    macroLegend
                }
            }
        }
    }

    /// One series per macro. Protein is emphasized (thicker line + filled symbol)
    /// per the task; each macro carries a distinct symbol so it reads without color.
    private var macrosChart: some View {
        Chart {
            ForEach(filteredLogs, id: \.date) { log in
                LineMark(x: .value("Date", log.date), y: .value("g", log.totalProteinG),
                         series: .value("Macro", "Protein"))
                    .foregroundStyle(Theme.protein)
                    .lineStyle(StrokeStyle(lineWidth: 3))
                    .symbol(.circle)
            }
            ForEach(filteredLogs, id: \.date) { log in
                LineMark(x: .value("Date", log.date), y: .value("g", log.totalCarbsG),
                         series: .value("Macro", "Carbs"))
                    .foregroundStyle(Theme.carbs)
                    .symbol(.square)
            }
            ForEach(filteredLogs, id: \.date) { log in
                LineMark(x: .value("Date", log.date), y: .value("g", log.totalFatG),
                         series: .value("Macro", "Fat"))
                    .foregroundStyle(Theme.fat)
                    .symbol(.triangle)
            }
            if let p = profile?.proteinTargetG {
                RuleMark(y: .value("Protein target", p))
                    .foregroundStyle(Theme.protein.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
            }
            if let c = profile?.carbTargetG {
                RuleMark(y: .value("Carb target", c))
                    .foregroundStyle(Theme.carbs.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
            }
            if let f = profile?.fatTargetG {
                RuleMark(y: .value("Fat target", f))
                    .foregroundStyle(Theme.fat.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
            }
        }
        .frame(height: 220)
        .accessibilityLabel("Daily macros in grams: protein highlighted with circles, carbs with squares, fat with triangles, each against its dashed target line")
    }

    private var macroLegend: some View {
        HStack(spacing: Theme.Spacing.m) {
            legendItem(symbol: "circle.fill", color: Theme.protein,
                       label: "Protein", target: profile?.proteinTargetG)
            legendItem(symbol: "square.fill", color: Theme.carbs,
                       label: "Carbs", target: profile?.carbTargetG)
            legendItem(symbol: "triangle.fill", color: Theme.fat,
                       label: "Fat", target: profile?.fatTargetG)
        }
        .font(.caption)
    }

    private func legendItem(symbol: String, color: Color, label: String, target: Int?) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: symbol).foregroundStyle(color)
            if let target {
                Text("\(label) (\(target)g)")
            } else {
                Text(label)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Workout-adherence heatmap

    private var filteredSessions: [WorkoutSession] {
        guard let cutoff = range.cutoff else { return sessions }
        return sessions.filter { $0.date >= cutoff }
    }

    private var workoutHeatmapCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                SectionHeader("Workout adherence")
                if filteredSessions.isEmpty {
                    EmptyStateView(systemImage: "calendar", title: "No workouts logged",
                                   message: "Log a session to build your training calendar.")
                } else {
                    HStack(spacing: Theme.Spacing.l) {
                        statTile(value: "\(currentStreak)", label: "Day streak")
                        statTile(value: "\(adherencePercent)%", label: "Plan adherence")
                    }
                    heatmapGrid
                    Text("Filled = trained that day. Border = scheduled by your plan.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(value)
                .font(.title2.bold())
                .foregroundStyle(Theme.accentTeal)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .snappy, value: value)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    /// Calendar grid (weeks as columns, weekday rows Sun→Sat) over the selected
    /// range. Trained days are filled; scheduled-but-not-trained days get a border
    /// so adherence reads without relying on color alone.
    private var heatmapGrid: some View {
        let days = heatmapDays
        let trained = trainedDaySet
        let scheduled = Set(plan?.scheduledWeekdays ?? [])
        let cal = Calendar.current
        let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 3) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: 3) {
                        ForEach(week, id: \.self) { day in
                            let isTrained = trained.contains(cal.startOfDay(for: day))
                            let weekday = cal.component(.weekday, from: day) - 1 // 0=Sun
                            let isScheduled = scheduled.contains(weekday)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(isTrained ? Theme.accentTeal : Color.gray.opacity(0.15))
                                .frame(width: 14, height: 14)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .strokeBorder(isScheduled ? Theme.fat : .clear, lineWidth: 1.5)
                                )
                        }
                    }
                }
            }
        }
        .frame(height: 7 * 17)
        .accessibilityLabel("Training calendar heatmap. Current streak \(currentStreak) days, plan adherence \(adherencePercent) percent.")
    }

    /// All days from the range cutoff (or first session) to today, oldest→newest,
    /// padded so the first column starts on a Sunday.
    private var heatmapDays: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start: Date
        if let cutoff = range.cutoff {
            start = cal.startOfDay(for: cutoff)
        } else if let earliest = sessions.map(\.date).min() {
            start = cal.startOfDay(for: earliest)
        } else {
            start = today
        }
        // Pad back to the Sunday on/before start so weekday rows line up.
        let weekdayOffset = cal.component(.weekday, from: start) - 1
        guard let gridStart = cal.date(byAdding: .day, value: -weekdayOffset, to: start) else { return [] }
        var days: [Date] = []
        var cursor = gridStart
        while cursor <= today {
            days.append(cursor)
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    private var trainedDaySet: Set<Date> {
        let cal = Calendar.current
        return Set(filteredSessions.map { cal.startOfDay(for: $0.date) })
    }

    /// Consecutive days (counting back from today, or yesterday if today is rest)
    /// with a logged session.
    private var currentStreak: Int {
        let cal = Calendar.current
        let trained = Set(sessions.map { cal.startOfDay(for: $0.date) })
        var streak = 0
        var day = cal.startOfDay(for: Date())
        // Allow today to be a rest day without breaking the streak.
        if !trained.contains(day) {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        while trained.contains(day) {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return streak
    }

    /// Trained scheduled-weekday slots ÷ total scheduled slots over the range.
    private var adherencePercent: Int {
        let scheduled = Set(plan?.scheduledWeekdays ?? [])
        guard !scheduled.isEmpty else { return 0 }
        let cal = Calendar.current
        let scheduledDays = heatmapDays.filter { day in
            day <= cal.startOfDay(for: Date()) &&
            scheduled.contains(cal.component(.weekday, from: day) - 1)
        }
        guard !scheduledDays.isEmpty else { return 0 }
        let trained = trainedDaySet
        let hit = scheduledDays.filter { trained.contains(cal.startOfDay(for: $0)) }.count
        return Int((Double(hit) / Double(scheduledDays.count) * 100).rounded())
    }

    // MARK: Per-lift progression

    private var liftNames: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for session in filteredSessions {
            for set in session.loggedSets where !seen.contains(set.exerciseName) {
                seen.insert(set.exerciseName)
                ordered.append(set.exerciseName)
            }
        }
        return ordered.sorted()
    }

    /// Max weight lifted for the chosen exercise per session, oldest→newest.
    private func liftProgression(for name: String) -> [(date: Date, maxWeight: Double)] {
        filteredSessions
            .compactMap { session -> (Date, Double)? in
                let weights = session.loggedSets.filter { $0.exerciseName == name }.map(\.weightKg)
                guard let best = weights.max() else { return nil }
                return (session.date, best)
            }
            .sorted { $0.0 < $1.0 }
            .map { (date: $0.0, maxWeight: $0.1) }
    }

    private var liftProgressionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                SectionHeader("Per-lift progression")
                if liftNames.isEmpty {
                    EmptyStateView(systemImage: "dumbbell", title: "No lifts logged",
                                   message: "Log sets in a workout to track strength over time.")
                } else {
                    Picker("Exercise", selection: liftSelectionBinding) {
                        ForEach(liftNames, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: resolvedLift) { Haptics.selection() }

                    let series = liftProgression(for: resolvedLift)
                    if series.isEmpty {
                        EmptyStateView(systemImage: "dumbbell", title: "No data in range",
                                       message: "No \(resolvedLift) sets in the selected range.")
                    } else {
                        liftChart(series)
                    }
                }
            }
        }
    }

    /// Falls back to the first available lift when nothing is selected yet.
    private var resolvedLift: String {
        selectedLift ?? liftNames.first ?? ""
    }

    private var liftSelectionBinding: Binding<String?> {
        Binding(get: { resolvedLift.isEmpty ? nil : resolvedLift },
                set: { selectedLift = $0 })
    }

    private func liftChart(_ series: [(date: Date, maxWeight: Double)]) -> some View {
        Chart {
            ForEach(series, id: \.date) { point in
                LineMark(x: .value("Date", point.date), y: .value("Max kg", point.maxWeight))
                    .foregroundStyle(Theme.accentTeal)
                    .symbol(.circle) // shape + color for color-blind safety
                PointMark(x: .value("Date", point.date), y: .value("Max kg", point.maxWeight))
                    .foregroundStyle(Theme.accentTeal)
            }
        }
        .frame(height: 220)
        .chartYScale(domain: .automatic(includesZero: false))
        .accessibilityLabel("Top-set weight over time for \(resolvedLift)")
    }

    // MARK: Helpers

    /// Buckets values into ISO weeks and averages each bucket; the point is keyed
    /// to the start of that week. Shared by the calories weekly-average overlay.
    private func weeklyAverage(_ logs: [DayLog], value: (DayLog) -> Double) -> [(Date, Double)] {
        let cal = Calendar.current
        var buckets: [Date: [Double]] = [:]
        for log in logs {
            let week = cal.dateInterval(of: .weekOfYear, for: log.date)?.start ?? cal.startOfDay(for: log.date)
            buckets[week, default: []].append(value(log))
        }
        return buckets
            .map { ($0.key, $0.value.reduce(0, +) / Double($0.value.count)) }
            .sorted { $0.0 < $1.0 }
    }
}

enum ChartRange: String, CaseIterable, Identifiable {
    case week, month, quarter, year, all
    var id: String { rawValue }
    var label: String {
        switch self {
        case .week: return "1W"; case .month: return "1M"; case .quarter: return "3M"
        case .year: return "1Y"; case .all: return "All"
        }
    }
    var cutoff: Date? {
        let cal = Calendar.current
        switch self {
        case .week: return cal.date(byAdding: .day, value: -7, to: Date())
        case .month: return cal.date(byAdding: .month, value: -1, to: Date())
        case .quarter: return cal.date(byAdding: .month, value: -3, to: Date())
        case .year: return cal.date(byAdding: .year, value: -1, to: Date())
        case .all: return nil
        }
    }
}
