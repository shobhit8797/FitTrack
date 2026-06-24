import SwiftUI
import UIKit

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

// MARK: - Photo → analyzeMeal → editable confirmation (spec §7.3)
struct MealPhotoEntrySheet: View {
    @Environment(FunctionsClient.self) private var functions
    @Environment(\.dismiss) private var dismiss
    @State private var items: [AnalyzedFoodItem] = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if busy {
                    ProgressView("Analyzing photo…")
                } else if !items.isEmpty {
                    MealConfirmationList(items: $items, onSave: dismiss.callAsFunction)
                } else {
                    VStack(spacing: Theme.Spacing.m) {
                        // Photo only leaves the device on this explicit pick (§13).
                        ImageSourcePicker(prompt: "Snap your meal") { image in
                            Task { await analyze(image) }
                        }
                        if let error { Text(error).foregroundStyle(.red).font(.caption) }
                    }
                }
            }
            .navigationTitle("Photo meal")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func analyze(_ image: UIImage) async {
        guard let base64 = ImageEncoding.jpegBase64(image) else {
            error = "Couldn't read that image — please try another."
            return
        }
        busy = true; error = nil
        defer { busy = false }
        do {
            let result = try await functions.analyzeMeal(jpegBase64: base64)
            if result.isEmpty {
                error = "No food found in that photo — try again or describe it instead."
            } else {
                items = result
            }
            // TODO (§13): optionally upload the JPEG to Firebase Storage and set
            // photoUrl on the saved meals. Left nil for now to keep capture minimal.
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Barcode → foodBarcode → editable confirmation (spec §7.3)
struct BarcodeEntrySheet: View {
    @Environment(FunctionsClient.self) private var functions
    @Environment(\.dismiss) private var dismiss
    @State private var items: [AnalyzedFoodItem] = []
    @State private var busy = false
    @State private var error: String?
    @State private var didScan = false

    var body: some View {
        NavigationStack {
            Group {
                if !items.isEmpty {
                    MealConfirmationList(items: $items, onSave: dismiss.callAsFunction)
                } else if BarcodeScannerView.isSupported {
                    ZStack {
                        BarcodeScannerView { code in
                            guard !didScan else { return }
                            didScan = true
                            Task { await lookup(code) }
                        }
                        .ignoresSafeArea(edges: .bottom)
                        if busy { ProgressView("Looking up product…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cardRadius)) }
                        if let error {
                            VStack {
                                Spacer()
                                Text(error).font(.caption).foregroundStyle(.white)
                                    .padding(Theme.Spacing.m)
                                    .frame(maxWidth: .infinity)
                                    .background(.red.opacity(0.85))
                            }
                        }
                    }
                } else {
                    EmptyStateView(systemImage: "barcode.viewfinder", title: "Scanning unavailable",
                                   message: "This device can't scan barcodes. Try the photo or describe flow instead.")
                }
            }
            .navigationTitle("Scan barcode")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func lookup(_ code: String) async {
        busy = true; error = nil
        defer { busy = false }
        do {
            guard let product = try await functions.foodBarcode(code) else {
                error = "Product not found. Try the label or photo flow."
                didScan = false // allow another scan attempt
                return
            }
            items = [FoodCaptureMapping.item(from: product, barcode: code)]
        } catch {
            self.error = error.localizedDescription
            didScan = false
        }
    }
}

// MARK: - Label OCR → parseLabel → editable confirmation (spec §7.3)
struct LabelEntrySheet: View {
    @Environment(FunctionsClient.self) private var functions
    @Environment(\.dismiss) private var dismiss
    @State private var items: [AnalyzedFoodItem] = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if busy {
                    ProgressView("Reading label…")
                } else if !items.isEmpty {
                    MealConfirmationList(items: $items, onSave: dismiss.callAsFunction)
                } else {
                    VStack(spacing: Theme.Spacing.m) {
                        // OCR runs on-device; image + text leave only on this pick (§13).
                        ImageSourcePicker(prompt: "Photograph the nutrition label") { image in
                            Task { await parse(image) }
                        }
                        if let error { Text(error).foregroundStyle(.red).font(.caption) }
                    }
                }
            }
            .navigationTitle("Nutrition label")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func parse(_ image: UIImage) async {
        busy = true; error = nil
        defer { busy = false }
        let ocrText = await LabelOCR.recognizeText(in: image)
        let base64 = ImageEncoding.jpegBase64(image)
        do {
            let label = try await functions.parseLabel(ocrText: ocrText, jpegBase64: base64)
            items = [FoodCaptureMapping.item(from: label)]
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Maps barcode/label results (per-serving macros) into a single editable
/// AnalyzedFoodItem so they can reuse MealConfirmationList (spec §7.3). The user
/// can then adjust calories/macros (e.g. for multiple servings) before saving.
enum FoodCaptureMapping {
    static func item(from product: FunctionsClient.CachedProduct, barcode: String) -> AnalyzedFoodItem {
        let m = product.perServing
        let name = [product.brand, product.productName].compactMap { $0 }.joined(separator: " ")
        return AnalyzedFoodItem(
            name: name.isEmpty ? "Scanned product" : name,
            dishKey: barcode,
            servingDescription: product.servingSize ?? "1 serving",
            calories: m.calories ?? 0,
            proteinG: m.proteinG ?? 0,
            carbsG: m.carbsG ?? 0,
            fatG: m.fatG ?? 0,
            confidence: 0.9,
            grounded: nil
        )
    }

    static func item(from label: FunctionsClient.LabelResult) -> AnalyzedFoodItem {
        let m = label.perServing
        let name = [label.brand, label.productName].compactMap { $0 }.joined(separator: " ")
        return AnalyzedFoodItem(
            name: name.isEmpty ? "Label item" : name,
            dishKey: label.productName ?? "label",
            servingDescription: label.servingSize ?? "1 serving",
            calories: m.calories ?? 0,
            proteinG: m.proteinG ?? 0,
            carbsG: m.carbsG ?? 0,
            fatG: m.fatG ?? 0,
            confidence: label.confidence,
            grounded: nil
        )
    }
}
