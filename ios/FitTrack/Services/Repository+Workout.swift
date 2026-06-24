import FirebaseFirestore
import Foundation

// Workout history helpers (spec §7.2): progressive-overload prefill reads the
// user's most recent prior session containing an exercise so the log sheet can
// seed each set's weight/reps. Scoped under users/{uid}/workoutSessions like the
// rest of Repository.

extension Repository {
    /// Sets logged for `name` in the most recent prior session that contains it.
    /// Scans the last ~20 sessions (date desc) and returns the matching set list
    /// sorted by `setIndex`. Returns `[]` if no prior session has the exercise.
    func lastSets(forExerciseNamed name: String) async -> [LoggedSet] {
        do {
            let snap = try await userDoc().collection("workoutSessions")
                .order(by: "date", descending: true)
                .limit(to: 20)
                .getDocuments()
            for doc in snap.documents {
                guard let session = try? doc.data(as: WorkoutSession.self) else { continue }
                let matching = session.loggedSets
                    .filter { $0.exerciseName == name }
                    .sorted { $0.setIndex < $1.setIndex }
                if !matching.isEmpty { return matching }
            }
        } catch {
            // Prefill is best-effort: on any read error fall back to empty defaults.
        }
        return []
    }
}
