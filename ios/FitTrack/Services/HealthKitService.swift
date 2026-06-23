import Foundation
import HealthKit

// HealthKit read/write (spec §7.5). Minimal scopes; Apple Watch data flows in
// automatically via HealthKit. Health data stays on device unless the user
// takes an action that sends a derived value.

@Observable
final class HealthKitService {
    private let store = HKHealthStore()
    private(set) var authorized = false

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
