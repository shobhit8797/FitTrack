import FirebaseAuth
import FirebaseFirestore
import Foundation

// Per-user data access (spec §6, §9). Firestore's offline persistence is the
// local cache + sync engine, so this is a thin typed repository, not a custom
// sync layer. Every path is scoped under users/{uid} — Security Rules enforce it.

@Observable
final class Repository {
    private let db = Firestore.firestore()

    private var uid: String? { Auth.auth().currentUser?.uid }
    private func userDoc() throws -> DocumentReference {
        guard let uid else { throw RepoError.notSignedIn }
        return db.collection("users").document(uid)
    }

    enum RepoError: LocalizedError {
        case notSignedIn
        var errorDescription: String? { "You must be signed in." }
    }

    // MARK: Profile
    func fetchProfile() async throws -> UserProfile? {
        let snap = try await userDoc().getDocument()
        guard snap.exists else { return nil }
        return try snap.data(as: UserProfile.self)
    }

    /// Live profile updates (targets land here once generated server-side).
    func profileStream() -> AsyncThrowingStream<UserProfile?, Error> {
        AsyncThrowingStream { continuation in
            guard let uid else {
                continuation.finish(throwing: RepoError.notSignedIn); return
            }
            let reg = db.collection("users").document(uid).addSnapshotListener { snap, err in
                if let err { continuation.finish(throwing: err); return }
                let profile = try? snap?.data(as: UserProfile.self)
                continuation.yield(profile)
            }
            continuation.onTermination = { _ in reg.remove() }
        }
    }

    // MARK: Meals (per day)
    private func dayId(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f.string(from: date)
    }

    func mealsCollection(for date: Date) throws -> CollectionReference {
        try userDoc().collection("dayLogs").document(dayId(date)).collection("meals")
    }

    func addMeal(_ meal: MealEntry, on date: Date) async throws {
        let ref = try mealsCollection(for: date).document()
        var m = meal; m.id = ref.documentID
        try ref.setData(from: m)
        try await recomputeDayRollup(on: date)
    }

    func deleteMeal(_ id: String, on date: Date) async throws {
        try await mealsCollection(for: date).document(id).delete()
        try await recomputeDayRollup(on: date)
    }

    func mealsStream(for date: Date) -> AsyncThrowingStream<[MealEntry], Error> {
        AsyncThrowingStream { continuation in
            do {
                let reg = try mealsCollection(for: date)
                    .order(by: "loggedAt")
                    .addSnapshotListener { snap, err in
                        if let err { continuation.finish(throwing: err); return }
                        let meals = snap?.documents.compactMap { try? $0.data(as: MealEntry.self) } ?? []
                        continuation.yield(meals)
                    }
                continuation.onTermination = { _ in reg.remove() }
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    /// Recompute the day rollup from its meals (spec §9: never trust a stored total).
    func recomputeDayRollup(on date: Date) async throws {
        let snap = try await mealsCollection(for: date).getDocuments()
        let meals = snap.documents.compactMap { try? $0.data(as: MealEntry.self) }
        let rollup: [String: Any] = [
            "date": Timestamp(date: date),
            "totalCalories": meals.reduce(0) { $0 + $1.calories },
            "totalProteinG": meals.reduce(0.0) { $0 + $1.proteinG },
            "totalCarbsG": meals.reduce(0.0) { $0 + $1.carbsG },
            "totalFatG": meals.reduce(0.0) { $0 + $1.fatG },
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        try await userDoc().collection("dayLogs").document(dayId(date))
            .setData(rollup, merge: true)
    }

    // MARK: Weight
    func addWeight(_ entry: WeightEntry) async throws {
        let ref = try userDoc().collection("weightEntries").document()
        var e = entry; e.id = ref.documentID
        try ref.setData(from: e)
    }

    func weightStream() -> AsyncThrowingStream<[WeightEntry], Error> {
        AsyncThrowingStream { continuation in
            do {
                let reg = try userDoc().collection("weightEntries")
                    .order(by: "date", descending: true)
                    .addSnapshotListener { snap, err in
                        if let err { continuation.finish(throwing: err); return }
                        let entries = snap?.documents.compactMap { try? $0.data(as: WeightEntry.self) } ?? []
                        continuation.yield(entries)
                    }
                continuation.onTermination = { _ in reg.remove() }
            } catch { continuation.finish(throwing: error) }
        }
    }

    // MARK: Workout plan + sessions
    func fetchCurrentPlan() async throws -> WorkoutPlan? {
        let snap = try await userDoc().collection("workoutPlans").document("current").getDocument()
        guard snap.exists else { return nil }
        return try snap.data(as: WorkoutPlan.self)
    }

    func addSession(_ session: WorkoutSession) async throws {
        let ref = try userDoc().collection("workoutSessions").document()
        var s = session; s.id = ref.documentID
        try ref.setData(from: s)
    }

    func sessionsStream() -> AsyncThrowingStream<[WorkoutSession], Error> {
        AsyncThrowingStream { continuation in
            do {
                let reg = try userDoc().collection("workoutSessions")
                    .order(by: "date", descending: true)
                    .addSnapshotListener { snap, err in
                        if let err { continuation.finish(throwing: err); return }
                        let sessions = snap?.documents.compactMap { try? $0.data(as: WorkoutSession.self) } ?? []
                        continuation.yield(sessions)
                    }
                continuation.onTermination = { _ in reg.remove() }
            } catch { continuation.finish(throwing: error) }
        }
    }
}
