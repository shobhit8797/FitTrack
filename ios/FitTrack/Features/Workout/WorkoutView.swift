import SwiftUI

// Workout (spec §7.2): plan view with how-to video links, scheduled-day card,
// and session logging (sets against the plan). Attendance = WorkoutSessions.
struct WorkoutView: View {
    @Environment(Repository.self) private var repo
    @Environment(FunctionsClient.self) private var functions
    @State private var plan: WorkoutPlan?
    @State private var planStatus: String?
    @State private var planError: String?
    @State private var sessions: [WorkoutSession] = []
    @State private var loggingDay: WorkoutDay?
    @State private var retrying = false
    // Which day's card is on screen. Driven by the bubble selector up top so the
    // user picks a day instead of scrolling the whole plan.
    @State private var selectedDayID: String?
    @Namespace private var bubbleNS
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The day backing the visible card; falls back to the first day.
    private var selectedDay: WorkoutDay? {
        guard let plan else { return nil }
        return plan.days.first { $0.id == selectedDayID } ?? plan.days.first
    }

    private var todayIsScheduled: Bool {
        guard let plan else { return false }
        let weekday = Calendar.current.component(.weekday, from: Date()) - 1 // 0=Sun
        return plan.scheduledWeekdays.contains(weekday)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let plan {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                            StatusHeader(scheduled: todayIsScheduled, streak: streak())

                            // Pick a day from the bubbles instead of scrolling the plan.
                            DayBubbleSelector(days: plan.days, selection: $selectedDayID, namespace: bubbleNS)

                            if let day = selectedDay {
                                WorkoutDayCard(day: day) {
                                    Haptics.tap()
                                    withAnimation(.snappy) { loggingDay = day }
                                }
                                // New identity per day → the section rebuilds when you
                                // switch bubbles, so the exercise cards re-stagger in.
                                // Old day fades out; the new day's entrance is owned by
                                // each ExerciseCard's own spring, so insertion is identity.
                                .id(day.id)
                                .transition(reduceMotion
                                    ? .opacity
                                    : .asymmetric(insertion: .identity, removal: .opacity))
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.m)
                        .padding(.top, Theme.Spacing.xs)
                        .padding(.bottom, Theme.Spacing.xl + Theme.Spacing.l)
                        .animation(reduceMotion ? nil : .snappy, value: selectedDayID)
                    }
                    .navigationTitle(plan.splitName)
                    .transition(.opacity)
                } else if planStatus == "generating" {
                    EmptyStateView(systemImage: "sparkles", title: "Building your plan…",
                                   message: "Your coach is putting together a workout plan from your inputs. This usually takes a few seconds — you can keep using the app.")
                        .navigationTitle("Workout")
                } else if planStatus == "failed" {
                    EmptyStateView(
                        systemImage: "exclamationmark.triangle",
                        title: "Couldn't build your plan",
                        message: planError ?? "Something went wrong generating your plan.",
                        actionTitle: retrying ? "Retrying…" : "Try again",
                        action: { Task { await retry() } }
                    )
                    .navigationTitle("Workout")
                } else {
                    EmptyStateView(
                        systemImage: "dumbbell", title: "No workout plan yet",
                        message: "Generate a personalized plan from your profile and goals.",
                        actionTitle: retrying ? "Generating…" : "Generate plan",
                        action: { Task { await retry() } }
                    )
                    .navigationTitle("Workout")
                }
            }
            .background(ScreenBackground())
            // Stream the plan, generation status, and sessions concurrently so the
            // plan appears the moment the async generator finishes.
            .task {
                async let planTask: Void = {
                    do {
                        for try await p in repo.planStream() {
                            // Animate the plan materializing once the generator finishes.
                            withAnimation(reduceMotion ? nil : .snappy) { plan = p }
                            // Default the bubble selection to the first day on first load.
                            if selectedDayID == nil { selectedDayID = p?.days.first?.id }
                        }
                    } catch {}
                }()
                async let statusTask: Void = {
                    do {
                        for try await profile in repo.profileStream() {
                            planStatus = profile?.workoutPlanStatus
                            planError = profile?.workoutPlanError
                        }
                    } catch {}
                }()
                async let sessionsTask: Void = {
                    do { for try await s in repo.sessionsStream() { sessions = s } } catch {}
                }()
                _ = await (planTask, statusTask, sessionsTask)
            }
            // Full-screen: gym mode is immersive, and a stray swipe shouldn't
            // toss a half-logged session.
            .fullScreenCover(item: $loggingDay) { day in
                WorkoutSessionView(day: day)
            }
        }
    }

    private func retry() async {
        guard !retrying else { return }
        retrying = true
        defer { retrying = false }
        // Optimistically reflect the in-flight state; the profile stream will
        // confirm once the backend flips workoutPlanStatus.
        planStatus = "generating"
        do { try await functions.generateWorkoutPlan() } catch {
            planStatus = "failed"
            planError = error.localizedDescription
        }
    }

    private func streak() -> Int {
        // Count consecutive prior days (incl. today) with a session.
        let days = Set(sessions.map { Calendar.current.startOfDay(for: $0.date) })
        var count = 0
        var cursor = Calendar.current.startOfDay(for: Date())
        while days.contains(cursor) {
            count += 1
            cursor = Calendar.current.date(byAdding: .day, value: -1, to: cursor)!
        }
        return count
    }
}

/// Horizontal row of day "bubbles" pinned above the card. Tapping a bubble
/// selects that day; the selected pill carries a sliding gradient indicator
/// (matchedGeometry) so the selection glides between days instead of snapping.
private struct DayBubbleSelector: View {
    let days: [WorkoutDay]
    @Binding var selection: String?
    var namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.s) {
                    ForEach(days) { day in
                        bubble(for: day).id(day.id)
                    }
                }
                // Inset so the selected pill's shadow/glow isn't clipped.
                .padding(.horizontal, Theme.Spacing.xs)
                .padding(.vertical, Theme.Spacing.s)
            }
            // Keep the active day centered as selection moves.
            .onChange(of: selection) { _, new in
                guard let new else { return }
                withAnimation(reduceMotion ? nil : .snappy) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    private func bubble(for day: WorkoutDay) -> some View {
        let isSelected = day.id == selection
        return Button {
            Haptics.selection()
            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                selection = day.id
            }
        } label: {
            Text(day.dayLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .lineLimit(1)
                .padding(.horizontal, Theme.Spacing.m)
                .frame(minHeight: Theme.minTapTarget)
                .background {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(Theme.accentGradient)
                            .matchedGeometryEffect(id: "selectedBubble", in: namespace)
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
        .accessibilityLabel(day.dayLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Show \(day.dayLabel) exercises")
    }
}

/// The selected day, rendered as a header + a stack of individual exercise
/// cards (each with its own depth and a staggered spring-in), and the log
/// action as the one obvious CTA at the bottom.
private struct WorkoutDayCard: View {
    let day: WorkoutDay
    var onLog: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(day.dayLabel)
                    .font(.title3.weight(.semibold))
                Spacer(minLength: Theme.Spacing.s)
                Text("^[\(day.exercises.count) exercise](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Spacing.xs)

            if let warmup = day.warmup, !warmup.isEmpty {
                MobilityCard(title: "Warm-up", icon: "figure.flexibility", items: warmup)
            }

            ForEach(Array(day.exercises.enumerated()), id: \.element.id) { idx, ex in
                ExerciseCard(exercise: ex, index: idx)
            }

            if let cooldown = day.cooldown, !cooldown.isEmpty {
                MobilityCard(title: "Cool-down", icon: "figure.mind.and.body", items: cooldown)
            }

            Button {
                onLog()
            } label: {
                Label("Start workout", systemImage: "play.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.top, Theme.Spacing.s)
            .accessibilityHint("Open gym mode and record your sets for \(day.dayLabel)")
        }
    }
}

/// Compact warm-up / cool-down list on the plan view: movement + prescription
/// per row, with the optional form cue underneath.
private struct MobilityCard: View {
    let title: String
    let icon: String
    let items: [MobilityItem]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accentTeal)
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.name)
                            .font(.subheadline)
                        Spacer(minLength: Theme.Spacing.s)
                        Text(item.prescription)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    if !item.notes.isEmpty {
                        Text(item.notes)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }
}

/// A single exercise as its own elevated card. Material surface + hairline
/// stroke + soft shadow give it depth; it springs in from slightly below with a
/// per-row delay so the day's exercises cascade into place on selection.
private struct ExerciseCard: View {
    let exercise: PlannedExercise
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        ExerciseRow(exercise: exercise)
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.08), radius: 10, y: 5)
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.97, anchor: .top)
            .offset(y: shown ? 0 : 12)
            .onAppear {
                guard !reduceMotion else { shown = true; return }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)
                    .delay(Double(index) * 0.05)) {
                    shown = true
                }
            }
    }
}

/// Calm status header: scheduled/rest state on the left, an accent streak count
/// on the right.
private struct StatusHeader: View {
    let scheduled: Bool
    let streak: Int

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: scheduled ? "calendar.badge.checkmark" : "calendar")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(scheduled ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.secondary))
                .frame(width: Theme.minTapTarget, height: Theme.minTapTarget)

            VStack(alignment: .leading, spacing: 2) {
                Text(scheduled ? "Scheduled training day" : "Rest day")
                    .font(.headline)
                Text(scheduled ? "Time to put in the work." : "Recover and come back strong.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: Theme.Spacing.s)

            if streak > 0 {
                VStack(alignment: .trailing, spacing: 0) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "flame.fill")
                            .font(.subheadline)
                            .foregroundStyle(Theme.accentTeal)
                        Text("\(streak)")
                            .font(.title2.weight(.bold).monospacedDigit())
                            .foregroundStyle(Theme.accentTeal)
                            .contentTransition(.numericText())
                    }
                    Text("day streak")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(streak) day streak")
            }
        }
        .animation(.snappy, value: streak)
        .accessibilityElement(children: .combine)
    }
}

struct ExerciseRow: View {
    @Environment(FunctionsClient.self) private var functions
    let exercise: PlannedExercise
    // Resolved once per row appearance; nil URL means no video to link to.
    @State private var videoURL: URL?
    @State private var resolved = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.sm) {
                Text(exercise.name)
                    .font(.body.weight(.medium))
                Spacer(minLength: Theme.Spacing.s)
                Text("\(exercise.sets) × \(exercise.repRange)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                // Hidden until the catalog lookup yields a real videoUrl.
                if let videoURL {
                    Link(destination: videoURL) {
                        Image(systemName: "play.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Theme.accentTeal)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Watch how-to video for \(exercise.name)")
                }
            }
            if !exercise.notes.isEmpty {
                Text(exercise.notes).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(exercise.name), \(exercise.sets) sets of \(exercise.repRange) reps")
        .task {
            // One lookup per row appearance — don't spam the network.
            guard !resolved else { return }
            resolved = true
            let catalog = try? await functions.resolveExercise(id: exercise.exerciseId, name: exercise.name)
            if let urlString = catalog?.videoUrl, let url = URL(string: urlString) {
                videoURL = url
            }
        }
    }
}

// MARK: - Gym-mode session logger

/// One editable set in the gym-mode logger. The plan seeds the initial rows;
/// after that the user owns them — add, delete, change weight/reps freely.
struct EditableSet: Identifiable {
    let id = UUID()
    var weightKg: Double
    var reps: Int
    var done = false
}

/// All sets for one exercise in the running session.
struct ExerciseSessionLog: Identifiable {
    let id = UUID()
    let exercise: PlannedExercise
    var sets: [EditableSet]
    var priorSummary: String?
}

/// Gym mode (spec §7.2): full-screen session logger. Check sets off as you do
/// them (progress bar + elapsed timer up top), swipe to delete a set, add
/// extras per exercise — the plan is a starting point, not a cage. Weights and
/// reps prefill from the last session for progressive overload; only checked
/// sets are saved.
struct WorkoutSessionView: View {
    @Environment(Repository.self) private var repo
    @Environment(\.dismiss) private var dismiss
    let day: WorkoutDay

    @State private var logs: [ExerciseSessionLog] = []
    @State private var startedAt = Date()
    @State private var saving = false
    @State private var showDiscardConfirm = false
    // Checked-off warm-up / cool-down items (kept local; not saved as sets).
    @State private var warmupDone: Set<String> = []
    @State private var cooldownDone: Set<String> = []

    private var doneCount: Int { logs.reduce(0) { $0 + $1.sets.filter(\.done).count } }
    private var totalCount: Int { logs.reduce(0) { $0 + $1.sets.count } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progressHeader
                List {
                    if let warmup = day.warmup, !warmup.isEmpty {
                        MobilitySection(title: "Warm-up", icon: "figure.flexibility",
                                        items: warmup, done: $warmupDone)
                    }
                    ForEach($logs) { $log in
                        ExerciseLogSection(log: $log)
                    }
                    if let cooldown = day.cooldown, !cooldown.isEmpty {
                        MobilitySection(title: "Cool-down", icon: "figure.mind.and.body",
                                        items: cooldown, done: $cooldownDone)
                    }
                    Section {
                    } footer: {
                        Text("Check a set off as you finish it — only checked sets are saved. Swipe a set to delete it.")
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .selectAllOnFocus()
            }
            .background(ScreenBackground())
            .navigationTitle(day.dayLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        if doneCount > 0 { showDiscardConfirm = true } else { dismiss() }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close workout")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Finish") {
                        Haptics.tap()
                        Task { await finish() }
                    }
                    .fontWeight(.semibold)
                    .disabled(doneCount == 0 || saving)
                }
            }
            .confirmationDialog("Discard this workout?", isPresented: $showDiscardConfirm,
                                titleVisibility: .visible) {
                Button("Discard workout", role: .destructive) { dismiss() }
                Button("Keep training", role: .cancel) {}
            } message: {
                Text("You've checked \(doneCount) sets — they won't be saved.")
            }
            .task { await buildLogs() }
        }
        .interactiveDismissDisabled(doneCount > 0) // no accidental swipe-away mid-workout
    }

    /// Sticky session status: elapsed time, sets done, and a progress bar.
    private var progressHeader: some View {
        VStack(spacing: Theme.Spacing.s) {
            HStack {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "timer")
                        .foregroundStyle(Theme.accentTeal)
                    Text(startedAt, style: .timer)
                        .monospacedDigit()
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                    Text("\(doneCount)")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(Theme.accentTeal)
                        .contentTransition(.numericText())
                    Text("of \(totalCount) sets")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .animation(.snappy, value: doneCount)
            }
            ProgressView(value: totalCount > 0 ? Double(doneCount) / Double(totalCount) : 0)
                .tint(Theme.accentTeal)
                .animation(.snappy, value: doneCount)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(doneCount) of \(totalCount) sets done")
    }

    /// Seed one section per exercise: planned set count, weights/reps from the
    /// most recent session with that exercise (falling back to the plan's rep
    /// range), plus a "Last time" summary line.
    private func buildLogs() async {
        guard logs.isEmpty else { return }
        var built: [ExerciseSessionLog] = []
        for ex in day.exercises.sorted(by: { $0.order < $1.order }) {
            let prior = await repo.lastSets(forExerciseNamed: ex.name)
            let sets = (0..<max(ex.sets, 1)).map { i -> EditableSet in
                let p = prior.first { $0.setIndex == i } ?? prior.last
                return EditableSet(weightKg: p?.weightKg ?? 0,
                                   reps: p?.reps ?? Self.defaultReps(from: ex.repRange))
            }
            let best = prior.max { $0.weightKg < $1.weightKg }
            let summary = best.map { "Last time: \(Self.trimmed($0.weightKg)) kg × \($0.reps)" }
            built.append(ExerciseSessionLog(exercise: ex, sets: sets, priorSummary: summary))
        }
        logs = built
    }

    /// First number in a rep range like "8-12" or "10", else 8.
    private static func defaultReps(from repRange: String) -> Int {
        Int(repRange.prefix { $0.isNumber }) ?? 8
    }

    private static func trimmed(_ kg: Double) -> String {
        kg.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(kg)) : String(format: "%.1f", kg)
    }

    private func finish() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        var logged: [LoggedSet] = []
        for log in logs {
            for (i, s) in log.sets.enumerated() where s.done {
                logged.append(LoggedSet(exerciseId: log.exercise.exerciseId,
                                        exerciseName: log.exercise.name,
                                        weightKg: s.weightKg, reps: s.reps,
                                        rpe: nil, setIndex: i))
            }
        }
        let session = WorkoutSession(id: "", date: Date(), dayLabel: day.dayLabel,
                                     loggedSets: logged, note: nil)
        try? await repo.addSession(session)
        Haptics.success()
        dismiss()
    }
}

/// Checkable warm-up / cool-down list in the session logger. These aren't
/// saved with the session — the checks are pacing, not history.
private struct MobilitySection: View {
    let title: String
    let icon: String
    let items: [MobilityItem]
    @Binding var done: Set<String>

    var body: some View {
        Section {
            ForEach(items) { item in
                let isDone = done.contains(item.id)
                Button {
                    Haptics.tap(isDone ? .light : .medium)
                    withAnimation(.snappy) {
                        if isDone { done.remove(item.id) } else { done.insert(item.id) }
                    }
                } label: {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(isDone ? Theme.accentTeal : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(isDone ? .secondary : .primary)
                            if !item.notes.isEmpty {
                                Text(item.notes)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: Theme.Spacing.s)
                        Text(item.prescription)
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(isDone ? Theme.accentTeal.opacity(0.08) : nil)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.name), \(item.prescription)")
                .accessibilityAddTraits(isDone ? [.isButton, .isSelected] : .isButton)
            }
        } header: {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accentTeal)
                .textCase(nil)
        }
    }
}

/// One exercise's sets: header with target + last-time hint, checkable set
/// rows (swipe to delete), and an add-set row that clones the last set.
private struct ExerciseLogSection: View {
    @Binding var log: ExerciseSessionLog

    var body: some View {
        Section {
            ForEach(Array(log.sets.enumerated()), id: \.element.id) { idx, _ in
                SetLogRow(set: $log.sets[idx], number: idx + 1)
            }
            .onDelete { offsets in
                Haptics.tap()
                withAnimation(.snappy) { log.sets.remove(atOffsets: offsets) }
            }

            Button {
                Haptics.tap()
                let last = log.sets.last
                withAnimation(.snappy) {
                    log.sets.append(EditableSet(weightKg: last?.weightKg ?? 0,
                                                reps: last?.reps ?? 8))
                }
            } label: {
                Label("Add set", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.accentTeal)
            }
            .accessibilityHint("Adds another set of \(log.exercise.name)")
        } header: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(log.exercise.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .textCase(nil)
                    if let priorSummary = log.priorSummary {
                        Text(priorSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                }
                Spacer(minLength: Theme.Spacing.s)
                Text("Plan: \(log.exercise.sets) × \(log.exercise.repRange)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
        }
    }
}

/// A single checkable set: big check target on the left, editable weight and
/// reps on the right. Checking gives a medium-impact haptic — the "rep done"
/// moment should feel like something.
private struct SetLogRow: View {
    @Binding var set: EditableSet
    let number: Int

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Button {
                Haptics.tap(set.done ? .light : .medium)
                withAnimation(.snappy) { set.done.toggle() }
            } label: {
                Image(systemName: set.done ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(set.done ? Theme.accentTeal : Color.secondary)
                    .frame(width: Theme.minTapTarget - 12, height: Theme.minTapTarget - 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(set.done ? "Set \(number) done" : "Set \(number) not done")
            .accessibilityHint("Double-tap to toggle")

            Text("Set \(number)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(set.done ? .secondary : .primary)

            Spacer(minLength: Theme.Spacing.s)

            HStack(spacing: Theme.Spacing.xs) {
                TextField("0", value: $set.weightKg, format: .number.precision(.fractionLength(0...1)))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                    .keyboardType(.decimalPad)
                    .font(.body.weight(.semibold).monospacedDigit())
                Text("kg")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("×")
                .font(.subheadline)
                .foregroundStyle(.tertiary)

            HStack(spacing: Theme.Spacing.xs) {
                TextField("0", value: $set.reps, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 36)
                    .keyboardType(.numberPad)
                    .font(.body.weight(.semibold).monospacedDigit())
                Text("reps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listRowBackground(set.done ? Theme.accentTeal.opacity(0.08) : nil)
        .onSubmit { Haptics.selection() }
    }
}
