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

    // Weekly weight-logging reminder (client-managed, written directly to this
    // doc — Security Rules allow owner writes to non-target fields). Optional so
    // profile docs that predate the feature still decode; nil ⇒ use the
    // WeightReminderPrefs defaults (enabled, Monday, 9:00 AM). Weekday is
    // 0=Sun..6=Sat, matching preferredWeekdays / SupplementReminder.weekdays.
    var weightReminderEnabled: Bool? = nil
    var weightReminderWeekday: Int? = nil
    var weightReminderHour: Int? = nil
    var weightReminderMinute: Int? = nil

    // Telegram binding, written server-side when the user redeems a link code
    // (Security Rules block the client from touching it — it's what authorizes a
    // chat to write into this account). nil ⇒ not connected.
    var telegram: TelegramLink? = nil

    var hasTargets: Bool { calorieTarget != nil }
    var isTelegramLinked: Bool { telegram != nil }

    /// Resolved weekly weigh-in reminder settings, applying defaults for any
    /// field an older profile doc doesn't have.
    var weightReminder: WeightReminderPrefs {
        WeightReminderPrefs(
            enabled: weightReminderEnabled ?? WeightReminderPrefs.default.enabled,
            weekday: weightReminderWeekday ?? WeightReminderPrefs.default.weekday,
            hour: weightReminderHour ?? WeightReminderPrefs.default.hour,
            minute: weightReminderMinute ?? WeightReminderPrefs.default.minute
        )
    }
    var isWorkoutPlanGenerating: Bool { workoutPlanStatus == "generating" }
    var workoutPlanFailed: Bool { workoutPlanStatus == "failed" }
    var isDietPlanGenerating: Bool { dietPlanStatus == "generating" }
    var dietPlanFailed: Bool { dietPlanStatus == "failed" }
}

/// The connected Telegram chat, mirrored onto the profile so the app can show
/// connection state. The bot's own record lives outside users/{uid}.
struct TelegramLink: Codable, Equatable {
    var chatId: Int
    var username: String?
    var linkedAt: Date?
    /// The bot's public handle, stamped in at link time so the app can open the
    /// chat later without asking the backend for it again.
    var botUsername: String?

    /// "@handle" when Telegram exposes one, otherwise a neutral label — a chat
    /// with no public username is normal, not an error.
    var displayHandle: String {
        if let username, !username.isEmpty { return "@\(username)" }
        return "Connected chat"
    }
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

/// Resolved weekly weight-logging reminder settings (see UserProfile). Encodes
/// the rule: remind the user to log weight once a week on `weekday` at
/// `hour:minute`, and keep nudging daily until they've logged for the week.
/// Weekday is 0=Sun..6=Sat. Notification scheduling lives in NotificationService;
/// this type owns the small bit of "which cycle are we in" date math shared by
/// the scheduler and the in-app check-in prompt.
struct WeightReminderPrefs: Equatable {
    var enabled: Bool
    var weekday: Int // 0=Sun..6=Sat
    var hour: Int
    var minute: Int

    static let `default` = WeightReminderPrefs(enabled: true, weekday: 1, hour: 9, minute: 0)

    var time: ReminderTime { ReminderTime(hour: hour, minute: minute) }

    /// Localized recap, e.g. "Mondays at 9:00 AM".
    var summary: String {
        let symbols = Calendar.current.weekdaySymbols // [Sunday, Monday, ...]
        let day = symbols.indices.contains(weekday) ? symbols[weekday] : "Monday"
        return "\(day)s at \(time.display)"
    }

    /// The most recent moment this reminder was due at or before `now` — the
    /// start of the current weigh-in cycle. On the weigh-in day before the
    /// reminder time, this is last week's occurrence.
    func lastFireDate(now: Date = Date(), calendar: Calendar = .current) -> Date {
        var comps = DateComponents()
        comps.weekday = weekday + 1 // Calendar weekdays are 1=Sun..7=Sat
        comps.hour = hour
        comps.minute = minute
        return calendar.nextDate(
            after: now, matching: comps, matchingPolicy: .nextTime, direction: .backward
        ) ?? now
    }

    /// True once a weight has been logged during the current cycle (at or after
    /// the last time the reminder was due).
    func loggedThisCycle(lastLogged: Date?, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let lastLogged else { return false }
        return lastLogged >= lastFireDate(now: now, calendar: calendar)
    }
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

extension WorkoutPlan {
    /// Whether `date` falls on one of the plan's scheduled weekdays (0=Sun).
    func isScheduled(on date: Date = Date()) -> Bool {
        scheduledWeekdays.contains(Calendar.current.component(.weekday, from: date) - 1)
    }

    /// Best-guess session label for `date`: the plan day at the same position
    /// as `date`'s weekday within the sorted schedule (single-day plans always
    /// match). A heuristic — plans don't pin days to specific weekdays.
    func dayLabel(for date: Date = Date()) -> String? {
        guard isScheduled(on: date), !days.isEmpty else { return nil }
        let weekday = Calendar.current.component(.weekday, from: date) - 1
        let position = scheduledWeekdays.sorted().firstIndex(of: weekday) ?? 0
        return days.sorted { $0.order < $1.order }[position % days.count].dayLabel
    }
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

// MARK: - Diet plan (a single-day Lyzr plan, or a 7-day plan from the Diet coach)

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
    // A 7-day plan (built via the Diet coach chat) carries a per-day breakdown.
    // Optional so single-day plans generated before this existed still decode; when
    // present the Diet tab shows a day picker, otherwise it renders `meals` flat.
    var days: [DietDayPlan]?

    var isWeekly: Bool { !(days ?? []).isEmpty }
}

/// One day of a 7-day plan: that day's meals, its macro totals, and an optional
/// one-line tip. `dailyCalories`/macros are the day's own totals (not the plan's).
struct DietDayPlan: Codable, Identifiable, Equatable {
    var id: String { "\(order)-\(day)" }
    var day: String
    var order: Int
    var meals: [DietMeal]
    var dailyCalories: Int
    var proteinG: Int
    var carbsG: Int
    var fatG: Int
    var note: String?

    /// Short label for the day bubble, e.g. "Mon" from "Monday".
    var shortLabel: String { String(day.prefix(3)) }
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

// MARK: - Supplement / medication reminders

/// Whether a reminder is for a supplement or a medication. Purely cosmetic
/// (icon + wording) — both schedule identical local notifications.
enum ReminderKind: String, Codable, CaseIterable, Identifiable {
    case supplement, medication
    var id: String { rawValue }
    var label: String {
        switch self {
        case .supplement: return "Supplement"
        case .medication: return "Medication"
        }
    }
    var pluralLabel: String { label + "s" }
    var icon: String {
        switch self {
        case .supplement: return "pills.fill"
        case .medication: return "cross.case.fill"
        }
    }
}

/// A time-of-day for a reminder, stored as wall-clock hour/minute so it fires at
/// the same local time regardless of time zone (a `UNCalendarNotificationTrigger`
/// re-anchors to the device calendar). Not a `Date` — we never want to pin it to
/// a specific calendar day.
struct ReminderTime: Codable, Identifiable, Equatable, Hashable, Comparable {
    var hour: Int
    var minute: Int
    var id: String { String(format: "%02d%02d", hour, minute) }

    static func < (lhs: ReminderTime, rhs: ReminderTime) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }

    /// Localized "9:00 AM"-style label, formatted for the user's locale/clock.
    var display: String {
        var comps = DateComponents(); comps.hour = hour; comps.minute = minute
        let date = Calendar.current.date(from: comps) ?? Date()
        return date.formatted(.dateTime.hour().minute())
    }
}

/// A supplement or medication the user wants to be reminded to take, plus the
/// schedule for the reminder. Persisted in Firestore (users/{uid}/reminders) so
/// it survives reinstall and syncs across devices; the actual alerts are local
/// notifications scheduled on-device from these records.
struct SupplementReminder: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    /// Free-text dose, e.g. "1 tablet", "500 mg", "2 capsules". Optional.
    var dosage: String?
    var kind: ReminderKind
    /// One or more times of day to fire. At least one is required to be useful.
    var times: [ReminderTime]
    /// Weekdays to fire on, 0=Sun..6=Sat (matches `UserProfile.preferredWeekdays`).
    /// An empty array means every day.
    var weekdays: [Int]
    /// When false the reminder is kept but no notifications are scheduled.
    var enabled: Bool
    var createdAt: Date

    var isEveryDay: Bool { weekdays.isEmpty || weekdays.count == 7 }

    /// Short human summary of the schedule, e.g. "9:00 AM, 9:00 PM · Every day".
    var scheduleSummary: String {
        let timePart = times.sorted().map(\.display).joined(separator: ", ")
        let dayPart: String
        if isEveryDay {
            dayPart = "Every day"
        } else {
            let symbols = Calendar.current.shortWeekdaySymbols // [Sun, Mon, ...]
            dayPart = weekdays.sorted()
                .compactMap { symbols.indices.contains($0) ? symbols[$0] : nil }
                .joined(separator: " ")
        }
        return timePart.isEmpty ? dayPart : "\(timePart) · \(dayPart)"
    }
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

extension Array where Element == WorkoutSession {
    /// Consecutive prior days (incl. today) with at least one session.
    var currentStreak: Int {
        let days = Set(map { Calendar.current.startOfDay(for: $0.date) })
        var count = 0
        var cursor = Calendar.current.startOfDay(for: Date())
        while days.contains(cursor) {
            count += 1
            cursor = Calendar.current.date(byAdding: .day, value: -1, to: cursor)!
        }
        return count
    }
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
