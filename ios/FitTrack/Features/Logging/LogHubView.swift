import SwiftUI
import UIKit

// Log hub (spec §8): the ➕ entry point — photo / barcode / manual / weight.
// A half-height grid of big tappable tiles (each with its own hue) instead of a
// full-screen list: quick capture should feel like a launcher, not a settings
// page. AI/DB estimates always land in an editable confirmation sheet (§7.3) —
// never auto-saved.
struct LogHubView: View {
    @Environment(Repository.self) private var repo
    // Optional: the hub also renders in previews without an AppState around.
    @Environment(AppState.self) private var appState: AppState?
    @Environment(\.dismiss) private var dismiss
    @State private var route: LogRoute?
    // Workout logging: stream the plan so we can offer its days, then log a
    // session against the chosen day.
    @State private var plan: WorkoutPlan?
    @State private var workoutDay: WorkoutDay?
    @State private var showWorkoutPicker = false

    private let columns = [GridItem(.flexible(), spacing: Theme.Spacing.sm),
                           GridItem(.flexible(), spacing: Theme.Spacing.sm)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    gridHeader("Food")
                    LazyVGrid(columns: columns, spacing: Theme.Spacing.sm) {
                        tile("camera.fill", "Photo", "AI estimates macros", color: Theme.accentTeal) { route = .photo }
                        tile("barcode.viewfinder", "Barcode", "Scan a product", color: .indigo) { route = .barcode }
                        tile("text.viewfinder", "Label", "Read a nutrition label", color: .orange) { route = .label }
                        tile("keyboard", "Describe", "Type what you ate", color: .pink) { route = .text }
                    }

                    gridHeader("Activity & body")
                    LazyVGrid(columns: columns, spacing: Theme.Spacing.sm) {
                        tile("dumbbell.fill", "Workout", "Record your sets", color: .purple) { startWorkoutLog() }
                        tile("scalemass.fill", "Weight", "Log today's weight", color: .green) { route = .weight }
                    }
                }
                .padding(Theme.Spacing.m)
            }
            .background(ScreenBackground())
            .navigationTitle("Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Close")
                }
            }
            .task {
                do { for try await p in repo.planStream() { plan = p } } catch {}
            }
            .sheet(item: $route) { route in
                switch route {
                case .text:    MealTextEntrySheet()
                case .weight:  WeightLogSheet()
                case .photo:   MealPhotoEntrySheet()
                case .barcode: BarcodeEntrySheet()
                case .label:   LabelEntrySheet()
                }
            }
            .fullScreenCover(item: $workoutDay) { day in WorkoutSessionView(day: day) }
            .confirmationDialog("Which session?", isPresented: $showWorkoutPicker, titleVisibility: .visible) {
                if let plan {
                    ForEach(plan.days) { day in
                        Button(day.dayLabel) { workoutDay = day }
                    }
                }
            } message: {
                Text(plan == nil
                     ? "Generate a workout plan from Settings to log sessions against it."
                     : "Pick the day you trained.")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // A widget-preselected meal type only applies to this hub session.
        .onDisappear { appState?.pendingMealType = nil }
    }

    /// Mirror of Today's old workout shortcut: if today is a scheduled training
    /// day with a single obvious match, jump straight in; otherwise let the user
    /// pick (the dialog also surfaces the "generate a plan" hint when empty).
    private func startWorkoutLog() {
        guard let plan, !plan.days.isEmpty else { showWorkoutPicker = true; return }
        if plan.isScheduled(), plan.days.count == 1 {
            workoutDay = plan.days[0]
        } else {
            showWorkoutPicker = true
        }
    }

    private func gridHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Spacing.xs)
            .accessibilityAddTraits(.isHeader)
    }

    private func tile(_ icon: String, _ title: String, _ subtitle: String,
                      color: Color, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                IconBadge(systemImage: icon, color: color, size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .padding(Theme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
        .accessibilityAddTraits(.isButton)
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
                        if let error {
                            Label(error, systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.red).font(.caption)
                        }
                        Button {
                            Haptics.tap()
                            Task { await estimate() }
                        } label: {
                            HStack(spacing: Theme.Spacing.s) {
                                if busy { ProgressView().tint(.white) }
                                Text(busy ? "Estimating…" : "Estimate")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle(enabled: !busy && !text.isEmpty))
                        .disabled(busy || text.isEmpty)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
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
    @Environment(AppState.self) private var appState: AppState?
    @Binding var items: [AnalyzedFoodItem]
    var onSave: () -> Void
    // Default the meal type from the current time of day — most logging happens
    // right after eating, so this is usually already correct (user can change it).
    @State private var mealType: MealType = MealType.suggestedForNow()
    @State private var date = Date()
    @State private var useGrounded: Set<String> = []

    var body: some View {
        Form {
            Picker("Meal", selection: $mealType) {
                ForEach(MealType.allCases) { Text($0.label).tag($0) }
            }
            DatePicker("When", selection: $date)

            ForEach($items) { $item in
                Section {
                    if let g = item.grounded {
                        Picker("Source", selection: Binding(
                            get: { useGrounded.contains(item.id) ? 1 : 0 },
                            set: {
                                Haptics.selection()
                                if $0 == 1 { useGrounded.insert(item.id) } else { useGrounded.remove(item.id) }
                            }
                        )) {
                            Label("AI estimate · \(item.calories) kcal", systemImage: "sparkles").tag(0)
                            Label("\(g.matchedName) · \(g.calories) kcal", systemImage: "checkmark.seal.fill").tag(1)
                        }.pickerStyle(.inline)
                    }
                    LabeledContent("Calories") {
                        TextField("kcal", value: $item.calories, format: .number)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                            .font(.body.weight(.semibold))
                    }
                    // Every macro is editable — the AI/DB estimate is a starting
                    // point the user corrects before saving (spec §7.3).
                    macroField("Protein", value: $item.proteinG, color: Theme.protein)
                    macroField("Carbs", value: $item.carbsG, color: Theme.carbs)
                    macroField("Fat", value: $item.fatG, color: Theme.fat)
                    macroField("Fiber", value: Binding(
                        get: { item.fiberG ?? 0 },
                        set: { item.fiberG = $0 }
                    ), color: Theme.carbs)
                    if item.confidence < 0.5 {
                        Label {
                            Text("Low confidence — please double-check these numbers.")
                                .font(.caption.weight(.medium))
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(Theme.carbs)
                        .padding(Theme.Spacing.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.carbs.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                } header: {
                    Text(item.name)
                }
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    Text("Save \(items.count) item\(items.count == 1 ? "" : "s")")
                }
                .buttonStyle(PrimaryButtonStyle())
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .selectAllOnFocus()
        // A widget deep link (fittrack://log/meal?type=…) beats the time-of-day
        // guess; consume it so later logs fall back to the suggestion again.
        .onAppear {
            if let pending = appState?.pendingMealType {
                mealType = pending
                appState?.pendingMealType = nil
            }
        }
    }

    /// One editable macro row: color dot + label on the left, a right-aligned
    /// grams field. Decimal keypad so users can enter e.g. 4.5 g.
    private func macroField(_ label: String, value: Binding<Double>, color: Color) -> some View {
        LabeledContent {
            HStack(spacing: 2) {
                TextField(label, value: value, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.body.weight(.medium))
                Text("g").foregroundStyle(.secondary)
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label)
            }
        }
        .accessibilityLabel("\(label) in grams")
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
                // Fiber isn't grounded by the food DB — keep the edited value.
                fiberG: item.fiberG,
                servingDescription: item.servingDescription,
                entryMethod: g != nil && useG ? .foodDB : .llm,
                photoUrl: nil, barcode: nil, foodDbId: g?.foodDbId, confidence: item.confidence
            )
            try? await repo.addMeal(meal, on: date)
        }
        Haptics.success()
        onSave()
    }
}

/// Friendly, centered loading view with the accent tint — used while a capture
/// flow waits on the backend (analyze / lookup / parse) so the wait reads as
/// intentional rather than a bare spinner.
struct CaptureLoadingView: View {
    let message: String
    var systemImage: String = "sparkles"

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            ZStack {
                Circle()
                    .fill(Theme.accentTeal.opacity(0.12))
                    .frame(width: 88, height: 88)
                Image(systemName: systemImage)
                    .font(.system(size: 32))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.accentTeal.gradient)
            }
            VStack(spacing: Theme.Spacing.s) {
                ProgressView().tint(Theme.accentTeal)
                Text(message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
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
                    CaptureLoadingView(message: "Analyzing your photo…", systemImage: "sparkles")
                } else if !items.isEmpty {
                    MealConfirmationList(items: $items, onSave: dismiss.callAsFunction)
                } else {
                    VStack(spacing: Theme.Spacing.m) {
                        // Photo only leaves the device on this explicit pick (§13).
                        ImageSourcePicker(prompt: "Snap your meal") { image in
                            Haptics.tap()
                            Task { await analyze(image) }
                        }
                        if let error {
                            Label(error, systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.red).font(.caption)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, Theme.Spacing.xl)
                        }
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
                            Haptics.tap()
                            Task { await lookup(code) }
                        }
                        .ignoresSafeArea(edges: .bottom)
                        if busy {
                            HStack(spacing: Theme.Spacing.sm) {
                                ProgressView().tint(Theme.accentTeal)
                                Text("Looking up product…")
                                    .font(.subheadline.weight(.medium))
                            }
                            .padding(.vertical, Theme.Spacing.sm)
                            .padding(.horizontal, Theme.Spacing.ml)
                            .background(.regularMaterial, in: Capsule())
                            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                        }
                        if let error {
                            VStack {
                                Spacer()
                                Label(error, systemImage: "exclamationmark.circle.fill")
                                    .font(.caption.weight(.medium)).foregroundStyle(.white)
                                    .padding(Theme.Spacing.m)
                                    .frame(maxWidth: .infinity)
                                    .background(.red.opacity(0.9))
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
                    CaptureLoadingView(message: "Reading the label…", systemImage: "text.viewfinder")
                } else if !items.isEmpty {
                    MealConfirmationList(items: $items, onSave: dismiss.callAsFunction)
                } else {
                    VStack(spacing: Theme.Spacing.m) {
                        // OCR runs on-device; image + text leave only on this pick (§13).
                        ImageSourcePicker(prompt: "Photograph the nutrition label") { image in
                            Haptics.tap()
                            Task { await parse(image) }
                        }
                        if let error {
                            Label(error, systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.red).font(.caption)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, Theme.Spacing.xl)
                        }
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
            fiberG: m.fiberG,
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
            fiberG: m.fiberG,
            confidence: label.confidence,
            grounded: nil
        )
    }
}
