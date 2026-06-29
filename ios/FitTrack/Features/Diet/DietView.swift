import SwiftUI

// Diet (the Nutrition Architect Lyzr agent's plan). Mirrors WorkoutView: streams
// the current diet plan + its generation status, renders meals with per-meal and
// daily macro totals, plus hydration, grocery list, and notes. Generation is
// requested from Settings (or the empty-state button here).
struct DietView: View {
    @Environment(Repository.self) private var repo
    @Environment(FunctionsClient.self) private var functions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var plan: DietPlan?
    @State private var planStatus: String?
    @State private var planError: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Group {
                if let plan {
                    planList(plan)
                        .navigationTitle(plan.planName)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else if planStatus == "generating" {
                    EmptyStateView(systemImage: "sparkles", title: "Building your meal plan…",
                                   message: "Your nutrition coach is putting together a plan around your targets and preferences. This usually takes a few seconds.")
                        .navigationTitle("Diet")
                } else if planStatus == "failed" {
                    EmptyStateView(
                        systemImage: "exclamationmark.triangle",
                        title: "Couldn't build your meal plan",
                        message: planError ?? "Something went wrong generating your plan.",
                        actionTitle: working ? "Retrying…" : "Try again",
                        action: { Task { await generate() } }
                    )
                    .navigationTitle("Diet")
                } else {
                    EmptyStateView(
                        systemImage: "fork.knife", title: "No meal plan yet",
                        message: "Generate a personalized diet plan that hits your calorie and macro targets.",
                        actionTitle: working ? "Generating…" : "Generate plan",
                        action: { Task { await generate() } }
                    )
                    .navigationTitle("Diet")
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.85), value: plan != nil)
            .task {
                async let planTask: Void = {
                    do { for try await p in repo.dietPlanStream() { plan = p } } catch {}
                }()
                async let statusTask: Void = {
                    do {
                        for try await profile in repo.profileStream() {
                            planStatus = profile?.dietPlanStatus
                            planError = profile?.dietPlanError
                        }
                    } catch {}
                }()
                _ = await (planTask, statusTask)
            }
        }
    }

    @ViewBuilder private func planList(_ plan: DietPlan) -> some View {
        List {
            // Hero: the plan's daily macro headline.
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    if !plan.summary.isEmpty {
                        Text(plan.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: Theme.Spacing.sm) {
                        macroStat(plan.dailyCalories, "Calories", unit: "kcal", color: Theme.accentTeal)
                        statDivider
                        macroStat(plan.proteinG, "Protein", unit: "g", color: Theme.protein)
                        statDivider
                        macroStat(plan.carbsG, "Carbs", unit: "g", color: Theme.carbs)
                        statDivider
                        macroStat(plan.fatG, "Fat", unit: "g", color: Theme.fat)
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Daily target")
                .accessibilityValue("\(plan.dailyCalories) calories, \(plan.proteinG) grams protein, \(plan.carbsG) grams carbs, \(plan.fatG) grams fat")
            }

            ForEach(plan.meals.sorted { $0.order < $1.order }) { meal in
                Section {
                    ForEach(meal.items) { item in
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(item.name)
                                    .font(.body.weight(.medium))
                                Spacer(minLength: Theme.Spacing.s)
                                Text("\(item.calories) kcal")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            if !item.servingDescription.isEmpty {
                                Text(item.servingDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text("P \(Int(item.proteinG))g · C \(Int(item.carbsG))g · F \(Int(item.fatG))g")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(item.name)
                        .accessibilityValue("\(item.servingDescription.isEmpty ? "" : item.servingDescription + ", ")\(item.calories) calories, \(Int(item.proteinG)) grams protein, \(Int(item.carbsG)) grams carbs, \(Int(item.fatG)) grams fat")
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                        Image(systemName: mealIcon(meal.mealLabel))
                            .font(.footnote)
                            .foregroundStyle(Theme.accentTeal)
                        Text(meal.mealLabel)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .textCase(nil)
                        Spacer(minLength: Theme.Spacing.s)
                        Text("\(meal.calories) kcal · \(Int(meal.proteinG))g P")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .textCase(nil)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(meal.mealLabel)
                    .accessibilityValue("\(meal.calories) calories, \(Int(meal.proteinG)) grams protein")
                }
            }

            if !plan.hydrationNote.isEmpty {
                Section {
                    Label {
                        Text(plan.hydrationNote).font(.subheadline)
                    } icon: {
                        Image(systemName: "drop.fill").foregroundStyle(Theme.accentTeal)
                    }
                } header: { sectionLabel("Hydration", icon: "drop.fill") }
            }
            if !plan.groceryList.isEmpty {
                Section {
                    ForEach(plan.groceryList, id: \.self) { item in
                        Label {
                            Text(item)
                        } icon: {
                            Image(systemName: "cart.fill").foregroundStyle(Theme.accentTeal)
                        }
                    }
                } header: { sectionLabel("Grocery list", icon: "cart.fill") }
            }
            if !plan.notes.isEmpty {
                Section {
                    Text(plan.notes).font(.caption).foregroundStyle(.secondary)
                } header: { sectionLabel("Notes", icon: "note.text") }
            }
            Section {
                Button {
                    Haptics.tap()
                    Task { await generate() }
                } label: {
                    Label(working ? "Regenerating…" : "Regenerate plan",
                          systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .tint(Theme.accentTeal)
                .disabled(working)
            }
        }
    }

    /// A single bold, color-coded stat in the hero row (value + caption label).
    private func macroStat(_ value: Int, _ label: String, unit: String, color: Color) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(value)")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(color)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(value)))
                Text(unit)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color.opacity(0.7))
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .snappy, value: value)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 0.5, height: 28)
    }

    /// Accent-tinted header label for hydration / grocery / notes sections.
    private func sectionLabel(_ title: String, icon: String) -> some View {
        Label {
            Text(title).textCase(nil)
        } icon: {
            Image(systemName: icon).foregroundStyle(Theme.accentTeal)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)
    }

    /// Best-effort icon for a meal from its free-text label (model has no MealType here).
    private func mealIcon(_ label: String) -> String {
        let l = label.lowercased()
        if l.contains("break") { return MealType.breakfast.icon }
        if l.contains("lunch") { return MealType.lunch.icon }
        if l.contains("dinner") || l.contains("supper") { return MealType.dinner.icon }
        if l.contains("snack") { return MealType.snack.icon }
        return "fork.knife"
    }

    private func generate() async {
        guard !working else { return }
        working = true
        defer { working = false }
        planStatus = "generating"
        do { try await functions.generateDietPlan() } catch {
            planStatus = "failed"
            planError = error.localizedDescription
        }
    }
}
