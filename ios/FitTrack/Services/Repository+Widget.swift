import FirebaseAuth
import FirebaseFirestore
import Foundation
import WidgetKit

// Home-screen widget snapshot (see Shared/WidgetShared.swift). The widgets read
// a WidgetSnapshot from the App Group instead of talking to Firebase, so the
// app rewrites it whenever today's numbers change (meal/session writes, Today
// loads, foregrounding). Best-effort by design: a failed refresh keeps the
// previous snapshot and never surfaces an error into a user flow.

extension Repository {
    /// Fire-and-forget refresh — safe to call from any user flow.
    func refreshWidgetSnapshot() {
        Task { await self.refreshWidgetSnapshotNow() }
    }

    func refreshWidgetSnapshotNow() async {
        guard Auth.auth().currentUser != nil else {
            Repository.clearWidgetSnapshot()
            return
        }
        let now = Date()
        let profile = try? await fetchProfile()
        let plan = try? await fetchCurrentPlan()
        let meals = await todayMealsForWidget(now)
        let sessions = await recentSessionsForWidget()

        let isWorkoutDay = plan?.isScheduled(on: now) ?? false
        WidgetStore.save(WidgetSnapshot(
            dayId: WidgetStore.dayId(for: now),
            updatedAt: now,
            isSignedIn: true,
            caloriesEaten: meals.reduce(0) { $0 + $1.calories },
            calorieTarget: profile?.calorieTarget ?? 0,
            proteinG: meals.reduce(0) { $0 + $1.proteinG },
            proteinTargetG: Double(profile?.proteinTargetG ?? 0),
            carbsG: meals.reduce(0) { $0 + $1.carbsG },
            carbTargetG: Double(profile?.carbTargetG ?? 0),
            fatG: meals.reduce(0) { $0 + $1.fatG },
            fatTargetG: Double(profile?.fatTargetG ?? 0),
            mealsLoggedToday: meals.count,
            lastMealName: meals.max { $0.loggedAt < $1.loggedAt }?.name,
            isWorkoutDay: isWorkoutDay,
            todayWorkoutLabel: isWorkoutDay ? plan?.dayLabel(for: now) : nil,
            workoutLoggedToday: sessions.contains { Calendar.current.isDate($0.date, inSameDayAs: now) },
            workoutStreak: sessions.currentStreak
        ))
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Signed out: widgets show their signed-out state instead of stale data.
    static func clearWidgetSnapshot() {
        WidgetStore.save(.empty(isSignedIn: false))
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func todayMealsForWidget(_ date: Date) async -> [MealEntry] {
        guard let snap = try? await mealsCollection(for: date).getDocuments() else { return [] }
        return snap.documents.compactMap { try? $0.data(as: MealEntry.self) }
    }

    /// Newest-first sessions, capped — plenty of history for the streak count
    /// and "logged today" without reading a lifetime of documents.
    private func recentSessionsForWidget() async -> [WorkoutSession] {
        guard let snap = try? await userDoc().collection("workoutSessions")
            .order(by: "date", descending: true)
            .limit(to: 400)
            .getDocuments()
        else { return [] }
        return snap.documents.compactMap { try? $0.data(as: WorkoutSession.self) }
    }
}
