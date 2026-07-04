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

    /// Only fat-loss and muscle-gain move weight in a direction, so only they
    /// take a target weekly rate. Recomp/maintain hold weight steady.
    var usesWeeklyRate: Bool { self == .fatLoss || self == .muscleGain }

    /// Selectable weekly weight-change magnitudes (kg/week) for this goal, from
    /// gentle to aggressive. Kept modest and safe — the backend clamps anyway.
    var weeklyRatePresets: [Double] {
        switch self {
        case .fatLoss: return [0.25, 0.5, 0.75, 1.0]
        case .muscleGain: return [0.125, 0.25, 0.5]
        default: return []
        }
    }

    /// Sensible default rate when the user first picks this goal.
    var defaultWeeklyRate: Double {
        switch self {
        case .fatLoss: return 0.5
        case .muscleGain: return 0.25
        default: return 0
        }
    }

    /// Pace descriptor for a given rate, e.g. "Steady" / "Aggressive".
    func weeklyRateName(_ kg: Double) -> String {
        switch self {
        case .fatLoss:
            switch kg {
            case ..<0.375: return "Gentle"
            case ..<0.625: return "Steady"
            case ..<0.875: return "Aggressive"
            default: return "Rapid"
            }
        case .muscleGain:
            switch kg {
            case ..<0.1875: return "Lean"
            case ..<0.375: return "Steady"
            default: return "Fast"
            }
        default: return ""
        }
    }

    /// "lose" for a cut, "gain" for a bulk — for user-facing rate copy.
    var rateVerb: String { self == .muscleGain ? "gain" : "lose" }
}

enum MealType: String, Codable, CaseIterable, Identifiable {
    case breakfast, lunch, dinner, snack
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    /// Best-guess meal for the current time of day, used to pre-select the meal
    /// type when logging — people usually log right after eating.
    static func suggestedForNow(_ date: Date = Date()) -> MealType {
        switch Calendar.current.component(.hour, from: date) {
        case 4..<11: return .breakfast
        case 11..<16: return .lunch
        case 16..<22: return .dinner
        default: return .snack // late night / very early morning
        }
    }
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
    /// Target weekly weight-change magnitude in kg (nil unless the goal is
    /// fat-loss or muscle-gain). Drives the calorie target server-side (spec §5).
    var weeklyWeightChangeKg: Double?
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

    // Async plan-generation status, written by the backend (Lyzr agents):
    // "generating" while the agent builds the plan, "ready" once stored, "failed"
    // with an error if generation errored. nil until the user requests a plan.
    var workoutPlanStatus: String?
    var workoutPlanError: String?
    var dietPlanStatus: String?
    var dietPlanError: String?

    var hasTargets: Bool { calorieTarget != nil }
    var isWorkoutPlanGenerating: Bool { workoutPlanStatus == "generating" }
    var workoutPlanFailed: Bool { workoutPlanStatus == "failed" }
    var isDietPlanGenerating: Bool { dietPlanStatus == "generating" }
    var dietPlanFailed: Bool { dietPlanStatus == "failed" }
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
    // Optional so meals logged before fiber tracking existed still decode.
    var fiberG: Double?
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
    // Optional: plans generated before warm-up/cool-down existed decode as nil.
    var warmup: [MobilityItem]?
    var cooldown: [MobilityItem]?
}

/// A warm-up movement or cool-down stretch/posture: name + prescription
/// ("2 min", "10 reps/side", "30 s hold") + optional form cue.
struct MobilityItem: Codable, Identifiable, Equatable {
    var id: String { "\(name)-\(prescription)" }
    var name: String
    var prescription: String
    var notes: String
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

// MARK: - Diet plan (generated by the Lyzr Nutrition Architect agent)

struct DietPlan: Codable, Equatable {
    var planName: String
    var summary: String
    var dailyCalories: Int
    var proteinG: Int
    var carbsG: Int
    var fatG: Int
    var meals: [DietMeal]
    var hydrationNote: String
    var groceryList: [String]
    var notes: String
}

struct DietMeal: Codable, Identifiable, Equatable {
    var id: String { "\(order)-\(mealLabel)" }
    var mealLabel: String
    var order: Int
    var items: [DietFoodItem]

    var calories: Int { items.reduce(0) { $0 + $1.calories } }
    var proteinG: Double { items.reduce(0) { $0 + $1.proteinG } }
}

struct DietFoodItem: Codable, Identifiable, Equatable {
    var id: String { "\(name)-\(servingDescription)" }
    var name: String
    var servingDescription: String
    var calories: Int
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
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
    // Optional — the backend may omit fiber; the user can still edit it in.
    var fiberG: Double?
    var confidence: Double
    var grounded: GroundedMacros?

    private enum CodingKeys: String, CodingKey {
        case name, dishKey, servingDescription, calories, proteinG, carbsG, fatG, fiberG, confidence, grounded
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
