import Foundation

// Domain models mirroring the Firestore documents written by the backend
// (spec §6). These are plain Codable value types; Firestore's offline cache
// (not a hand-rolled SwiftData sync layer) provides the local mirror.

enum Sex: String, Codable, CaseIterable, Identifiable {
    case male, female
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum ActivityLevel: String, Codable, CaseIterable, Identifiable {
    case sedentary, light, moderate, active, veryActive
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sedentary: return "Sedentary"
        case .light: return "Lightly active"
        case .moderate: return "Moderately active"
        case .active: return "Active"
        case .veryActive: return "Very active"
        }
    }
}

enum Goal: String, Codable, CaseIterable, Identifiable {
    case fatLoss, recomp, muscleGain, maintain
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fatLoss: return "Fat loss"
        case .recomp: return "Recomposition"
        case .muscleGain: return "Muscle gain"
        case .maintain: return "Maintain"
        }
    }
}

enum MealType: String, Codable, CaseIterable, Identifiable {
    case breakfast, lunch, dinner, snack
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum EntryMethod: String, Codable {
    case photo, barcode, label, manual, llm, foodDB
}

/// The user's profile + computed targets (spec §5–6). Targets are nullable
/// until the backend generates them on onboarding completion.
struct UserProfile: Codable, Equatable {
    var displayName: String
    var sex: Sex
    var birthDate: Date
    var heightCm: Double
    var weightKg: Double
    var activityLevel: ActivityLevel
    var goal: Goal
    var goalFreeText: String?
    var bodyFatPct: Double?
    var dietType: String
    var dietaryRestrictions: [String]
    var trainingDaysPerWeek: Int
    var preferredWeekdays: [Int] // 0=Sun..6=Sat
    var experience: String
    var equipment: [String]
    var injuriesNotes: String
    var freeFormContext: String

    // Targets (nil until generated server-side — never an app default).
    var calorieTarget: Int?
    var proteinTargetG: Int?
    var carbTargetG: Int?
    var fatTargetG: Int?

    var hasTargets: Bool { calorieTarget != nil }
}

struct Targets: Codable, Equatable {
    let bmr: Int
    let tdee: Int
    let calorieTarget: Int
    let proteinTargetG: Int
    let carbTargetG: Int
    let fatTargetG: Int
}

struct WeightEntry: Codable, Identifiable, Equatable {
    var id: String
    var date: Date
    var weightKg: Double
    var source: String // manual | healthKit
    var note: String?
}

struct MealEntry: Codable, Identifiable, Equatable {
    var id: String
    var mealType: MealType
    var loggedAt: Date
    var name: String
    var calories: Int
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
    var servingDescription: String?
    var entryMethod: EntryMethod
    var photoUrl: String?
    var barcode: String?
    var foodDbId: String?
    var confidence: Double?
}

/// Per-day rollup + Health metrics (spec §6). Totals are recomputed from meals
/// rather than trusted blindly (spec §9 conflict-safe merge).
struct DayLog: Codable, Equatable {
    var date: Date
    var totalCalories: Int
    var totalProteinG: Double
    var totalCarbsG: Double
    var totalFatG: Double
    var steps: Int?
    var activeEnergyKcal: Int?
    var exerciseMinutes: Int?
}

// MARK: - Workout

struct WorkoutPlan: Codable, Equatable {
    var splitName: String
    var summary: String
    var scheduledWeekdays: [Int]
    var days: [WorkoutDay]
}

struct WorkoutDay: Codable, Identifiable, Equatable {
    var id: String { "\(order)-\(dayLabel)" }
    var dayLabel: String
    var order: Int
    var exercises: [PlannedExercise]
}

struct PlannedExercise: Codable, Identifiable, Equatable {
    var id: String { "\(order)-\(name)" }
    var name: String
    var sets: Int
    var repRange: String
    var notes: String
    var order: Int
    var exerciseId: String?
}

struct Exercise: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var primaryMuscle: String
    var secondaryMuscles: [String]
    var equipment: String
    var instructions: String
    var formCues: [String]
    var videoUrl: String?
    var difficulty: String
    var isCustom: Bool
}

struct WorkoutSession: Codable, Identifiable, Equatable {
    var id: String
    var date: Date
    var dayLabel: String?
    var loggedSets: [LoggedSet]
    var note: String?
}

struct LoggedSet: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var exerciseId: String?
    var exerciseName: String
    var weightKg: Double
    var reps: Int
    var rpe: Double?
    var setIndex: Int
}

// MARK: - AI / food results (returned by Cloud Functions)

struct AnalyzedFoodItem: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var dishKey: String
    var servingDescription: String
    var calories: Int
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
    var confidence: Double
    var grounded: GroundedMacros?

    private enum CodingKeys: String, CodingKey {
        case name, dishKey, servingDescription, calories, proteinG, carbsG, fatG, confidence, grounded
    }
}

struct GroundedMacros: Codable, Equatable {
    var source: String
    var foodDbId: String
    var matchedName: String
    var estimatedGrams: Int
    var calories: Int
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
}
