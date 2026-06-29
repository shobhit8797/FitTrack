import SwiftUI

// Today / Dashboard (spec §7.1). Calorie ring hero, macro bars, today's meals,
// steps + active energy from Health, swipe between days.
struct TodayView: View {
    @Environment(Repository.self) private var repo
    @Environment(HealthKitService.self) private var health
    @Environment(FunctionsClient.self) private var functions
    @State private var model = TodayViewModel()
    @State private var selectedDate = Date()
    @State private var planStatus: String?
    @State private var planError: String?
    @State private var retrying = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.l) {
                    dayNav

                    planBanner

                    if let target = model.calorieTarget {
                        CalorieRing(consumed: model.totalCalories, target: target)
                            .padding(.top, Theme.Spacing.m)

                        Card {
                            VStack(spacing: Theme.Spacing.m) {
                                MacroBar(name: "Protein", current: model.totalProtein,
                                         target: model.proteinTarget, color: Theme.protein)
                                MacroBar(name: "Carbs", current: model.totalCarbs,
                                         target: model.carbTarget, color: Theme.carbs)
                                MacroBar(name: "Fat", current: model.totalFat,
                                         target: model.fatTarget, color: Theme.fat)
                            }
                        }
                    } else if model.loading {
                        targetsSkeleton
                    } else {
                        EmptyStateView(systemImage: "target", title: "No targets yet",
                                       message: "Finish setting up your profile to see your daily calorie and macro goals.")
                    }

                    healthCard

                    mealsSection
                }
                .padding(Theme.Spacing.m)
                // Swipe left/right anywhere on the dashboard to change day (spec §7.1).
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 40)
                        .onEnded { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            if value.translation.width > 0 { shift(-1) }
                            else if !Calendar.current.isDateInToday(selectedDate) { shift(1) }
                        }
                )
            }
            .refreshable { await model.load(repo: repo, health: health, date: selectedDate) }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(navTitle)
            .task(id: selectedDate) { await model.load(repo: repo, health: health, date: selectedDate) }
            // Live plan-generation status, so the home banner updates the moment
            // the async generator finishes (or fails) — never blocks this screen.
            .task {
                do {
                    for try await profile in repo.profileStream() {
                        planStatus = profile?.workoutPlanStatus
                        planError = profile?.workoutPlanError
                    }
                } catch {}
            }
            // Live HealthKit refresh (spec §7.5): reload when an observer fires.
            .onChange(of: health.lastUpdate) {
                Task { await model.load(repo: repo, health: health, date: selectedDate) }
            }
        }
    }

    /// Non-blocking notice about async workout-plan generation (spec §11.1).
    /// Hidden once the plan is ready (or for legacy profiles with no status).
    @ViewBuilder private var planBanner: some View {
        if planStatus == "generating" {
            Card {
                HStack(spacing: Theme.Spacing.m) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Building your workout plan…").fontWeight(.medium)
                        Text("We'll add it to the Workout tab when it's ready.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        } else if planStatus == "failed" {
            Card {
                HStack(spacing: Theme.Spacing.m) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.carbs)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Plan generation failed").fontWeight(.medium)
                        Text("Your targets are saved — tap to try the plan again.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(retrying ? "…" : "Retry") { Task { await retryPlan() } }
                        .buttonStyle(.bordered).tint(Theme.accentTeal)
                        .disabled(retrying)
                }
            }
        }
    }

    private func retryPlan() async {
        guard !retrying else { return }
        retrying = true
        defer { retrying = false }
        planStatus = "generating"
        do { try await functions.generateWorkoutPlan() } catch {
            planStatus = "failed"
            planError = error.localizedDescription
        }
    }

    private var navTitle: String {
        if Calendar.current.isDateInToday(selectedDate) { return "Today" }
        if Calendar.current.isDateInYesterday(selectedDate) { return "Yesterday" }
        return selectedDate.formatted(.dateTime.weekday(.wide))
    }

    private var dayNav: some View {
        let isToday = Calendar.current.isDateInToday(selectedDate)
        return HStack {
            Button { shift(-1) } label: {
                Image(systemName: "chevron.left").font(.body.weight(.semibold))
                    .frame(width: Theme.minTapTarget, height: Theme.minTapTarget)
            }
            .accessibilityLabel("Previous day")
            Spacer()
            Text(selectedDate.formatted(date: .complete, time: .omitted))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            Spacer()
            Button { shift(1) } label: {
                Image(systemName: "chevron.right").font(.body.weight(.semibold))
                    .frame(width: Theme.minTapTarget, height: Theme.minTapTarget)
            }
            .accessibilityLabel("Next day")
            .disabled(isToday)
            .opacity(isToday ? 0.3 : 1)
        }
    }

    private var targetsSkeleton: some View {
        VStack(spacing: Theme.Spacing.l) {
            Circle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 210, height: 210)
                .padding(.top, Theme.Spacing.m)
            Card {
                VStack(spacing: Theme.Spacing.m) {
                    ForEach(0..<3, id: \.self) { _ in SkeletonBar(height: 18) }
                }
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityLabel("Loading your targets")
    }

    private var healthCard: some View {
        Card {
            HStack {
                metric("figure.walk", "\(model.steps ?? 0)", "steps")
                Divider().frame(height: 36)
                metric("flame.fill", "\(model.activeEnergy ?? 0)", "active kcal")
                Divider().frame(height: 36)
                metric("timer", "\(model.exerciseMinutes ?? 0)", "min")
            }
        }
    }

    private func metric(_ icon: String, _ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon).foregroundStyle(Theme.accentTeal)
            Text(value).font(.headline)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var mealsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ForEach(MealType.allCases) { type in
                let meals = model.meals.filter { $0.mealType == type }
                if !meals.isEmpty {
                    let subtotal = meals.reduce(0) { $0 + $1.calories }
                    SectionHeader(type.label) {
                        Label("\(subtotal) kcal", systemImage: type.icon)
                            .labelStyle(.titleAndIcon)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.accentTeal)
                    }
                    .padding(.top, Theme.Spacing.s)
                    ForEach(meals) { meal in mealRow(meal) }
                }
            }
            if model.meals.isEmpty {
                EmptyStateView(systemImage: "fork.knife", title: "No meals yet",
                               message: "Tap ➕ in the tab bar to log your first meal — by photo, barcode, label, or just describe it.")
            }
        }
        .animation(.snappy, value: model.meals)
    }

    private func mealRow(_ meal: MealEntry) -> some View {
        Card {
            HStack(spacing: Theme.Spacing.m) {
                Image(systemName: meal.mealType.icon)
                    .font(.body)
                    .foregroundStyle(Theme.accentTeal)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meal.name).fontWeight(.medium)
                    if let s = meal.servingDescription {
                        Text(s).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("\(meal.calories)")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                + Text(" kcal").font(.caption).foregroundColor(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func shift(_ days: Int) {
        guard let next = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) else { return }
        Haptics.selection()
        withAnimation(.snappy) { selectedDate = next }
    }
}

@Observable
final class TodayViewModel {
    var meals: [MealEntry] = []
    var calorieTarget: Int?
    var proteinTarget = 0
    var carbTarget = 0
    var fatTarget = 0
    var steps: Int?
    var activeEnergy: Int?
    var exerciseMinutes: Int?
    var loading = true

    var totalCalories: Int { meals.reduce(0) { $0 + $1.calories } }
    var totalProtein: Double { meals.reduce(0) { $0 + $1.proteinG } }
    var totalCarbs: Double { meals.reduce(0) { $0 + $1.carbsG } }
    var totalFat: Double { meals.reduce(0) { $0 + $1.fatG } }

    @MainActor
    func load(repo: Repository, health: HealthKitService, date: Date) async {
        if let profile = try? await repo.fetchProfile() {
            calorieTarget = profile.calorieTarget
            proteinTarget = profile.proteinTargetG ?? 0
            carbTarget = profile.carbTargetG ?? 0
            fatTarget = profile.fatTargetG ?? 0
        }
        // Targets resolved — drop the skeleton before the (endless) meals stream.
        loading = false
        let metrics = await health.dailyMetrics(for: date)
        steps = metrics.steps
        activeEnergy = metrics.activeEnergyKcal
        exerciseMinutes = metrics.exerciseMinutes

        do {
            for try await meals in repo.mealsStream(for: date) {
                self.meals = meals
            }
        } catch { /* offline cache still serves last value */ }
    }
}
