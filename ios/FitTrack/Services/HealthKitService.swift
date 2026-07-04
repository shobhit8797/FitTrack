import Foundation
import HealthKit

// HealthKit read/write (spec §7.5). Minimal scopes; Apple Watch data flows in
// automatically via HealthKit. Health data stays on device unless the user
// takes an action that sends a derived value.

@Observable
final class HealthKitService {
    private let store = HKHealthStore()
    private(set) var authorized = false

    /// Whether the user has connected Apple Health (been through the permission
    /// sheet at least once). Unlike `authorized` — which only reflects this
    /// session — this is derived from HealthKit's own request status, so it
    /// survives relaunches. The dashboard hides its activity tiles until this is
    /// true, so we never show empty/zero Health metrics to a user who hasn't
    /// connected. HealthKit deliberately won't reveal per-type *read* grants, so
    /// "have we ever requested?" is the honest, stable signal we can rely on.
    private(set) var connected = false

    /// Bumped on the main actor whenever an observer query reports new samples
    /// (spec §7.5). Views key a reload off this so the dashboard reflects live
    /// Watch/iPhone data without manual refresh.
    private(set) var lastUpdate = Date.distantPast

    /// Identifiers we watch for live updates (steps, active energy, body mass).
    private let observedIdentifiers: [HKQuantityTypeIdentifier] = [
        .stepCount, .activeEnergyBurned, .bodyMass,
    ]
    private var observerQueries: [HKObserverQuery] = []
    private var observing = false

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        if let steps = HKObjectType.quantityType(forIdentifier: .stepCount) { types.insert(steps) }
        if let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) { types.insert(energy) }
        if let exercise = HKObjectType.quantityType(forIdentifier: .appleExerciseTime) { types.insert(exercise) }
        if let mass = HKObjectType.quantityType(forIdentifier: .bodyMass) { types.insert(mass) }
        types.insert(HKObjectType.workoutType())
        return types
    }

    private var writeTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = []
        if let mass = HKObjectType.quantityType(forIdentifier: .bodyMass) { types.insert(mass) }
        if let energy = HKObjectType.quantityType(forIdentifier: .dietaryEnergyConsumed) { types.insert(energy) }
        return types
    }

    func requestAuthorization() async throws {
        guard isAvailable else { return }
        try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
        authorized = true
        connected = true
        startObserving()
    }

    /// Refresh `connected` from HealthKit's request status — call at launch so a
    /// user who connected on a previous run still sees their activity tiles.
    /// `.unnecessary` means every type has already been requested (i.e. the user
    /// has been through the permission sheet); `.shouldRequest` means not yet.
    @MainActor
    func refreshConnectionState() async {
        guard isAvailable else { connected = false; return }
        let status: HKAuthorizationRequestStatus? = try? await withCheckedThrowingContinuation { cont in
            store.getRequestStatusForAuthorization(toShare: writeTypes, read: readTypes) { status, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: status) }
            }
        }
        connected = (status == .unnecessary)
        if connected { startObserving() }
    }

    /// Live refresh (spec §7.5): an HKObserverQuery per watched type plus background
    /// delivery, so the dashboard updates as Watch/iPhone samples arrive. Idempotent.
    func startObserving() {
        guard isAvailable, !observing else { return }
        observing = true
        for id in observedIdentifiers {
            guard let type = HKObjectType.quantityType(forIdentifier: id) else { continue }
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, _ in
                // Surface the change to observers, then ack so HealthKit stops retrying.
                self?.bumpUpdate()
                completion()
            }
            store.execute(query)
            observerQueries.append(query)
            // Wake the app for new samples even when backgrounded. Hourly cadence is
            // plenty for daily rollups and is battery-friendly.
            store.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
        }
    }

    private func bumpUpdate() {
        Task { @MainActor in self.lastUpdate = Date() }
    }

    /// Daily rollup for the dashboard (spec §7.5).
    struct DailyMetrics {
        var steps: Int?
        var activeEnergyKcal: Int?
        var exerciseMinutes: Int?
    }

    func dailyMetrics(for date: Date) async -> DailyMetrics {
        async let steps = sum(.stepCount, unit: .count(), on: date)
        async let energy = sum(.activeEnergyBurned, unit: .kilocalorie(), on: date)
        async let exercise = sum(.appleExerciseTime, unit: .minute(), on: date)
        return DailyMetrics(
            steps: (await steps).map(Int.init),
            activeEnergyKcal: (await energy).map(Int.init),
            exerciseMinutes: (await exercise).map(Int.init)
        )
    }

    private func sum(_ id: HKQuantityTypeIdentifier, unit: HKUnit, on date: Date) async -> Double? {
        guard let type = HKObjectType.quantityType(forIdentifier: id) else { return nil }
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        return await withCheckedContinuation { cont in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate,
                                          options: .cumulativeSum) { _, stats, _ in
                cont.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    /// Optional write-back of body mass (spec §7.4 toggle).
    func writeBodyMass(kg: Double, date: Date) async throws {
        guard let type = HKObjectType.quantityType(forIdentifier: .bodyMass) else { return }
        let q = HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: kg)
        let sample = HKQuantitySample(type: type, quantity: q, start: date, end: date)
        try await store.save(sample)
    }
}
