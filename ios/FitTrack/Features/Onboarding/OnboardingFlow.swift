import SwiftUI

// Per-user onboarding (spec §4). Collects this user's inputs + a free-text box,
// then calls completeOnboarding which computes targets (§5) and generates a plan
// (§11.1) server-side. No app-wide defaults are ever applied.
struct OnboardingFlow: View {
    let existingProfile: UserProfile?
    @Environment(FunctionsClient.self) private var functions
    @State private var step = 0
    @State private var draft = OnboardingDraft()
    @State private var submitting = false
    @State private var error: String?

    private let steps = ["About you", "Body", "Goal", "Training", "Diet", "Anything else"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProgressView(value: Double(step + 1), total: Double(steps.count))
                    .tint(Theme.accentTeal)
                    .padding(.horizontal)

                TabView(selection: $step) {
                    aboutStep.tag(0)
                    bodyStep.tag(1)
                    goalStep.tag(2)
                    trainingStep.tag(3)
                    dietStep.tag(4)
                    contextStep.tag(5)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.default, value: step)

                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
                }

                HStack {
                    if step > 0 {
                        Button("Back") { step -= 1 }.buttonStyle(.bordered)
                    }
                    Spacer()
                    if step < steps.count - 1 {
                        Button("Next") { step += 1 }
                            .buttonStyle(.borderedProminent).tint(Theme.accentTeal)
                    } else {
                        Button(submitting ? "Building your plan…" : "Generate my plan") {
                            Task { await submit() }
                        }
                        .buttonStyle(.borderedProminent).tint(Theme.accentTeal)
                        .disabled(submitting)
                    }
                }
                .padding()
            }
            .navigationTitle(steps[step])
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: Steps
    private var aboutStep: some View {
        Form {
            TextField("Your name", text: $draft.displayName)
            Picker("Sex (for BMR)", selection: $draft.sex) {
                ForEach(Sex.allCases) { Text($0.label).tag($0) }
            }
            DatePicker("Birth date", selection: $draft.birthDate, displayedComponents: .date)
        }
    }

    private var bodyStep: some View {
        Form {
            Stepper("Height: \(Int(draft.heightCm)) cm", value: $draft.heightCm, in: 120...230)
            Stepper("Weight: \(draft.weightKg, specifier: "%.1f") kg", value: $draft.weightKg, in: 35...250, step: 0.5)
            Picker("Activity level", selection: $draft.activityLevel) {
                ForEach(ActivityLevel.allCases) { Text($0.label).tag($0) }
            }
        }
    }

    private var goalStep: some View {
        Form {
            Picker("Goal", selection: $draft.goal) {
                ForEach(Goal.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
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
            Section("Equipment") {
                MultiToggle(options: ["Barbell", "Dumbbell", "Machine", "Cable", "Bodyweight", "Bands"],
                            selected: $draft.equipment)
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
        submitting = true; error = nil
        defer { submitting = false }
        do {
            _ = try await functions.completeOnboarding(profile: draft.payload)
            // RootView's profile listener will pick up the new targets and route on.
        } catch {
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
    var goal: Goal = .recomp
    var goalFreeText = ""
    var trainingDaysPerWeek = 4
    var preferredWeekdays: Set<Int> = [1, 2, 4, 5]
    var experience = "intermediate"
    var equipment: Set<String> = ["Barbell", "Dumbbell"]
    var dietType = "vegetarian"
    var restrictionsText = ""
    var injuriesNotes = ""
    var freeFormContext = ""

    var payload: [String: Any] {
        let iso = ISO8601DateFormatter().string(from: birthDate)
        return [
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
            "equipment": Array(equipment),
            "injuriesNotes": injuriesNotes,
            "freeFormContext": freeFormContext,
        ]
    }
}

struct WeekdayPicker: View {
    @Binding var selected: Set<Int>
    private let labels = ["S", "M", "T", "W", "T", "F", "S"]
    var body: some View {
        HStack {
            ForEach(0..<7, id: \.self) { i in
                let on = selected.contains(i)
                Button(labels[i]) {
                    if on { selected.remove(i) } else { selected.insert(i) }
                }
                .frame(width: 38, height: 38)
                .background(on ? Theme.accentTeal : Color.secondary.opacity(0.15), in: Circle())
                .foregroundStyle(on ? .white : .primary)
            }
        }
    }
}

struct MultiToggle: View {
    let options: [String]
    @Binding var selected: Set<String>
    var body: some View {
        ForEach(options, id: \.self) { opt in
            Button {
                if selected.contains(opt) { selected.remove(opt) } else { selected.insert(opt) }
            } label: {
                HStack {
                    Text(opt)
                    Spacer()
                    if selected.contains(opt) {
                        Image(systemName: "checkmark").foregroundStyle(Theme.accentTeal)
                    }
                }
            }
            .tint(.primary)
        }
    }
}
