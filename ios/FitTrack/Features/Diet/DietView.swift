import SwiftUI

// Diet tab. Streams the current diet plan + its generation status. A plan is
// either a single-day plan (the Lyzr Nutrition Architect) or a 7-day plan built
// through the Diet coach chat — the latter adds a day picker up top. Both render
// meals with per-meal and daily macro totals, plus hydration, grocery, and notes.
struct DietView: View {
    @Environment(Repository.self) private var repo
    @Environment(FunctionsClient.self) private var functions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var plan: DietPlan?
    @State private var planStatus: String?
    @State private var planError: String?
    @State private var working = false
    @State private var showChat = false
    // For 7-day plans: which day's meals are on screen (driven by the bubbles).
    @State private var selectedDayID: String?
    @Namespace private var bubbleNS

    /// The day backing the visible meals; falls back to today, then the first day.
    private var selectedDay: DietDayPlan? {
        guard let days = plan?.days, !days.isEmpty else { return nil }
        return days.first { $0.id == selectedDayID } ?? defaultDay(days)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let plan {
                    planContent(plan)
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
                    dietEmptyState
                        .navigationTitle("Diet")
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.85), value: plan != nil)
            .toolbar {
                if planStatus != "generating" {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Haptics.tap()
                            showChat = true
                        } label: {
                            Image(systemName: "bubble.left.and.text.bubble.right")
                        }
                        .accessibilityLabel("Plan with your coach")
                    }
                }
            }
            .sheet(isPresented: $showChat) { DietChatView() }
            .task {
                async let planTask: Void = {
                    do {
                        for try await p in repo.dietPlanStream() {
                            withAnimation(reduceMotion ? nil : .snappy) { plan = p }
                            // Default the day picker to today (or the first day) on load.
                            if let days = p?.days, !days.isEmpty, selectedDayID == nil {
                                selectedDayID = defaultDay(days)?.id
                            }
                        }
                    } catch {}
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

    // MARK: Empty state — chat first, quick-generate as a fallback

    private var dietEmptyState: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: "sparkles")
                .font(.system(size: 46))
                .foregroundStyle(Theme.accentTeal.gradient)
                .symbolRenderingMode(.hierarchical)
            VStack(spacing: Theme.Spacing.xs) {
                Text("Plan your week with AI").font(.headline)
                Text("Tell your coach what you like and it'll build a personalized 7-day meal plan around your calorie and macro targets.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: Theme.Spacing.s) {
                Button {
                    Haptics.tap()
                    showChat = true
                } label: {
                    Label("Chat with your coach", systemImage: "bubble.left.and.text.bubble.right.fill")
                }
                .buttonStyle(PrimaryButtonStyle())

                Button(working ? "Generating…" : "Or generate instantly from my profile") {
                    Task { await generate() }
                }
                .font(.subheadline)
                .tint(Theme.accentTeal)
                .disabled(working)
            }
            .padding(.top, Theme.Spacing.s)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity)
    }

    // MARK: Plan content (single-day vs 7-day)

    @ViewBuilder private func planContent(_ plan: DietPlan) -> some View {
        List {
            if plan.isWeekly, let days = plan.days, let day = selectedDay {
                Section {
                    DietDayBubbles(days: days, selection: $selectedDayID, namespace: bubbleNS)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                heroSection(summary: plan.summary, day: day)
                mealSections(day.meals)
                    // Rebuild identity per day so the meals refresh when you switch.
                    .id(day.id)
            } else {
                heroSection(summary: plan.summary, cal: plan.dailyCalories,
                            protein: plan.proteinG, carbs: plan.carbsG, fat: plan.fatG, note: nil)
                mealSections(plan.meals)
            }

            extrasSections(plan)

            Section {
                Button {
                    Haptics.tap()
                    showChat = true
                } label: {
                    Label("Plan a new week with your coach", systemImage: "bubble.left.and.text.bubble.right")
                        .frame(maxWidth: .infinity)
                }
                .tint(Theme.accentTeal)
                Button {
                    Haptics.tap()
                    Task { await generate() }
                } label: {
                    Label(working ? "Regenerating…" : "Quick regenerate from profile",
                          systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .tint(.secondary)
                .disabled(working)
            }
        }
    }

    // MARK: Hero

    /// 7-day hero: weekly summary + the selected day's macro totals + optional tip.
    private func heroSection(summary: String, day: DietDayPlan) -> some View {
        heroSection(summary: summary, cal: day.dailyCalories, protein: day.proteinG,
                    carbs: day.carbsG, fat: day.fatG, note: day.note)
    }

    private func heroSection(summary: String, cal: Int, protein: Int, carbs: Int, fat: Int, note: String?) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                if !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Theme.Spacing.s) {
                    macroStat(cal, "Calories", unit: "kcal", color: Theme.accentTeal)
                    macroStat(protein, "Protein", unit: "g", color: Theme.protein)
                    macroStat(carbs, "Carbs", unit: "g", color: Theme.carbs)
                    macroStat(fat, "Fat", unit: "g", color: Theme.fat)
                }
                if let note, !note.isEmpty {
                    Label {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "lightbulb.fill").foregroundStyle(Theme.carbs)
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Daily target")
            .accessibilityValue("\(cal) calories, \(protein) grams protein, \(carbs) grams carbs, \(fat) grams fat")
        }
    }

    // MARK: Meals

    @ViewBuilder private func mealSections(_ meals: [DietMeal]) -> some View {
        ForEach(meals.sorted { $0.order < $1.order }) { meal in
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
    }

    // MARK: Weekly extras (hydration / grocery / notes)

    @ViewBuilder private func extrasSections(_ plan: DietPlan) -> some View {
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
            } header: {
                sectionLabel(plan.isWeekly ? "Weekly grocery list" : "Grocery list", icon: "cart.fill")
            }
        }
        if !plan.notes.isEmpty {
            Section {
                Text(plan.notes).font(.caption).foregroundStyle(.secondary)
            } header: { sectionLabel("Notes", icon: "note.text") }
        }
    }

    // MARK: Small helpers

    /// Today's day if it's in the plan, else the first day.
    private func defaultDay(_ days: [DietDayPlan]) -> DietDayPlan? {
        let todayName = Date().formatted(.dateTime.weekday(.wide))
        return days.first { $0.day.caseInsensitiveCompare(todayName) == .orderedSame } ?? days.first
    }

    /// A single bold, color-coded stat chip in the hero row (value + caption label).
    private func macroStat(_ value: Int, _ label: String, unit: String, color: Color) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(value)")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(color)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(value)))
                    .minimumScaleFactor(0.7)
                Text(unit)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color.opacity(0.7))
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.s)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(reduceMotion ? nil : .snappy, value: value)
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

/// Horizontal row of weekday "bubbles" for a 7-day plan. Tapping selects that
/// day; the active pill carries a sliding gradient indicator (matchedGeometry).
/// Mirrors the workout tab's day selector for a consistent feel.
private struct DietDayBubbles: View {
    let days: [DietDayPlan]
    @Binding var selection: String?
    var namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.s) {
                    ForEach(days.sorted { $0.order < $1.order }) { day in
                        bubble(for: day).id(day.id)
                    }
                }
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.s)
            }
            .onChange(of: selection) { _, new in
                guard let new else { return }
                withAnimation(reduceMotion ? nil : .snappy) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    private func bubble(for day: DietDayPlan) -> some View {
        let isSelected = day.id == selection
        return Button {
            Haptics.selection()
            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                selection = day.id
            }
        } label: {
            Text(day.shortLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .lineLimit(1)
                .padding(.horizontal, Theme.Spacing.m)
                .frame(minHeight: Theme.minTapTarget)
                .background {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(Theme.accentGradient)
                            .matchedGeometryEffect(id: "selectedDietBubble", in: namespace)
                            .shadow(color: Theme.accentTeal.opacity(0.35), radius: 8, y: 3)
                    } else {
                        Capsule(style: .continuous)
                            .fill(.regularMaterial)
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                            )
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.day)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Show \(day.day)'s meals")
    }
}
