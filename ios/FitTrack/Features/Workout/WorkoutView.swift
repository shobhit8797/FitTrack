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
            .sheet(item: $loggingDay) { day in
                SessionLogSheet(day: day)
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

            ForEach(Array(day.exercises.enumerated()), id: \.element.id) { idx, ex in
                ExerciseCard(exercise: ex, index: idx)
            }

            Button {
                onLog()
            } label: {
                Label("Log this session", systemImage: "square.and.pencil")
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.top, Theme.Spacing.s)
            .accessibilityHint("Record your sets for \(day.dayLabel)")
        }
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

/// Log sets against a planned day (spec §7.2). Real impl pre-fills last
/// session's weights for progressive overload.
struct SessionLogSheet: View {
    @Environment(Repository.self) private var repo
    @Environment(\.dismiss) private var dismiss
    let day: WorkoutDay
    @State private var sets: [LoggedSet] = []
    // Progressive-overload prefill: prior session's sets keyed by exercise name.
    @State private var priorSets: [String: [LoggedSet]] = [:]

    var body: some View {
        NavigationStack {
            Form {
                ForEach(day.exercises) { ex in
                    Section {
                        ForEach(0..<ex.sets, id: \.self) { i in
                            SetRow(exerciseName: ex.name, setIndex: i,
                                   prior: prior(for: ex.name, setIndex: i), sets: $sets)
                        }
                    } header: {
                        Text(ex.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .textCase(nil)
                    }
                }

                Section {
                    HStack {
                        Label("Sets logged", systemImage: "checklist")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(sets.count) of \(totalSets)")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Theme.accentTeal)
                            .contentTransition(.numericText())
                    }
                    .animation(.snappy, value: sets.count)
                }
            }
            .task {
                // Fetch each exercise's most recent prior sets once, for prefill.
                for ex in day.exercises where priorSets[ex.name] == nil {
                    priorSets[ex.name] = await repo.lastSets(forExerciseNamed: ex.name)
                }
            }
            .navigationTitle(day.dayLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Finish") {
                        Haptics.tap()
                        Task { await save() }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    /// Total number of sets planned across all exercises (for the footer summary).
    private var totalSets: Int { day.exercises.reduce(0) { $0 + $1.sets } }

    /// The matching prior set for an exercise/index, used to seed the row.
    private func prior(for name: String, setIndex: Int) -> LoggedSet? {
        priorSets[name]?.first { $0.setIndex == setIndex }
    }

    private func save() async {
        let session = WorkoutSession(id: "", date: Date(), dayLabel: day.dayLabel,
                                     loggedSets: sets, note: nil)
        try? await repo.addSession(session)
        Haptics.success()
        dismiss()
    }
}

struct SetRow: View {
    let exerciseName: String
    let setIndex: Int
    // Prior session's set for this exercise/index (progressive-overload prefill).
    let prior: LoggedSet?
    @Binding var sets: [LoggedSet]
    @State private var weight = 0.0
    @State private var reps = 8
    @State private var prefilled = false

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text("Set \(setIndex + 1)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .leading)

            Spacer(minLength: Theme.Spacing.s)

            HStack(spacing: Theme.Spacing.xs) {
                TextField("0", value: $weight, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                    .keyboardType(.decimalPad)
                    .font(.body.monospacedDigit())
                Text("kg")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("×")
                .font(.subheadline)
                .foregroundStyle(.tertiary)

            HStack(spacing: Theme.Spacing.xs) {
                TextField("0", value: $reps, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 40)
                    .keyboardType(.numberPad)
                    .font(.body.monospacedDigit())
                Text("reps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Set \(setIndex + 1)")
        // Commit-time selection haptic — fires when a field loses focus, not on
        // every keystroke, so it stays quiet while typing.
        .onSubmit { Haptics.selection() }
        .onChange(of: weight) { syncSet() }
        .onChange(of: reps) { syncSet() }
        // Seed from the prior session once it arrives, without clobbering edits.
        .onChange(of: prior) { applyPrefill() }
        .onAppear { applyPrefill() }
    }

    private func applyPrefill() {
        guard !prefilled, let prior else { return }
        prefilled = true
        weight = prior.weightKg
        reps = prior.reps
    }

    private func syncSet() {
        sets.removeAll { $0.exerciseName == exerciseName && $0.setIndex == setIndex }
        sets.append(LoggedSet(exerciseName: exerciseName, weightKg: weight, reps: reps, setIndex: setIndex))
    }
}
