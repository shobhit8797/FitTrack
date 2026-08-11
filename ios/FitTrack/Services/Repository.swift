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
    func userDoc() throws -> DocumentReference {
        guard let uid else { throw RepoError.notSignedIn }
        return db.collection("users").document(uid)
    }

    enum RepoError: LocalizedError {
        case notSignedIn
        var errorDescription: String? { "You must be signed in." }
    }

    // MARK: Profile
    func fetchProfile() async throws -> UserProfile? {
        if Demo.isActive { return DemoData.profile }
        let snap = try await userDoc().getDocument()
        guard snap.exists else { return nil }
        return try snap.data(as: UserProfile.self)
    }

    /// Live profile updates (targets land here once generated server-side).
    func profileStream() -> AsyncThrowingStream<UserProfile?, Error> {
        if Demo.isActive { return Demo.stream(DemoData.profile) }
        return AsyncThrowingStream { continuation in
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
        if Demo.isActive { return }
        let ref = try mealsCollection(for: date).document()
        var m = meal; m.id = ref.documentID
        try ref.setData(from: m)
        try await recomputeDayRollup(on: date)
    }

    func deleteMeal(_ id: String, on date: Date) async throws {
        if Demo.isActive { return }
        try await mealsCollection(for: date).document(id).delete()
        try await recomputeDayRollup(on: date)
    }

    /// Update an existing meal in place. If the edit moves it to a different
    /// calendar day (the "when" was changed), the document is relocated to that
    /// day's collection and both days' rollups are recomputed — so day totals
    /// stay correct on either side of the move.
    func updateMeal(_ meal: MealEntry, originalDate: Date) async throws {
        if Demo.isActive { return }
        let originalDay = dayId(originalDate)
        let newDay = dayId(meal.loggedAt)
        if originalDay == newDay {
            try mealsCollection(for: meal.loggedAt).document(meal.id).setData(from: meal)
            try await recomputeDayRollup(on: meal.loggedAt)
        } else {
            try await mealsCollection(for: originalDate).document(meal.id).delete()
            let ref = try mealsCollection(for: meal.loggedAt).document()
            var moved = meal; moved.id = ref.documentID
            try ref.setData(from: moved)
            try await recomputeDayRollup(on: originalDate)
            try await recomputeDayRollup(on: meal.loggedAt)
        }
    }

    func mealsStream(for date: Date) -> AsyncThrowingStream<[MealEntry], Error> {
        if Demo.isActive { return Demo.stream(DemoData.meals(for: date)) }
        return AsyncThrowingStream { continuation in
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
            "totalFiberG": meals.reduce(0.0) { $0 + ($1.fiberG ?? 0) },
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        try await userDoc().collection("dayLogs").document(dayId(date))
            .setData(rollup, merge: true)
        if Calendar.current.isDateInToday(date) { refreshWidgetSnapshot() }
    }

    // MARK: Weight
    func addWeight(_ entry: WeightEntry) async throws {
        if Demo.isActive { return }
        let ref = try userDoc().collection("weightEntries").document()
        var e = entry; e.id = ref.documentID
        try ref.setData(from: e)
    }

    /// Date of the newest weight entry, or nil if none. One-shot fetch (cheaper
    /// than a listener) for the weekly-reminder "has the user logged this cycle?"
    /// check on foreground and after saving reminder settings.
    func mostRecentWeightDate() async throws -> Date? {
        if Demo.isActive { return DemoData.weights.map(\.date).max() }
        let snap = try await userDoc().collection("weightEntries")
            .order(by: "date", descending: true).limit(to: 1).getDocuments()
        return snap.documents.first.flatMap { try? $0.data(as: WeightEntry.self) }?.date
    }

    /// Persist the weekly weigh-in reminder settings onto the user profile doc.
    /// Merges just these keys so it never touches targets or other profile fields
    /// (Security Rules allow owner writes to everything except the target fields).
    func updateWeightReminder(_ prefs: WeightReminderPrefs) async throws {
        if Demo.isActive { return }
        try await userDoc().setData([
            "weightReminderEnabled": prefs.enabled,
            "weightReminderWeekday": prefs.weekday,
            "weightReminderHour": prefs.hour,
            "weightReminderMinute": prefs.minute,
        ], merge: true)
    }

    func weightStream() -> AsyncThrowingStream<[WeightEntry], Error> {
        if Demo.isActive { return Demo.stream(DemoData.weights) }
        return AsyncThrowingStream { continuation in
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
        if Demo.isActive { return DemoData.workoutPlan }
        let snap = try await userDoc().collection("workoutPlans").document("current").getDocument()
        guard snap.exists else { return nil }
        return try snap.data(as: WorkoutPlan.self)
    }

    /// Live current-plan updates. The plan is generated asynchronously after
    /// onboarding, so the Workout tab streams it in rather than fetching once.
    func planStream() -> AsyncThrowingStream<WorkoutPlan?, Error> {
        if Demo.isActive { return Demo.stream(DemoData.workoutPlan) }
        return AsyncThrowingStream { continuation in
            guard let uid else {
                continuation.finish(throwing: RepoError.notSignedIn); return
            }
            let reg = db.collection("users").document(uid)
                .collection("workoutPlans").document("current")
                .addSnapshotListener { snap, err in
                    if let err { continuation.finish(throwing: err); return }
                    let plan = try? snap?.data(as: WorkoutPlan.self)
                    continuation.yield(plan)
                }
            continuation.onTermination = { _ in reg.remove() }
        }
    }

    // MARK: Diet plan
    func fetchCurrentDietPlan() async throws -> DietPlan? {
        if Demo.isActive { return DemoData.dietPlan }
        let snap = try await userDoc().collection("dietPlans").document("current").getDocument()
        guard snap.exists else { return nil }
        return try snap.data(as: DietPlan.self)
    }

    /// Live current diet-plan updates. Generated asynchronously after the user
    /// requests it, so the Diet tab streams it in rather than fetching once.
    func dietPlanStream() -> AsyncThrowingStream<DietPlan?, Error> {
        if Demo.isActive { return Demo.stream(DemoData.dietPlan) }
        return AsyncThrowingStream { continuation in
            guard let uid else {
                continuation.finish(throwing: RepoError.notSignedIn); return
            }
            let reg = db.collection("users").document(uid)
                .collection("dietPlans").document("current")
                .addSnapshotListener { snap, err in
                    if let err { continuation.finish(throwing: err); return }
                    let plan = try? snap?.data(as: DietPlan.self)
                    continuation.yield(plan)
                }
            continuation.onTermination = { _ in reg.remove() }
        }
    }

    func addSession(_ session: WorkoutSession) async throws {
        if Demo.isActive { return }
        let ref = try userDoc().collection("workoutSessions").document()
        var s = session; s.id = ref.documentID
        try ref.setData(from: s)
        // Saving a workout is the clock-out: clear the widget's gym clock and
        // cancel its pending "still at the gym?" reminder.
        GymClock.end()
        refreshWidgetSnapshot()
    }

    func sessionsStream() -> AsyncThrowingStream<[WorkoutSession], Error> {
        if Demo.isActive { return Demo.stream(DemoData.sessions) }
        return AsyncThrowingStream { continuation in
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
