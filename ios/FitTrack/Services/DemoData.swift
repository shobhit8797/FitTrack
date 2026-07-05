import Foundation

// Demo mode (marketing capture only). When launched with the environment
// variable FITTRACK_DEMO=1, the app bypasses Firebase auth and every repository
// read serves the seeded, realistic data below instead of hitting Firestore, so
// a UI-test walkthrough can drive fully-populated screens on the simulator for a
// screen recording. Nothing here ships in a normal launch — the flag is only set
// by FitTrackUITests, never by the app itself.

enum Demo {
    static let isActive = ProcessInfo.processInfo.environment["FITTRACK_DEMO"] == "1"

    /// A one-shot async stream that yields a single seeded value and completes —
    /// mimics a Firestore snapshot listener that has delivered its first value.
    static func stream<T>(_ value: T) -> AsyncThrowingStream<T, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(value)
            continuation.finish()
        }
    }
}

/// All seeded content for demo mode. Dates are relative to "now" so the week
/// strip, charts, and streaks always look current whenever the video is shot.
enum DemoData {
    private static let cal = Calendar.current

    private static func daysAgo(_ n: Int, hour: Int = 12, minute: Int = 0) -> Date {
        let day = cal.date(byAdding: .day, value: -n, to: cal.startOfDay(for: Date()))!
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    // MARK: Profile + targets

    static let profile = UserProfile(
        displayName: "Alex",
        sex: .male,
        birthDate: cal.date(from: DateComponents(year: 1994, month: 5, day: 12)) ?? Date(),
        heightCm: 178,
        weightKg: 79.3,
        activityLevel: .moderate,
        goal: .fatLoss,
        goalFreeText: "Lean out for summer while keeping my strength.",
        weeklyWeightChangeKg: 0.5,
        bodyFatPct: 18,
        dietType: "Balanced",
        dietaryRestrictions: [],
        trainingDaysPerWeek: 4,
        preferredWeekdays: [1, 2, 4, 5],
        experience: "Intermediate",
        equipment: ["Full gym"],
        injuriesNotes: "",
        freeFormContext: "",
        calorieTarget: 2200,
        proteinTargetG: 175,
        carbTargetG: 210,
        fatTargetG: 65,
        workoutPlanStatus: "ready",
        workoutPlanError: nil,
        dietPlanStatus: "ready",
        dietPlanError: nil
    )

    // MARK: Today's meals

    private static func meal(_ id: String, _ type: MealType, _ h: Int, _ m: Int,
                             _ name: String, _ serving: String, _ cal: Int,
                             _ p: Double, _ c: Double, _ f: Double, _ fiber: Double,
                             _ method: EntryMethod) -> MealEntry {
        MealEntry(id: id, mealType: type, loggedAt: daysAgo(0, hour: h, minute: m),
                  name: name, calories: cal, proteinG: p, carbsG: c, fatG: f,
                  fiberG: fiber, servingDescription: serving, entryMethod: method,
                  photoUrl: nil, barcode: nil, foodDbId: nil, confidence: 0.9)
    }

    static let todayMeals: [MealEntry] = [
        meal("m1", .breakfast, 8, 10, "Greek yogurt bowl with berries & granola",
             "1 large bowl", 420, 32, 48, 12, 6, .photo),
        meal("m2", .lunch, 13, 5, "Grilled chicken burrito bowl",
             "1 bowl", 640, 52, 62, 20, 9, .llm),
        meal("m3", .snack, 16, 30, "Whey protein shake & banana",
             "1 shake", 300, 32, 34, 5, 3, .manual),
    ]

    static func meals(for date: Date) -> [MealEntry] {
        cal.isDateInToday(date) ? todayMeals : []
    }

    // MARK: Workout plan

    private static func ex(_ order: Int, _ name: String, _ sets: Int,
                           _ reps: String, _ notes: String) -> PlannedExercise {
        PlannedExercise(name: name, sets: sets, repRange: reps, notes: notes,
                        order: order, exerciseId: nil)
    }

    private static func warm(_ name: String, _ pres: String, _ notes: String = "") -> MobilityItem {
        MobilityItem(name: name, prescription: pres, notes: notes)
    }

    static let workoutPlan = WorkoutPlan(
        splitName: "Upper / Lower Split",
        summary: "A 4-day upper/lower rotation built for lean-mass retention on a cut — compound-led, moderate volume, progressive overload week to week.",
        scheduledWeekdays: [1, 2, 4, 5],
        days: [
            WorkoutDay(
                dayLabel: "Upper A", order: 0,
                exercises: [
                    ex(0, "Barbell Bench Press", 4, "5-8", "Leave 1-2 reps in the tank on the top sets."),
                    ex(1, "Weighted Pull-up", 4, "6-10", "Add load once you clear 10 clean reps."),
                    ex(2, "Seated Dumbbell Shoulder Press", 3, "8-12", ""),
                    ex(3, "Chest-Supported Row", 3, "10-12", "Squeeze the shoulder blades."),
                    ex(4, "Cable Lateral Raise", 3, "12-15", "Slow eccentric."),
                ],
                warmup: [warm("Arm circles", "1 min"), warm("Band pull-apart", "2 × 20")],
                cooldown: [warm("Doorway pec stretch", "30 s/side"), warm("Lat hang", "30 s")]
            ),
            WorkoutDay(
                dayLabel: "Lower A", order: 1,
                exercises: [
                    ex(0, "Barbell Back Squat", 4, "5-8", "Brace hard, controlled descent."),
                    ex(1, "Romanian Deadlift", 3, "8-10", "Feel the hamstring stretch."),
                    ex(2, "Leg Press", 3, "10-12", ""),
                    ex(3, "Seated Leg Curl", 3, "12-15", ""),
                    ex(4, "Standing Calf Raise", 4, "12-15", "Full range, pause at the bottom."),
                ],
                warmup: [warm("Bodyweight squat", "2 × 15"), warm("Leg swings", "10/side")],
                cooldown: [warm("Couch stretch", "45 s/side"), warm("Hamstring stretch", "30 s/side")]
            ),
            WorkoutDay(
                dayLabel: "Upper B", order: 2,
                exercises: [
                    ex(0, "Overhead Press", 4, "5-8", ""),
                    ex(1, "Barbell Row", 4, "6-10", ""),
                    ex(2, "Incline Dumbbell Press", 3, "8-12", ""),
                    ex(3, "Lat Pulldown", 3, "10-12", ""),
                    ex(4, "EZ-Bar Curl", 3, "10-12", "Superset with pushdowns."),
                ],
                warmup: [warm("Scapular push-up", "2 × 12"), warm("Band dislocate", "15")],
                cooldown: [warm("Cross-body shoulder stretch", "30 s/side")]
            ),
            WorkoutDay(
                dayLabel: "Lower B", order: 3,
                exercises: [
                    ex(0, "Deadlift", 3, "3-5", "Reset each rep, keep the bar close."),
                    ex(1, "Front Squat", 3, "6-8", ""),
                    ex(2, "Walking Lunge", 3, "10/leg", ""),
                    ex(3, "Leg Extension", 3, "12-15", ""),
                    ex(4, "Hanging Leg Raise", 3, "10-15", "Slow and controlled."),
                ],
                warmup: [warm("Hip airplane", "8/side"), warm("Goblet squat", "2 × 10")],
                cooldown: [warm("Child's pose", "45 s"), warm("Pigeon stretch", "45 s/side")]
            ),
        ]
    )

    // MARK: Diet plan (7-day)

    private static func fi(_ name: String, _ serving: String, _ cal: Int,
                           _ p: Double, _ c: Double, _ f: Double) -> DietFoodItem {
        DietFoodItem(name: name, servingDescription: serving, calories: cal,
                     proteinG: p, carbsG: c, fatG: f)
    }

    private static func dmeal(_ order: Int, _ label: String, _ items: [DietFoodItem]) -> DietMeal {
        DietMeal(mealLabel: label, order: order, items: items)
    }

    private static func dietDay(_ order: Int, _ day: String, _ note: String?,
                                _ breakfast: DietFoodItem, _ lunch: DietFoodItem,
                                _ snack: DietFoodItem, _ dinner: DietFoodItem) -> DietDayPlan {
        let meals = [
            dmeal(0, "Breakfast", [breakfast]),
            dmeal(1, "Lunch", [lunch]),
            dmeal(2, "Snack", [snack]),
            dmeal(3, "Dinner", [dinner]),
        ]
        let items = meals.flatMap(\.items)
        return DietDayPlan(
            day: day, order: order, meals: meals,
            dailyCalories: items.reduce(0) { $0 + $1.calories },
            proteinG: Int(items.reduce(0.0) { $0 + $1.proteinG }.rounded()),
            carbsG: Int(items.reduce(0.0) { $0 + $1.carbsG }.rounded()),
            fatG: Int(items.reduce(0.0) { $0 + $1.fatG }.rounded()),
            note: note
        )
    }

    static let dietPlan = DietPlan(
        planName: "High-Protein Cut",
        summary: "Seven days built around your 2,200 kcal / 175 g protein targets — high-protein, fiber-forward, and easy to prep.",
        dailyCalories: 2200, proteinG: 175, carbsG: 210, fatG: 65,
        meals: [],
        hydrationNote: "Aim for 3 L of water a day; add electrolytes on training days.",
        groceryList: [
            "Chicken breast (1 kg)", "Salmon fillets (4)", "Eggs (18)",
            "Greek yogurt (1 kg)", "Rolled oats", "Mixed berries",
            "Brown rice", "Sweet potatoes", "Broccoli & spinach",
            "Almonds", "Olive oil", "Whey protein",
        ],
        notes: "Swap any protein for a like-for-like source you prefer. Keep the veggies uncapped.",
        days: [
            dietDay(0, "Monday", "Training day — extra carbs around your session.",
                    fi("Oatmeal, whey & blueberries", "1 bowl", 430, 35, 55, 9),
                    fi("Chicken, rice & broccoli", "1 plate", 620, 55, 65, 15),
                    fi("Greek yogurt & almonds", "1 cup", 280, 25, 18, 12),
                    fi("Salmon, sweet potato & spinach", "1 plate", 620, 45, 48, 26)),
            dietDay(1, "Tuesday", nil,
                    fi("Veggie omelette (3 eggs) & toast", "1 plate", 420, 30, 32, 20),
                    fi("Turkey & avocado wrap", "1 wrap", 560, 42, 52, 20),
                    fi("Protein shake & apple", "1 shake", 260, 28, 30, 4),
                    fi("Beef stir-fry with rice", "1 bowl", 640, 48, 60, 22)),
            dietDay(2, "Wednesday", "Rest day — slightly lower carbs.",
                    fi("Greek yogurt, granola & berries", "1 bowl", 400, 32, 46, 10),
                    fi("Tuna & quinoa salad", "1 bowl", 540, 45, 42, 20),
                    fi("Cottage cheese & pineapple", "1 cup", 240, 26, 20, 5),
                    fi("Grilled chicken & roast veg", "1 plate", 560, 52, 38, 20)),
            dietDay(3, "Thursday", "Training day — extra carbs around your session.",
                    fi("Overnight oats & peanut butter", "1 jar", 440, 30, 52, 14),
                    fi("Chicken burrito bowl", "1 bowl", 640, 52, 62, 20),
                    fi("Whey shake & banana", "1 shake", 300, 32, 34, 5),
                    fi("Lean beef, potato & greens", "1 plate", 600, 48, 52, 20)),
            dietDay(4, "Friday", nil,
                    fi("Scrambled eggs & smoked salmon", "1 plate", 440, 34, 12, 28),
                    fi("Chicken Caesar (light) wrap", "1 wrap", 560, 44, 46, 22),
                    fi("Protein bar", "1 bar", 220, 20, 24, 7),
                    fi("Shrimp stir-fry with noodles", "1 bowl", 580, 42, 62, 16)),
            dietDay(5, "Saturday", "Higher-carb refeed to support training.",
                    fi("Protein pancakes & berries", "3 pancakes", 480, 36, 58, 12),
                    fi("Sushi & edamame", "10 pcs", 600, 40, 78, 14),
                    fi("Greek yogurt & honey", "1 cup", 260, 24, 28, 6),
                    fi("Steak, rice & asparagus", "1 plate", 620, 50, 55, 22)),
            dietDay(6, "Sunday", "Meal-prep day — cook once, eat twice.",
                    fi("Veggie & feta frittata", "2 slices", 420, 30, 20, 26),
                    fi("Chicken pesto pasta", "1 bowl", 620, 48, 66, 18),
                    fi("Rice cakes & cottage cheese", "2 cakes", 240, 22, 26, 5),
                    fi("Baked cod, potatoes & peas", "1 plate", 540, 46, 50, 16)),
        ]
    )

    // MARK: Progress data — weight, day rollups, sessions

    static let weights: [WeightEntry] = (0...30).reversed().map { d in
        let t = Double(30 - d)                 // 0 (oldest) → 30 (today)
        let base = 81.6 - t * 0.076            // ~2.3 kg trend over the month
        let noise = sin(Double(d) * 1.27) * 0.28
        let kg = (base + noise * 0.6)
        return WeightEntry(id: "w\(d)", date: daysAgo(d, hour: 7),
                           weightKg: (kg * 10).rounded() / 10, source: "manual", note: nil)
    }

    static let dayLogs: [DayLog] = (0...29).map { d in
        let cals = 2180 + Int(sin(Double(d) * 0.85) * 190)
        let protein = 168.0 + sin(Double(d) * 1.1) * 14
        let carbs = 205.0 + sin(Double(d) * 0.7) * 25
        let fat = 63.0 + cos(Double(d) * 0.9) * 8
        return DayLog(date: daysAgo(d), totalCalories: cals,
                      totalProteinG: protein, totalCarbsG: carbs, totalFatG: fat,
                      steps: 7000 + (d * 137) % 4500,
                      activeEnergyKcal: 380 + (d * 53) % 260,
                      exerciseMinutes: 25 + (d * 7) % 40)
    }

    static let sessions: [WorkoutSession] = {
        var out: [WorkoutSession] = []
        let labels = ["Upper A", "Lower A", "Upper B", "Lower B"]
        var idx = 0
        for d in stride(from: 27, through: 0, by: -1) {
            let date = daysAgo(d, hour: 18)
            let weekday = cal.component(.weekday, from: date) - 1  // 0=Sun
            guard [1, 2, 4, 5].contains(weekday) else { continue }
            let label = labels[idx % labels.count]
            let weeks = Double(idx) / 4.0                          // ~progress over time
            out.append(WorkoutSession(id: "s\(d)", date: date, dayLabel: label,
                                      loggedSets: sets(for: label, weeks: weeks), note: nil))
            idx += 1
        }
        return out
    }()

    /// Progressive-overload sets for a session, ramping weight with the week index.
    private static func sets(for label: String, weeks: Double) -> [LoggedSet] {
        func lift(_ name: String, base: Double, step: Double, reps: Int, count: Int) -> [LoggedSet] {
            let w = (base + (weeks * step)).rounded()
            return (0..<count).map { i in
                LoggedSet(exerciseId: nil, exerciseName: name, weightKg: w, reps: reps, rpe: nil, setIndex: i)
            }
        }
        switch label {
        case "Upper A":
            return lift("Barbell Bench Press", base: 72, step: 1.6, reps: 6, count: 4)
                 + lift("Seated Dumbbell Shoulder Press", base: 24, step: 0.6, reps: 10, count: 3)
        case "Lower A":
            return lift("Barbell Back Squat", base: 100, step: 2.4, reps: 6, count: 4)
                 + lift("Romanian Deadlift", base: 90, step: 1.8, reps: 9, count: 3)
        case "Upper B":
            return lift("Overhead Press", base: 48, step: 1.0, reps: 6, count: 4)
                 + lift("Barbell Row", base: 78, step: 1.4, reps: 8, count: 4)
        default: // Lower B
            return lift("Deadlift", base: 130, step: 2.6, reps: 4, count: 3)
                 + lift("Front Squat", base: 78, step: 1.4, reps: 7, count: 3)
        }
    }

    static func lastSets(named name: String) -> [LoggedSet] {
        for session in sessions.sorted(by: { $0.date > $1.date }) {
            let m = session.loggedSets.filter { $0.exerciseName == name }.sorted { $0.setIndex < $1.setIndex }
            if !m.isEmpty { return m }
        }
        return []
    }

    // MARK: Reminders

    static let reminders: [SupplementReminder] = [
        SupplementReminder(id: "r1", name: "Creatine", dosage: "5 g", kind: .supplement,
                           times: [ReminderTime(hour: 8, minute: 0)], weekdays: [],
                           enabled: true, createdAt: daysAgo(20)),
        SupplementReminder(id: "r2", name: "Vitamin D3", dosage: "1 softgel", kind: .supplement,
                           times: [ReminderTime(hour: 9, minute: 0)], weekdays: [],
                           enabled: true, createdAt: daysAgo(18)),
        SupplementReminder(id: "r3", name: "Omega-3", dosage: "2 capsules", kind: .supplement,
                           times: [ReminderTime(hour: 9, minute: 0), ReminderTime(hour: 21, minute: 0)],
                           weekdays: [], enabled: true, createdAt: daysAgo(12)),
    ]
}
