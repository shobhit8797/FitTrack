import SwiftUI

// Today / Dashboard (spec §7.1). Greeting title, a scrollable week strip for
// day selection (swipe still works), a hero card with Eaten / ring / Burned and
// macro bars, activity tiles from Health, and the day's meal timeline.
// Settings lives behind the toolbar gear — not a tab (daily actions only in
// the tab bar).
struct TodayView: View {
    @Environment(Repository.self) private var repo
    @Environment(HealthKitService.self) private var health
    @Environment(FunctionsClient.self) private var functions
    @Environment(AppState.self) private var appState
    @State private var model = TodayViewModel()
    @State private var selectedDate = Date()
    @State private var planStatus: String?
    @State private var planError: String?
    @State private var retrying = false
    @State private var showSettings = false
    // Tap a logged meal to edit it; long-press (or the Delete action) removes it.
    @State private var editingMeal: MealEntry?
    @State private var mealPendingDeletion: MealEntry?
    // Gym mode: streamed plan + the day being trained right now.
    @State private var plan: WorkoutPlan?
    @State private var gymDay: WorkoutDay?
    @State private var showGymDayPicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.l) {
                    WeekStrip(selectedDate: $selectedDate)

                    if Calendar.current.isDateInToday(selectedDate) {
                        gymModeCard
                    }

                    planBanner

                    if let target = model.calorieTarget {
                        heroCard(target: target)
                    } else if model.loading {
                        targetsSkeleton
                    } else {
                        EmptyStateView(systemImage: "target", title: "No targets yet",
                                       message: "Finish setting up your profile to see your daily calorie and macro goals.")
                    }

                    // Activity tiles are Health-derived — only show them once the
                    // user has connected Apple Health, so we never display empty
                    // "0 steps / 0 min" data to someone who hasn't connected.
                    if health.connected {
                        activitySection
                    }

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
            .background(ScreenBackground())
            .refreshable { await model.load(repo: repo, health: health, date: selectedDate) }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(navTitle)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(item: $editingMeal) { meal in
                MealEditSheet(meal: meal, date: selectedDate)
            }
            .confirmationDialog(
                "Delete this meal?",
                isPresented: Binding(
                    get: { mealPendingDeletion != nil },
                    set: { if !$0 { mealPendingDeletion = nil } }
                ),
                titleVisibility: .visible,
                presenting: mealPendingDeletion
            ) { meal in
                Button("Delete", role: .destructive) {
                    Task { try? await repo.deleteMeal(meal.id, on: selectedDate) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { meal in
                Text("\"\(meal.name)\" will be removed from this day.")
            }
            .fullScreenCover(item: $gymDay) { day in WorkoutSessionView(day: day) }
            .confirmationDialog("Which workout?", isPresented: $showGymDayPicker,
                                titleVisibility: .visible) {
                ForEach(plan?.days ?? []) { day in
                    Button(day.dayLabel) { gymDay = day }
                }
            } message: {
                Text("Pick today's session.")
            }
            .task { await health.refreshConnectionState() }
            .task(id: selectedDate) { await model.load(repo: repo, health: health, date: selectedDate) }
            .task {
                do { for try await p in repo.planStream() { plan = p } } catch {}
            }
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

    // MARK: Gym mode

    /// One-tap entry into today's workout. Reads training vs rest day from the
    /// plan; Start opens the full-screen session logger (the day picker appears
    /// only when the plan has several days to choose from).
    @ViewBuilder private var gymModeCard: some View {
        if let plan, !plan.days.isEmpty {
            Card {
                HStack(spacing: Theme.Spacing.m) {
                    IconBadge(systemImage: "dumbbell.fill", color: .purple, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gym mode").font(.headline)
                        Text(todayIsScheduled
                             ? "Training day — your plan is ready."
                             : "Rest day — train anyway if you like.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Theme.Spacing.s)
                    Button {
                        Haptics.tap()
                        startGym(plan: plan)
                    } label: {
                        Label("Start", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accentTeal)
                    .accessibilityHint("Open today's workout in gym mode")
                }
            }
        }
    }

    private var todayIsScheduled: Bool {
        guard let plan else { return false }
        let weekday = Calendar.current.component(.weekday, from: Date()) - 1 // 0=Sun
        return plan.scheduledWeekdays.contains(weekday)
    }

    private func startGym(plan: WorkoutPlan) {
        if plan.days.count == 1 {
            gymDay = plan.days[0]
        } else {
            showGymDayPicker = true
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

    /// A warm, time-aware greeting for today; plain weekday names for the past.
    private var navTitle: String {
        if Calendar.current.isDateInToday(selectedDate) {
            switch Calendar.current.component(.hour, from: Date()) {
            case 0..<12: return "Good morning"
            case 12..<17: return "Good afternoon"
            default: return "Good evening"
            }
        }
        if Calendar.current.isDateInYesterday(selectedDate) { return "Yesterday" }
        return selectedDate.formatted(.dateTime.weekday(.wide))
    }

    // MARK: Hero

    /// Eaten and Burned flank the ring; the ring's hero number is what's left.
    /// Macro bars share the card so "how am I doing today" is one glance.
    private func heroCard(target: Int) -> some View {
        Card {
            VStack(spacing: Theme.Spacing.m) {
                HStack(alignment: .center) {
                    flankStat(value: model.totalCalories, label: "Eaten",
                              icon: "fork.knife", color: Theme.accentTeal)
                        .frame(maxWidth: .infinity)
                    CalorieRing(consumed: model.totalCalories, target: target, diameter: 164)
                    flankStat(value: model.activeEnergy ?? 0, label: "Burned",
                              icon: "flame.fill", color: Theme.energy)
                        .frame(maxWidth: .infinity)
                }
                .padding(.top, Theme.Spacing.xs)

                Divider()

                VStack(spacing: Theme.Spacing.sm) {
                    MacroBar(name: "Protein", current: model.totalProtein,
                             target: model.proteinTarget, color: Theme.protein)
                    MacroBar(name: "Carbs", current: model.totalCarbs,
                             target: model.carbTarget, color: Theme.carbs)
                    MacroBar(name: "Fat", current: model.totalFat,
                             target: model.fatTarget, color: Theme.fat)
                }
            }
        }
    }

    private func flankStat(value: Int, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
            Text("\(value)")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(value)))
                .animation(.snappy, value: value)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value) kilocalories")
    }

    private var targetsSkeleton: some View {
        Card {
            VStack(spacing: Theme.Spacing.l) {
                Circle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 164, height: 164)
                VStack(spacing: Theme.Spacing.m) {
                    ForEach(0..<3, id: \.self) { _ in SkeletonBar(height: 18) }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .redacted(reason: .placeholder)
        .accessibilityLabel("Loading your targets")
    }

    // MARK: Activity

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader("Activity")
            HStack(spacing: Theme.Spacing.sm) {
                activityTile("figure.walk", value: model.steps ?? 0, label: "steps", color: Theme.steps)
                activityTile("flame.fill", value: model.activeEnergy ?? 0, label: "active kcal", color: Theme.energy)
                activityTile("timer", value: model.exerciseMinutes ?? 0, label: "exercise min", color: Theme.exercise)
            }
        }
    }

    private func activityTile(_ icon: String, value: Int, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            IconBadge(systemImage: icon, color: color, size: 32)
            Text("\(value)")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(value)))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
    }

    // MARK: Meals

    private var mealsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader("Meals") {
                Button {
                    Haptics.tap()
                    appState.showLog = true
                } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accentTeal)
                }
                .accessibilityHint("Log a meal, workout, or weight")
            }

            ForEach(MealType.allCases) { type in
                let meals = model.meals.filter { $0.mealType == type }
                if !meals.isEmpty {
                    let subtotal = meals.reduce(0) { $0 + $1.calories }
                    HStack {
                        Text(type.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(subtotal) kcal")
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, Theme.Spacing.s)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .accessibilityElement(children: .combine)
                    ForEach(meals) { meal in mealRow(meal) }
                }
            }
            if model.meals.isEmpty {
                EmptyStateView(systemImage: "fork.knife", title: "No meals yet",
                               message: "Log your first meal — by photo, barcode, label, or just describe it.",
                               actionTitle: "Log a meal",
                               action: { appState.showLog = true })
            }
        }
        .animation(.snappy, value: model.meals)
    }

    private func mealRow(_ meal: MealEntry) -> some View {
        Button {
            Haptics.tap()
            editingMeal = meal
        } label: {
            Card {
                HStack(spacing: Theme.Spacing.m) {
                    IconBadge(systemImage: meal.mealType.icon, color: meal.mealType.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meal.name).fontWeight(.medium)
                            .lineLimit(2)
                        if let s = meal.servingDescription, !s.isEmpty {
                            Text(s).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text(macroLine(meal))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: Theme.Spacing.s)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(meal.calories)")
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .monospacedDigit()
                        Text("kcal")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                editingMeal = meal
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button(role: .destructive) {
                mealPendingDeletion = meal
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(meal.name), \(meal.calories) kilocalories, \(Int(meal.proteinG)) grams protein")
        .accessibilityHint("Double tap to edit, or use the actions to delete.")
    }

    /// Macro summary for a meal row — appends fiber only when it was recorded,
    /// so older meals (no fiber) read the same as before.
    private func macroLine(_ meal: MealEntry) -> String {
        var line = "P \(Int(meal.proteinG)) · C \(Int(meal.carbsG)) · F \(Int(meal.fatG))"
        if let fiber = meal.fiberG, fiber > 0 { line += " · Fb \(Int(fiber))" }
        return line + " g"
    }

    private func shift(_ days: Int) {
        guard let next = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) else { return }
        Haptics.selection()
        withAnimation(.snappy) { selectedDate = next }
    }
}

// MARK: - Week strip

/// Scrollable strip of the last four weeks. Each day is a tappable pill —
/// today gets a ring, the selected day fills with the accent gradient. Replaces
/// the old chevron day-nav: shows *where* you are in the week at a glance and
/// makes any recent day one tap away.
private struct WeekStrip: View {
    @Binding var selectedDate: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let dayCount = 28
    private var days: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<Self.dayCount).reversed().compactMap {
            cal.date(byAdding: .day, value: -$0, to: today)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.s) {
                    ForEach(days, id: \.self) { day in
                        pill(for: day)
                            .id(Calendar.current.startOfDay(for: day))
                    }
                }
                .padding(.horizontal, Theme.Spacing.xs)
                .padding(.vertical, Theme.Spacing.xs)
            }
            .onAppear {
                proxy.scrollTo(Calendar.current.startOfDay(for: selectedDate), anchor: .center)
            }
            .onChange(of: selectedDate) { _, new in
                withAnimation(reduceMotion ? nil : .snappy) {
                    proxy.scrollTo(Calendar.current.startOfDay(for: new), anchor: .center)
                }
            }
        }
    }

    private func pill(for day: Date) -> some View {
        let cal = Calendar.current
        let isSelected = cal.isDate(day, inSameDayAs: selectedDate)
        let isToday = cal.isDateInToday(day)
        return Button {
            Haptics.selection()
            withAnimation(reduceMotion ? nil : .snappy) { selectedDate = day }
        } label: {
            VStack(spacing: Theme.Spacing.xs) {
                Text(day.formatted(.dateTime.weekday(.narrow)))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(isSelected ? Theme.accentTeal : .secondary)
                Text(day.formatted(.dateTime.day()))
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? .white : .primary)
                    .frame(width: 38, height: 38)
                    .background {
                        if isSelected {
                            Circle()
                                .fill(Theme.accentGradient)
                                .shadow(color: Theme.accentTeal.opacity(0.35), radius: 6, y: 2)
                        } else if isToday {
                            Circle().strokeBorder(Theme.accentTeal, lineWidth: 1.5)
                        } else {
                            Circle().fill(Color.primary.opacity(0.05))
                        }
                    }
            }
            .frame(minWidth: Theme.minTapTarget, minHeight: Theme.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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

// MARK: - Edit a logged meal

/// Edit any meal the user has already logged — meal type, time, name, serving,
/// and every macro (spec §7.3: the logged value is always the user's to correct).
/// Saving writes back in place via the repository, which recomputes the day
/// rollup; changing the time to another day relocates the entry. Delete is also
/// available here for symmetry with the row's context menu.
struct MealEditSheet: View {
    @Environment(Repository.self) private var repo
    @Environment(\.dismiss) private var dismiss

    private let originalDate: Date
    @State private var meal: MealEntry
    @State private var serving: String
    @State private var fiber: Double
    @State private var saving = false
    @State private var error: String?
    @State private var showDeleteConfirm = false

    init(meal: MealEntry, date: Date) {
        originalDate = date
        _meal = State(initialValue: meal)
        _serving = State(initialValue: meal.servingDescription ?? "")
        _fiber = State(initialValue: meal.fiberG ?? 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Meal", selection: $meal.mealType) {
                        ForEach(MealType.allCases) { Text($0.label).tag($0) }
                    }
                    DatePicker("When", selection: $meal.loggedAt)
                }

                Section("Item") {
                    TextField("Name", text: $meal.name)
                    TextField("Serving (e.g. 1 katori)", text: $serving)
                    LabeledContent("Calories") {
                        TextField("kcal", value: $meal.calories, format: .number)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                            .font(.body.weight(.semibold))
                    }
                    macroField("Protein", value: $meal.proteinG, color: Theme.protein)
                    macroField("Carbs", value: $meal.carbsG, color: Theme.carbs)
                    macroField("Fat", value: $meal.fatG, color: Theme.fat)
                    macroField("Fiber", value: $fiber, color: Theme.carbs)
                }

                Section {
                    Button(role: .destructive) {
                        Haptics.warning()
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete meal", systemImage: "trash")
                    }
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .tint(Theme.accentTeal)
            .navigationTitle("Edit meal")
            .navigationBarTitleDisplayMode(.inline)
            .selectAllOnFocus()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .fontWeight(.semibold)
                        .disabled(saving || meal.name.isEmpty)
                }
            }
            .overlay {
                if saving {
                    Color.black.opacity(0.06).ignoresSafeArea()
                    ProgressView("Saving…")
                        .padding(Theme.Spacing.ml)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .confirmationDialog("Delete this meal?", isPresented: $showDeleteConfirm,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await delete() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\"\(meal.name)\" will be removed from this day.")
            }
        }
    }

    /// One editable macro row — mirrors MealConfirmationList's layout so editing a
    /// logged meal feels identical to the confirmation step where it was created.
    private func macroField(_ label: String, value: Binding<Double>, color: Color) -> some View {
        LabeledContent {
            HStack(spacing: 2) {
                TextField(label, value: value, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.body.weight(.medium))
                Text("g").foregroundStyle(.secondary)
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label)
            }
        }
        .accessibilityLabel("\(label) in grams")
    }

    private func save() async {
        error = nil
        saving = true
        defer { saving = false }
        let trimmedServing = serving.trimmingCharacters(in: .whitespacesAndNewlines)
        meal.servingDescription = trimmedServing.isEmpty ? nil : trimmedServing
        meal.fiberG = fiber > 0 ? fiber : nil
        do {
            try await repo.updateMeal(meal, originalDate: originalDate)
            Haptics.success()
            dismiss()
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
        }
    }

    private func delete() async {
        do {
            try await repo.deleteMeal(meal.id, on: originalDate)
            Haptics.success()
            dismiss()
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
        }
    }
}
