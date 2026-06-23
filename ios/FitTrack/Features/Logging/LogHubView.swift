import SwiftUI

// Log hub (spec §8): the ➕ entry point — photo / barcode / manual / weight.
// AI/DB estimates always land in an editable confirmation sheet (§7.3) — never
// auto-saved.
struct LogHubView: View {
    @State private var route: LogRoute?

    var body: some View {
        NavigationStack {
            List {
                Section("Food") {
                    row("camera.fill", "Photo", "Snap a meal — AI estimates macros") { route = .photo }
                    row("barcode.viewfinder", "Barcode", "Scan a packaged product") { route = .barcode }
                    row("text.viewfinder", "Label", "Photograph a nutrition label") { route = .label }
                    row("pencil", "Describe / manual", "Type what you ate") { route = .text }
                }
                Section("Body") {
                    row("scalemass.fill", "Weight", "Log today's weight") { route = .weight }
                }
            }
            .navigationTitle("Log")
            .sheet(item: $route) { route in
                switch route {
                case .text:    MealTextEntrySheet()
                case .weight:  WeightLogSheet()
                case .photo:   MealPhotoEntrySheet()
                case .barcode: BarcodeEntrySheet()
                case .label:   LabelEntrySheet()
                }
            }
        }
    }

    private func row(_ icon: String, _ title: String, _ subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.m) {
                Image(systemName: icon).foregroundStyle(Theme.accentTeal).frame(width: 28)
                VStack(alignment: .leading) {
                    Text(title).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

enum LogRoute: Identifiable {
    case photo, barcode, label, text, weight
    var id: Int { hashValue }
}

// MARK: - Free-text estimate → editable confirmation (spec §7.3 / §11.4)
struct MealTextEntrySheet: View {
    @Environment(FunctionsClient.self) private var functions
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var items: [AnalyzedFoodItem] = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    Form {
                        Section("Describe your meal") {
                            TextField("e.g. 1 katori dal + 2 rotis + curd", text: $text, axis: .vertical)
                                .lineLimit(2...5)
                        }
                        if let error { Text(error).foregroundStyle(.red).font(.caption) }
                        Button(busy ? "Estimating…" : "Estimate") {
                            Task { await estimate() }
                        }.disabled(busy || text.isEmpty)
                    }
                } else {
                    MealConfirmationList(items: $items, onSave: dismiss.callAsFunction)
                }
            }
            .navigationTitle("Describe meal")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func estimate() async {
        busy = true; error = nil
        defer { busy = false }
        do { items = try await functions.estimateText(text) }
        catch { self.error = error.localizedDescription }
    }
}

/// Editable confirmation list — the user picks LLM vs grounded macros, edits,
/// drops items, then saves (spec §7.3). Photo/barcode/label sheets reuse this.
struct MealConfirmationList: View {
    @Environment(Repository.self) private var repo
    @Binding var items: [AnalyzedFoodItem]
    var onSave: () -> Void
    @State private var mealType: MealType = .lunch
    @State private var date = Date()
    @State private var useGrounded: Set<String> = []

    var body: some View {
        Form {
            Picker("Meal", selection: $mealType) {
                ForEach(MealType.allCases) { Text($0.label).tag($0) }
            }
            DatePicker("When", selection: $date)

            ForEach($items) { $item in
                Section(item.name) {
                    if let g = item.grounded {
                        Picker("Source", selection: Binding(
                            get: { useGrounded.contains(item.id) ? 1 : 0 },
                            set: { if $0 == 1 { useGrounded.insert(item.id) } else { useGrounded.remove(item.id) } }
                        )) {
                            Text("AI estimate (\(item.calories) kcal)").tag(0)
                            Text("\(g.matchedName) (\(g.calories) kcal)").tag(1)
                        }.pickerStyle(.inline)
                    }
                    LabeledContent("Calories") {
                        TextField("kcal", value: $item.calories, format: .number)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    Text("P \(Int(item.proteinG))g · C \(Int(item.carbsG))g · F \(Int(item.fatG))g")
                        .font(.caption).foregroundStyle(.secondary)
                    if item.confidence < 0.5 {
                        Label("Low confidence — please double-check", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            Button("Save \(items.count) item\(items.count == 1 ? "" : "s")") {
                Task { await save() }
            }
        }
    }

    private func save() async {
        for item in items {
            let useG = useGrounded.contains(item.id)
            let g = item.grounded
            let meal = MealEntry(
                id: "", mealType: mealType, loggedAt: date, name: item.name,
                calories: useG ? (g?.calories ?? item.calories) : item.calories,
                proteinG: useG ? (g?.proteinG ?? item.proteinG) : item.proteinG,
                carbsG: useG ? (g?.carbsG ?? item.carbsG) : item.carbsG,
                fatG: useG ? (g?.fatG ?? item.fatG) : item.fatG,
                servingDescription: item.servingDescription,
                entryMethod: g != nil && useG ? .foodDB : .llm,
                photoUrl: nil, barcode: nil, foodDbId: g?.foodDbId, confidence: item.confidence
            )
            try? await repo.addMeal(meal, on: date)
        }
        onSave()
    }
}

// Placeholder sheets that share the confirmation flow — camera/scan wiring (§7.3)
// is the next implementation step.
struct MealPhotoEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            EmptyStateView(systemImage: "camera", title: "Photo logging",
                           message: "Camera + VisionKit capture, then analyzeMeal → confirmation. Wire next.")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}
struct BarcodeEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            EmptyStateView(systemImage: "barcode.viewfinder", title: "Barcode scan",
                           message: "DataScannerViewController → foodBarcode → confirmation. Wire next.")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}
struct LabelEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            EmptyStateView(systemImage: "text.viewfinder", title: "Label OCR",
                           message: "Vision OCR → parseLabel → confirmation. Wire next.")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}
