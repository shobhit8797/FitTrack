import SwiftUI

// Today / Dashboard (spec §7.1). Calorie ring hero, macro bars, today's meals,
// steps + active energy from Health, swipe between days.
struct TodayView: View {
    @Environment(Repository.self) private var repo
    @Environment(HealthKitService.self) private var health
    @State private var model = TodayViewModel()
    @State private var selectedDate = Date()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.l) {
                    dayNav

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
                    } else {
                        ProgressView("Loading your targets…").padding()
                    }

                    healthCard

                    mealsSection
                }
                .padding(Theme.Spacing.m)
            }
            .navigationTitle("Today")
            .task(id: selectedDate) { await model.load(repo: repo, health: health, date: selectedDate) }
            // Live HealthKit refresh (spec §7.5): reload when an observer fires.
            .onChange(of: health.lastUpdate) {
                Task { await model.load(repo: repo, health: health, date: selectedDate) }
            }
        }
    }

    private var dayNav: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(selectedDate.formatted(date: .abbreviated, time: .omitted)).font(.headline)
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .disabled(Calendar.current.isDateInToday(selectedDate))
        }
        .padding(.horizontal)
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
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            ForEach(MealType.allCases) { type in
                let meals = model.meals.filter { $0.mealType == type }
                if !meals.isEmpty {
                    Text(type.label).font(.headline).padding(.top, Theme.Spacing.s)
                    ForEach(meals) { meal in
                        Card {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(meal.name).fontWeight(.medium)
                                    if let s = meal.servingDescription {
                                        Text(s).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text("\(meal.calories) kcal").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if model.meals.isEmpty {
                EmptyStateView(systemImage: "fork.knife", title: "No meals yet",
                               message: "Log your first meal from the Log tab.")
            }
        }
    }

    private func shift(_ days: Int) {
        selectedDate = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) ?? selectedDate
    }
}

@Observable
final class TodayViewModel {
    var meals: [MealEntry] = []
    var calorieTarget: Int?
    var proteinTarget = 0, carbTarget = 0, fatTarget = 0
    var steps: Int?, activeEnergy: Int?, exerciseMinutes: Int?

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
