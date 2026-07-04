import SwiftUI

// Per-user onboarding (spec §4). Collects this user's inputs + a free-text box,
// then calls completeOnboarding which saves the profile and computes targets (§5)
// immediately. The workout plan (§11.1) is generated asynchronously server-side
// after this returns, so onboarding never blocks on the LLM — the user routes
// straight to the home screen and the plan lands later (planStatus). No app-wide
// defaults are ever applied.
struct OnboardingFlow: View {
    let existingProfile: UserProfile?
    @Environment(FunctionsClient.self) private var functions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0
    @State private var draft = OnboardingDraft()
    @State private var submitting = false
    @State private var error: String?

    private let steps = ["About you", "Body", "Goal", "Training", "Diet", "Anything else"]
    private let stepSubtitles = [
        "Tell us a little about yourself.",
        "Your measurements help us set accurate targets.",
        "What are you working towards?",
        "How and where do you like to train?",
        "How you eat shapes your meal plan.",
        "Anything the coach should know before we build your plan.",
    ]

    private var isLastStep: Bool { step == steps.count - 1 }

    /// Spring used for advancing/retreating between steps; crossfade-only when
    /// Reduce Motion is on (no large horizontal slide).
    private var stepAnimation: Animation? {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.82)
    }

    private func go(to newStep: Int) {
        Haptics.selection()
        withAnimation(stepAnimation) { step = newStep }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progressHeader

                TabView(selection: $step) {
                    aboutStep.tag(0)
                    bodyStep.tag(1)
                    goalStep.tag(2)
                    trainingStep.tag(3)
                    dietStep.tag(4)
                    contextStep.tag(5)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(stepAnimation, value: step)

                footer
            }
            .navigationTitle("Set up FitTrack")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: Chrome

    /// Step counter + branded progress bar + a large, friendly title/subtitle for
    /// the current step. Gives a clear sense of "where am I" through the flow.
    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Step \(step + 1) of \(steps.count)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.accentTeal)
                .contentTransition(.numericText())

            ProgressView(value: Double(step + 1), total: Double(steps.count))
                .tint(Theme.accentTeal)

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(steps[step])
                    .font(.title.weight(.bold))
                    .contentTransition(.opacity)
                Text(stepSubtitles[step])
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.ml)
        .padding(.top, Theme.Spacing.s)
        .padding(.bottom, Theme.Spacing.sm)
    }

    /// Bottom action bar: recoverable error, then a single obvious primary CTA
    /// (Next / Generate my plan) plus an unobtrusive Back.
    private var footer: some View {
        VStack(spacing: Theme.Spacing.sm) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }

            if isLastStep {
                Button {
                    // Flip submitting synchronously here (not inside the
                    // async submit) so a fast double-tap is rejected before
                    // a second Task spawns — otherwise both fire
                    // completeOnboarding and GTMSessionFetcher warns the
                    // request "was already running".
                    guard !submitting else { return }
                    Haptics.tap()
                    submitting = true
                    Task { await submit() }
                } label: {
                    if submitting {
                        HStack(spacing: Theme.Spacing.s) {
                            ProgressView().tint(.white)
                            Text("Building your plan…")
                        }
                    } else {
                        Label("Generate my plan", systemImage: "sparkles")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(enabled: !submitting))
                .disabled(submitting)
                .accessibilityLabel(submitting ? "Building your plan" : "Generate my plan")
            } else {
                Button {
                    go(to: step + 1)
                } label: {
                    Text("Next")
                }
                .buttonStyle(PrimaryButtonStyle())
            }

            if step > 0 {
                Button("Back") { go(to: step - 1) }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: Theme.minTapTarget)
                    .disabled(submitting)
                    .accessibilityHint("Return to \(steps[step - 1])")
            }
        }
        .padding(.horizontal, Theme.Spacing.ml)
        .padding(.top, Theme.Spacing.sm)
        .padding(.bottom, Theme.Spacing.s)
        .animation(stepAnimation, value: error)
    }

    // MARK: Steps
    private var aboutStep: some View {
        Form {
            TextField("Your name", text: $draft.displayName)
            Picker("Sex (for BMR)", selection: $draft.sex) {
                ForEach(Sex.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            DatePicker("Birth date", selection: $draft.birthDate, displayedComponents: .date)
        }
    }

    private var bodyStep: some View {
        Form {
            // Direct numeric entry — steppers were painful for values this size.
            LabeledContent("Height") {
                HStack(spacing: Theme.Spacing.xs) {
                    TextField("cm", value: $draft.heightCm, format: .number.precision(.fractionLength(0)))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                        .font(.body.weight(.semibold).monospacedDigit())
                    Text("cm").foregroundStyle(.secondary)
                }
            }
            LabeledContent("Weight") {
                HStack(spacing: Theme.Spacing.xs) {
                    TextField("kg", value: $draft.weightKg, format: .number.precision(.fractionLength(1)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                        .font(.body.weight(.semibold).monospacedDigit())
                    Text("kg").foregroundStyle(.secondary)
                }
            }
            Picker("Activity level", selection: $draft.activityLevel) {
                ForEach(ActivityLevel.allCases) { Text($0.label).tag($0) }
            }
        }
        .selectAllOnFocus()
    }

    private var goalStep: some View {
        Form {
            Section {
                ForEach(Goal.allCases) { goal in
                    let selected = draft.goal == goal
                    Button {
                        Haptics.selection()
                        draft.goal = goal
                    } label: {
                        HStack(spacing: Theme.Spacing.sm) {
                            IconBadge(systemImage: goal.icon,
                                      color: selected ? Theme.accentTeal : .secondary, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(goal.label).foregroundStyle(.primary)
                                Text(goal.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.accentTeal)
                                .opacity(selected ? 1 : 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .tint(.primary)
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityHint(goal.detail)
                }
            }
            if draft.goal.usesWeeklyRate {
                Section("How fast?") {
                    WeeklyRatePicker(goal: draft.goal, rateKg: $draft.weeklyWeightChangeKg)
                }
            }
            Section("What are you looking for?") {
                TextField("Optional: describe in your words", text: $draft.goalFreeText, axis: .vertical)
                    .lineLimit(2...4)
            }
        }
    }

    private var trainingStep: some View {
        Form {
            Stepper("Train \(draft.trainingDaysPerWeek)×/week", value: $draft.trainingDaysPerWeek, in: 1...7)
            Section("Preferred days") {
                WeekdayPicker(selected: $draft.preferredWeekdays)
            }
            Picker("Experience", selection: $draft.experience) {
                ForEach(["beginner", "intermediate", "advanced"], id: \.self) { Text($0.capitalized).tag($0) }
            }
            Section("Where do you train?") {
                ForEach(TrainingEnvironment.allCases) { env in
                    let selected = draft.trainingEnvironment == env
                    Button {
                        Haptics.selection()
                        draft.trainingEnvironment = env
                    } label: {
                        HStack(spacing: Theme.Spacing.sm) {
                            Image(systemName: env.icon)
                                .font(.body)
                                .foregroundStyle(Theme.accentTeal)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(env.label).foregroundStyle(.primary)
                                Text(env.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.accentTeal)
                                .opacity(selected ? 1 : 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .tint(.primary)
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityHint(env.detail)
                }
            }
        }
    }

    private var dietStep: some View {
        Form {
            Picker("Diet type", selection: $draft.dietType) {
                ForEach(["vegetarian", "veg + egg", "vegan", "non-veg"], id: \.self) { Text($0.capitalized).tag($0) }
            }
            Section("Restrictions / allergies") {
                TextField("e.g. lactose, nuts", text: $draft.restrictionsText)
            }
        }
    }

    private var contextStep: some View {
        Form {
            Section("Injuries or limitations") {
                TextField("Optional", text: $draft.injuriesNotes, axis: .vertical).lineLimit(2...4)
            }
            Section("Anything else about your plan, preferences, or constraints?") {
                TextField("Paste an existing plan or any context — fed to the coach verbatim.",
                          text: $draft.freeFormContext, axis: .vertical)
                    .lineLimit(4...10)
            }
            Section {
                Text("Targets and your plan are generated from these inputs. Not medical advice.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func submit() async {
        // submitting is set by the button tap (synchronously) to dedupe taps.
        error = nil
        defer { submitting = false }
        do {
            _ = try await functions.completeOnboarding(profile: draft.payload)
            // RootView's profile listener will pick up the new targets and route on.
            Haptics.success()
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
        }
    }
}

/// Mutable draft collected across steps, serialized to the Cloud Function payload.
struct OnboardingDraft {
    var displayName = ""
    var sex: Sex = .male
    var birthDate = Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date()
    var heightCm: Double = 170
    var weightKg: Double = 70
    var activityLevel: ActivityLevel = .moderate
    var goal: Goal = .recomp {
        // Keep the rate valid for the chosen goal: seed a default when switching
        // into a rate-bearing goal, clear it otherwise.
        didSet {
            guard goal != oldValue else { return }
            weeklyWeightChangeKg = goal.usesWeeklyRate ? goal.defaultWeeklyRate : 0
        }
    }
    var goalFreeText = ""
    /// Target weekly weight-change magnitude (kg). 0 unless the goal uses a rate.
    var weeklyWeightChangeKg: Double = Goal.recomp.defaultWeeklyRate
    var trainingDaysPerWeek = 4
    var preferredWeekdays: Set<Int> = [1, 2, 4, 5]
    var experience = "intermediate"
    var trainingEnvironment: TrainingEnvironment = .gym
    var dietType = "vegetarian"
    var restrictionsText = ""
    var injuriesNotes = ""
    var freeFormContext = ""

    init() {}

    /// Seed the draft from an existing profile so Settings can edit it in place.
    init(profile p: UserProfile) {
        displayName = p.displayName
        sex = p.sex
        birthDate = p.birthDate
        heightCm = p.heightCm
        weightKg = p.weightKg
        activityLevel = p.activityLevel
        goalFreeText = p.goalFreeText ?? ""
        trainingDaysPerWeek = p.trainingDaysPerWeek
        preferredWeekdays = Set(p.preferredWeekdays)
        experience = p.experience
        trainingEnvironment = TrainingEnvironment.matching(p.equipment)
        dietType = p.dietType
        restrictionsText = p.dietaryRestrictions.joined(separator: ", ")
        injuriesNotes = p.injuriesNotes
        freeFormContext = p.freeFormContext
        goal = p.goal // didSet doesn't fire during init, so the stored rate below wins
        weeklyWeightChangeKg = p.weeklyWeightChangeKg ?? (p.goal.usesWeeklyRate ? p.goal.defaultWeeklyRate : 0)
    }

    var payload: [String: Any] {
        let iso = ISO8601DateFormatter().string(from: birthDate)
        var body: [String: Any] = [
            "displayName": displayName,
            "sex": sex.rawValue,
            "birthDate": iso,
            "heightCm": heightCm,
            "weightKg": weightKg,
            "activityLevel": activityLevel.rawValue,
            "goal": goal.rawValue,
            "goalFreeText": goalFreeText,
            "dietType": dietType,
            "dietaryRestrictions": restrictionsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            "trainingDaysPerWeek": trainingDaysPerWeek,
            "preferredWeekdays": Array(preferredWeekdays).sorted(),
            "experience": experience,
            "equipment": trainingEnvironment.equipment,
            "injuriesNotes": injuriesNotes,
            "freeFormContext": freeFormContext,
        ]
        // Only send a rate for goals that use one; the backend keys off its
        // presence, and sending 0 for maintain/recomp would be meaningless.
        if goal.usesWeeklyRate, weeklyWeightChangeKg > 0 {
            body["weeklyWeightChangeKg"] = weeklyWeightChangeKg
        }
        return body
    }
}

struct WeekdayPicker: View {
    @Binding var selected: Set<Int>
    private let labels = ["S", "M", "T", "W", "T", "F", "S"]
    private let fullNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    var body: some View {
        HStack {
            ForEach(0..<7, id: \.self) { i in
                let on = selected.contains(i)
                Button(labels[i]) {
                    Haptics.selection()
                    if on { selected.remove(i) } else { selected.insert(i) }
                }
                .font(.subheadline.weight(.semibold))
                .frame(width: Theme.minTapTarget, height: Theme.minTapTarget)
                .background(on ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.secondary.opacity(0.15)), in: Circle())
                .foregroundStyle(on ? .white : .primary)
                .buttonStyle(.plain)
                .accessibilityLabel(fullNames[i])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Icon + one-line description per goal, so the choice reads as cards rather
/// than a bare radio list.
private extension Goal {
    var icon: String {
        switch self {
        case .fatLoss: "flame.fill"
        case .recomp: "arrow.triangle.2.circlepath"
        case .muscleGain: "dumbbell.fill"
        case .maintain: "equal.circle.fill"
        }
    }

    var detail: String {
        switch self {
        case .fatLoss: "Drop fat while keeping muscle"
        case .recomp: "Trade fat for muscle at a steady weight"
        case .muscleGain: "Build size and strength"
        case .maintain: "Hold where you are, eat to support it"
        }
    }
}

/// How the user trains, asked instead of a raw equipment checklist (friendlier,
/// and most people think in terms of *where* they train, not which bars they own).
/// Each case maps to the equipment tags the exercise catalog + plan prompt understand.
enum TrainingEnvironment: String, CaseIterable, Identifiable {
    case gym, homeGym, minimal, calisthenics
    var id: String { rawValue }

    var label: String {
        switch self {
        case .gym: "Full gym"
        case .homeGym: "Home gym"
        case .minimal: "Just the basics at home"
        case .calisthenics: "Calisthenics"
        }
    }

    var detail: String {
        switch self {
        case .gym: "Barbells, machines, cables — the works"
        case .homeGym: "Barbell, dumbbells & bands at home"
        case .minimal: "A few dumbbells or bands, plus bodyweight"
        case .calisthenics: "Bodyweight and a pull-up bar only"
        }
    }

    var icon: String {
        switch self {
        case .gym: "dumbbell.fill"
        case .homeGym: "house.fill"
        case .minimal: "figure.strengthtraining.traditional"
        case .calisthenics: "figure.gymnastics"
        }
    }

    /// Equipment tags sent to the backend (must match exercises.data equipment values).
    var equipment: [String] {
        switch self {
        case .gym: ["Barbell", "Dumbbell", "Machine", "Cable", "Bodyweight", "Bands"]
        case .homeGym: ["Barbell", "Dumbbell", "Bands", "Bodyweight"]
        case .minimal: ["Dumbbell", "Bands", "Bodyweight"]
        case .calisthenics: ["Bodyweight", "Bands"]
        }
    }

    /// Best-fit environment for a stored equipment list, so editing an existing
    /// profile pre-selects the right card. Matches the case whose equipment set
    /// equals the stored one, else falls back to full gym.
    static func matching(_ equipment: [String]) -> TrainingEnvironment {
        let stored = Set(equipment)
        return allCases.first { Set($0.equipment) == stored } ?? .gym
    }
}

/// Reusable control for choosing a target weekly weight-change pace. Renders as a
/// segmented picker of the goal's presets with a plain-language caption
/// underneath. Shown only for goals that move weight (fat-loss / muscle-gain).
struct WeeklyRatePicker: View {
    let goal: Goal
    @Binding var rateKg: Double

    private var presets: [Double] { goal.weeklyRatePresets }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Picker("Weekly pace", selection: $rateKg) {
                ForEach(presets, id: \.self) { kg in
                    Text(format(kg)).tag(kg)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: rateKg) { _, _ in Haptics.selection() }

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// e.g. "0.5 kg". Trims a trailing ".0" so 1.0 reads as "1".
    private func format(_ kg: Double) -> String {
        let s = String(format: "%.3f", kg)
        var trimmed = s
        while trimmed.hasSuffix("0") { trimmed.removeLast() }
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        return "\(trimmed) kg"
    }

    private var caption: String {
        let perMonth = rateKg * 4.345
        return "\(goal.weeklyRateName(rateKg)) — \(goal.rateVerb) about "
            + "\(format(rateKg))/week (~\(String(format: "%.1f", perMonth)) kg/month). "
            + "Sets your calorie target."
    }
}
