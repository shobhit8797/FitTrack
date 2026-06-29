import SwiftUI

// Weight logging (spec §7.4): weight + editable date + note → WeightEntry.
// Optional HealthKit write-back behind a toggle.
struct WeightLogSheet: View {
    @Environment(Repository.self) private var repo
    @Environment(HealthKitService.self) private var health
    @Environment(\.dismiss) private var dismiss
    @State private var weightKg = 70.0
    @State private var date = Date()
    @State private var note = ""
    @State private var writeToHealth = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("\(weightKg, specifier: "%.1f") kg", value: $weightKg, in: 30...300, step: 0.1)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Note (optional)", text: $note)
                }
                Section {
                    Toggle("Also save to Apple Health", isOn: $writeToHealth)
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            }
            .navigationTitle("Log weight")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                }
            }
        }
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
