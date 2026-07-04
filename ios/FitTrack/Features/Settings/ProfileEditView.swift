import SwiftUI

// Edit an existing profile from Settings (spec §5–6). Reuses OnboardingDraft as
// the editable model + payload builder, so the field set and the server contract
// stay identical to onboarding. Saving calls updateProfile, which recomputes
// deterministic targets server-side — the app never invents targets locally.
//
// Editing stats, goal, or the weekly rate changes the calorie/macro targets
// immediately, but does NOT regenerate the workout/diet plans: those are
// explicit actions in Settings, so the user stays in control of when the coach
// re-runs. We nudge them toward it after a save that likely moved the numbers.
struct ProfileEditView: View {
    @Environment(Repository.self) private var repo
    @Environment(FunctionsClient.self) private var functions
    @Environment(\.dismiss) private var dismiss

    @State private var draft = OnboardingDraft()
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?
    @State private var savedTargets: Targets?

    var body: some View {
        Form {
            if loaded {
                aboutSection
                bodySection
                goalSection
                trainingSection
                dietSection
                contextSection
                if let savedTargets {
                    savedSection(savedTargets)
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).font(.caption)
                    }
                }
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .tint(Theme.accentTeal)
        .navigationTitle("Edit profile")
        .navigationBarTitleDisplayMode(.inline)
        .selectAllOnFocus()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .fontWeight(.semibold)
                    .disabled(!loaded || saving)
            }
        }
        .overlay {
            if saving {
                Color.black.opacity(0.06).ignoresSafeArea()
                ProgressView("Saving…")
                    .padding(Theme.Spacing.ml)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .task {
            guard !loaded else { return }
            if let profile = try? await repo.fetchProfile() {
                draft = OnboardingDraft(profile: profile)
            }
            loaded = true
        }
    }

    // MARK: Sections

    private var aboutSection: some View {
        Section("About you") {
            TextField("Your name", text: $draft.displayName)
            Picker("Sex (for BMR)", selection: $draft.sex) {
                ForEach(Sex.allCases) { Text($0.label).tag($0) }
            }
            DatePicker("Birth date", selection: $draft.birthDate, displayedComponents: .date)
        }
    }

    private var bodySection: some View {
        Section("Body") {
            LabeledContent("Height") {
                numberField($draft.heightCm, unit: "cm", decimals: 0, keyboard: .numberPad)
            }
            LabeledContent("Weight") {
                numberField($draft.weightKg, unit: "kg", decimals: 1, keyboard: .decimalPad)
            }
            Picker("Activity level", selection: $draft.activityLevel) {
                ForEach(ActivityLevel.allCases) { Text($0.label).tag($0) }
            }
        }
    }

    private var goalSection: some View {
        Section("Goal") {
            Picker("Goal", selection: $draft.goal) {
                ForEach(Goal.allCases) { Text($0.label).tag($0) }
            }
            if draft.goal.usesWeeklyRate {
                WeeklyRatePicker(goal: draft.goal, rateKg: $draft.weeklyWeightChangeKg)
                    .padding(.vertical, Theme.Spacing.xs)
            }
            TextField("Describe your goal (optional)", text: $draft.goalFreeText, axis: .vertical)
                .lineLimit(2...4)
        }
    }

    private var trainingSection: some View {
        Section("Training") {
            Stepper("Train \(draft.trainingDaysPerWeek)×/week", value: $draft.trainingDaysPerWeek, in: 1...7)
            WeekdayPicker(selected: $draft.preferredWeekdays)
            Picker("Experience", selection: $draft.experience) {
                ForEach(["beginner", "intermediate", "advanced"], id: \.self) { Text($0.capitalized).tag($0) }
            }
            Picker("Where do you train?", selection: $draft.trainingEnvironment) {
                ForEach(TrainingEnvironment.allCases) { Text($0.label).tag($0) }
            }
        }
    }

    private var dietSection: some View {
        Section("Diet") {
            Picker("Diet type", selection: $draft.dietType) {
                ForEach(["vegetarian", "veg + egg", "vegan", "non-veg"], id: \.self) { Text($0.capitalized).tag($0) }
            }
            TextField("Restrictions / allergies (comma-separated)", text: $draft.restrictionsText)
        }
    }

    private var contextSection: some View {
        Section {
            TextField("Injuries or limitations", text: $draft.injuriesNotes, axis: .vertical).lineLimit(2...4)
            TextField("Anything else for your coach", text: $draft.freeFormContext, axis: .vertical).lineLimit(3...8)
        } header: {
            Text("Context")
        } footer: {
            Text("Saving updates your calorie and macro targets. Regenerate your workout or diet plan from Settings to have your coach use the new profile.")
        }
    }

    private func savedSection(_ t: Targets) -> some View {
        Section("Updated targets") {
            LabeledContent("Calories", value: "\(t.calorieTarget) kcal")
            LabeledContent("Protein", value: "\(t.proteinTargetG) g")
            LabeledContent("Carbs", value: "\(t.carbTargetG) g")
            LabeledContent("Fat", value: "\(t.fatTargetG) g")
        }
    }

    // MARK: Helpers

    private func numberField(
        _ value: Binding<Double>, unit: String, decimals: Int, keyboard: UIKeyboardType
    ) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            TextField(unit, value: value, format: .number.precision(.fractionLength(decimals)))
                .keyboardType(keyboard)
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
                .font(.body.weight(.semibold).monospacedDigit())
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private func save() async {
        error = nil
        saving = true
        defer { saving = false }
        do {
            let targets = try await functions.updateProfile(profile: draft.payload)
            savedTargets = targets
            Haptics.success()
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
        }
    }
}
