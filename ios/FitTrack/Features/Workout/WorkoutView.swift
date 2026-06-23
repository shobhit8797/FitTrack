import SwiftUI

// Workout (spec §7.2): plan view with how-to video links, scheduled-day card,
// and session logging (sets against the plan). Attendance = WorkoutSessions.
struct WorkoutView: View {
    @Environment(Repository.self) private var repo
    @State private var plan: WorkoutPlan?
    @State private var sessions: [WorkoutSession] = []
    @State private var loggingDay: WorkoutDay?

    private var todayIsScheduled: Bool {
        guard let plan else { return false }
        let weekday = Calendar.current.component(.weekday, from: Date()) - 1 // 0=Sun
        return plan.scheduledWeekdays.contains(weekday)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let plan {
                    List {
                        Section {
                            HStack {
                                Image(systemName: todayIsScheduled ? "calendar.badge.checkmark" : "calendar")
                                    .foregroundStyle(todayIsScheduled ? Theme.accentTeal : .secondary)
                                Text(todayIsScheduled ? "Today is a scheduled training day" : "Rest day")
                                Spacer()
                                Text("\(streak()) day streak").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(plan.days) { day in
                            Section(day.dayLabel) {
                                ForEach(day.exercises) { ex in
                                    ExerciseRow(exercise: ex)
                                }
                                Button("Log this session") { loggingDay = day }
                                    .tint(Theme.accentTeal)
                            }
                        }
                    }
                    .navigationTitle(plan.splitName)
                } else {
                    EmptyStateView(systemImage: "dumbbell", title: "No plan yet",
                                   message: "Your plan is generated during onboarding.")
                        .navigationTitle("Workout")
                }
            }
            .task {
                plan = try? await repo.fetchCurrentPlan()
                do { for try await s in repo.sessionsStream() { sessions = s } } catch {}
            }
            .sheet(item: $loggingDay) { day in
                SessionLogSheet(day: day)
            }
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

struct ExerciseRow: View {
    let exercise: PlannedExercise
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(exercise.name).fontWeight(.medium)
                Spacer()
                Text("\(exercise.sets) × \(exercise.repRange)").foregroundStyle(.secondary)
                if let url = exercise.exerciseId.flatMap({ _ in URL(string: "https://fittrack.app") }) {
                    // Real impl: resolve videoUrl from catalog via getExercise.
                    Link(destination: url) { Image(systemName: "play.circle") }
                }
            }
            if !exercise.notes.isEmpty {
                Text(exercise.notes).font(.caption).foregroundStyle(.secondary)
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

    var body: some View {
        NavigationStack {
            Form {
                ForEach(day.exercises) { ex in
                    Section(ex.name) {
                        ForEach(0..<ex.sets, id: \.self) { i in
                            SetRow(exerciseName: ex.name, setIndex: i, sets: $sets)
                        }
                    }
                }
            }
            .navigationTitle(day.dayLabel)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Finish") { Task { await save() } }
                }
            }
        }
    }

    private func save() async {
        let session = WorkoutSession(id: "", date: Date(), dayLabel: day.dayLabel,
                                     loggedSets: sets, note: nil)
        try? await repo.addSession(session)
        dismiss()
    }
}

struct SetRow: View {
    let exerciseName: String
    let setIndex: Int
    @Binding var sets: [LoggedSet]
    @State private var weight = 0.0
    @State private var reps = 8

    var body: some View {
        HStack {
            Text("Set \(setIndex + 1)").font(.caption).foregroundStyle(.secondary)
            Spacer()
            TextField("kg", value: $weight, format: .number).frame(width: 60).keyboardType(.decimalPad)
            Text("kg ×")
            TextField("reps", value: $reps, format: .number).frame(width: 44).keyboardType(.numberPad)
        }
        .onChange(of: weight) { syncSet() }
        .onChange(of: reps) { syncSet() }
    }

    private func syncSet() {
        sets.removeAll { $0.exerciseName == exerciseName && $0.setIndex == setIndex }
        sets.append(LoggedSet(exerciseName: exerciseName, weightKg: weight, reps: reps, setIndex: setIndex))
    }
}
