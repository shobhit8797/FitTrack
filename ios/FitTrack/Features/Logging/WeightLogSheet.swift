import SwiftUI

// Weight logging (spec §7.4): weight + editable date + note → WeightEntry.
// The value is a big, directly-editable number with ± nudge buttons (a 0.1-step
// stepper from 70 kg was hostile). Prefills from the most recent entry (or the
// profile) so most logs are one small adjustment away. Optional HealthKit
// write-back behind a toggle.
struct WeightLogSheet: View {
    @Environment(Repository.self) private var repo
    @Environment(HealthKitService.self) private var health
    @Environment(\.dismiss) private var dismiss
    @State private var weightKg = 70.0
    @State private var date = Date()
    @State private var note = ""
    @State private var writeToHealth = false
    @State private var error: String?
    @State private var prefilled = false
    @FocusState private var weightFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    weightEntry
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Note (optional)", text: $note)
                }
                Section {
                    Toggle("Also save to Apple Health", isOn: $writeToHealth)
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            }
            .selectAllOnFocus()
            .navigationTitle("Log weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Haptics.tap()
                        Task { await save() }
                    }
                    .fontWeight(.semibold)
                }
            }
            .task { await prefill() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// Big editable number flanked by −/＋ 0.1 kg nudges.
    private var weightEntry: some View {
        HStack(spacing: Theme.Spacing.l) {
            nudgeButton("minus", accessibilityLabel: "Decrease weight") {
                weightKg = max(30, (weightKg - 0.1).rounded(toPlaces: 1))
            }

            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                TextField("0", value: $weightKg, format: .number.precision(.fractionLength(1)))
                    .keyboardType(.decimalPad)
                    .focused($weightFocused)
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .fixedSize()
                Text("kg")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { weightFocused = true }

            nudgeButton("plus", accessibilityLabel: "Increase weight") {
                weightKg = min(300, (weightKg + 0.1).rounded(toPlaces: 1))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.m)
        .accessibilityElement(children: .contain)
    }

    private func nudgeButton(_ icon: String, accessibilityLabel: String,
                             action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.accentTeal)
                .frame(width: Theme.minTapTarget, height: Theme.minTapTarget)
                .background(Theme.accentTeal.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Seed from the latest logged weight, falling back to the profile weight.
    private func prefill() async {
        guard !prefilled else { return }
        do {
            for try await entries in repo.weightStream() {
                if !prefilled, let latest = entries.max(by: { $0.date < $1.date }) {
                    weightKg = latest.weightKg
                }
                prefilled = true
                return
            }
        } catch {}
        if !prefilled, let profile = try? await repo.fetchProfile() {
            weightKg = profile.weightKg
        }
        prefilled = true
    }

    private func save() async {
        do {
            try await repo.addWeight(WeightEntry(
                id: "", date: date, weightKg: weightKg, source: "manual",
                note: note.isEmpty ? nil : note
            ))
            if writeToHealth { try? await health.writeBodyMass(kg: weightKg, date: date) }
            Haptics.success()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
