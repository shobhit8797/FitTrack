import SwiftUI
import PhotosUI
import UIKit

// Multimodal meal-logging chat. The user describes a meal in a natural
// conversation — attaching one or more photos, scanning a barcode, and/or typing
// a description — and the assistant (Gemini/OpenRouter behind `mealChat`) either
// asks ONE clarifying question or, once confident, returns the food items to log.
//
// Like the diet coach, the transcript is stateless: every turn relays the full
// history + all attached images to the backend. When the model is done it hands
// off to the reusable, editable MealConfirmationList — AI estimates always land in
// that confirmation sheet before saving (never silently written; see LogHubView).

/// One turn of the meal chat. Images are user attachments; `isContext` marks a
/// synthetic line (e.g. a scanned product) rendered as a subtle info chip.
struct MealChatMessage: Identifiable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    var images: [UIImage] = []
    var isContext: Bool = false
}

struct MealChatView: View {
    @Environment(FunctionsClient.self) private var functions
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var messages: [MealChatMessage] = []
    @State private var draft = ""
    /// Photos staged in the input bar, sent with the next message.
    @State private var pendingImages: [UIImage] = []
    /// Every image attached across the conversation — relayed to the backend each
    /// turn (stateless). Capped to match the server's limit.
    @State private var allImages: [UIImage] = []
    @State private var awaitingReply = false
    @State private var errorText: String?

    // Handoff to the editable confirmation sheet.
    @State private var confirmItems: [AnalyzedFoodItem] = []
    @State private var showConfirm = false

    // Attachment sources.
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showScanner = false
    @State private var resolvingBarcode = false
    /// Extracting nutrition facts from a snapped/picked packaged-food label.
    @State private var analyzingLabel = false
    /// Whether the camera was opened to snap a nutrition label vs. a meal photo.
    @State private var cameraForLabel = false
    /// Single-photo picker fallback for a nutrition label when there's no camera.
    @State private var showLabelPicker = false
    @State private var labelPickerItem: PhotosPickerItem?

    @FocusState private var inputFocused: Bool

    /// Backend + client both cap the images per conversation.
    private let maxImages = 6

    private let intro = "Hey! Tell me what you ate 🍽️ Snap a photo (or a few), scan a barcode, or just describe it — I'll figure out the nutrition and ask if I need a detail."
    private let suggestions = [
        "2 rotis + dal + salad", "A bowl of poha", "Paneer tikka",
        "Masala dosa", "Protein shake", "2 eggs + toast",
    ]

    /// Any in-flight backend work that should block a new send.
    private var isBusy: Bool { awaitingReply || resolvingBarcode || analyzingLabel }

    private var canSend: Bool {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || !pendingImages.isEmpty) && !isBusy
    }
    private var hasProposedItems: Bool { !confirmItems.isEmpty }

    var body: some View {
        NavigationStack {
            conversation
                .background(ScreenBackground())
                .safeAreaInset(edge: .bottom) { bottomBar }
                .navigationTitle("Log a meal")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Close")
                    }
                }
                .fullScreenCover(isPresented: $showCamera) {
                    CameraPicker { image in
                        guard let image else { cameraForLabel = false; return }
                        if cameraForLabel {
                            cameraForLabel = false
                            Task { await analyzeLabel(image) }
                        } else {
                            stage(image)
                        }
                    }
                    .ignoresSafeArea()
                }
                .fullScreenCover(isPresented: $showScanner) { scannerSheet }
                .sheet(isPresented: $showConfirm) {
                    NavigationStack {
                        MealConfirmationList(items: $confirmItems) {
                            showConfirm = false
                            dismiss()
                        }
                        .navigationTitle("Review meal")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Back") { showConfirm = false }
                            }
                        }
                    }
                }
                .onChange(of: photoItems) { _, items in loadPickedPhotos(items) }
                .onChange(of: labelPickerItem) { _, item in loadPickedLabel(item) }
                .photosPicker(isPresented: $showLabelPicker, selection: $labelPickerItem, matching: .images)
        }
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    coachBubble(intro)

                    if messages.isEmpty {
                        suggestionChips
                    }

                    ForEach(messages) { msg in
                        messageRow(msg)
                    }

                    if isBusy {
                        coachRow { MealTypingIndicator() }
                    }

                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.top, Theme.Spacing.m)
                .padding(.bottom, Theme.Spacing.s)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { scrollToBottom(proxy) }
            .onChange(of: isBusy) { scrollToBottom(proxy) }
        }
    }

    private let bottomAnchor = "bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : .snappy) {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }

    // MARK: Bubbles

    @ViewBuilder private func messageRow(_ msg: MealChatMessage) -> some View {
        switch msg.role {
        case .user:
            if msg.isContext {
                contextRow(msg.text)
            } else {
                HStack {
                    Spacer(minLength: Theme.Spacing.xl)
                    VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
                        if !msg.images.isEmpty { imageStrip(msg.images) }
                        if !msg.text.isEmpty {
                            Text(msg.text)
                                .font(.body)
                                .foregroundStyle(.white)
                                .padding(.horizontal, Theme.Spacing.m)
                                .padding(.vertical, Theme.Spacing.s)
                                .background(Theme.accentGradient, in: bubbleShape(isUser: true))
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("You said")
                .accessibilityValue(msg.text.isEmpty ? "Sent \(msg.images.count) photo(s)" : msg.text)
            }
        case .assistant:
            coachRow {
                Text(msg.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, Theme.Spacing.m)
                    .padding(.vertical, Theme.Spacing.s)
                    .background(.regularMaterial, in: bubbleShape(isUser: false))
                    .overlay(
                        bubbleShape(isUser: false)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                    )
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Coach said")
            .accessibilityValue(msg.text)
        }
    }

    /// Photo thumbnails inside a message bubble (up to a few per row).
    private func imageStrip(_ images: [UIImage]) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(Array(images.enumerated()), id: \.offset) { _, img in
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    /// A synthetic info line (e.g. a scanned product), centered and subtle.
    private func contextRow(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 0)
            Label(text, systemImage: text.hasPrefix("Label") ? "doc.text.viewfinder" : "barcode.viewfinder")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.s)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    private func coachBubble(_ text: String) -> some View {
        coachRow {
            Text(text)
                .font(.body)
                .foregroundStyle(.primary)
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.s)
                .background(.regularMaterial, in: bubbleShape(isUser: false))
                .overlay(
                    bubbleShape(isUser: false)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Coach said")
        .accessibilityValue(text)
    }

    private func coachRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.s) {
            Image(systemName: "fork.knife")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Theme.accentGradient, in: Circle())
                .accessibilityHidden(true)
            content()
            Spacer(minLength: Theme.Spacing.xl)
        }
    }

    private func bubbleShape(isUser: Bool) -> some InsettableShape {
        .rect(
            topLeadingRadius: 18,
            bottomLeadingRadius: isUser ? 18 : 4,
            bottomTrailingRadius: isUser ? 4 : 18,
            topTrailingRadius: 18
        )
    }

    // MARK: Quick actions

    /// Compact shortcuts to the three fastest ways to log — upload a photo, scan a
    /// barcode, or scan a nutrition label — pinned above the input field so they're
    /// one tap away in any state rather than buried behind the "+" menu.
    private var quickActionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                quickPill("Photo", icon: "photo.on.rectangle.angled",
                          hint: "Upload a meal photo") { showPhotoPicker = true }
                if BarcodeScannerView.isSupported {
                    quickPill("Barcode", icon: "barcode.viewfinder",
                              hint: "Scan a product barcode") { showScanner = true }
                }
                quickPill("Label", icon: "text.viewfinder",
                          hint: "Scan a nutrition label") { startLabelScan() }
            }
            .padding(.vertical, 2)
        }
    }

    private func quickPill(_ title: String, icon: String, hint: String,
                           action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, Theme.Spacing.m)
                .frame(minHeight: 36)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.accentTeal.opacity(0.3), lineWidth: 1))
                .foregroundStyle(Theme.accentTeal)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel(title)
        .accessibilityHint(hint)
    }

    /// Snap the label with the camera when available; otherwise pick from library.
    private func startLabelScan() {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            cameraForLabel = true
            showCamera = true
        } else {
            showLabelPicker = true
        }
    }

    // MARK: Suggestions

    private var suggestionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                ForEach(suggestions, id: \.self) { chip in
                    Button {
                        draft = chip
                        send()
                    } label: {
                        Text(chip)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, Theme.Spacing.m)
                            .frame(minHeight: 36)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.accentTeal.opacity(0.3), lineWidth: 1))
                            .foregroundStyle(Theme.accentTeal)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Describe \"\(chip)\"")
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
        .padding(.leading, 36)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        VStack(spacing: Theme.Spacing.s) {
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }

            // If the model proposed items but the user backed out of the sheet,
            // let them jump back in without re-sending.
            if hasProposedItems && !showConfirm {
                Button {
                    Haptics.tap()
                    showConfirm = true
                } label: {
                    Label("Review \(confirmItems.count) item\(confirmItems.count == 1 ? "" : "s") to log",
                          systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !pendingImages.isEmpty { pendingStrip }

            if !hasProposedItems { quickActionBar }

            inputField
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.top, Theme.Spacing.s)
        .padding(.bottom, Theme.Spacing.s)
        .background(.bar)
        .animation(reduceMotion ? nil : .snappy, value: errorText)
        .animation(reduceMotion ? nil : .snappy, value: pendingImages.count)
        .animation(reduceMotion ? nil : .snappy, value: hasProposedItems)
    }

    /// Thumbnails of photos staged for the next send, each removable.
    private var pendingStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                ForEach(Array(pendingImages.enumerated()), id: \.offset) { idx, img in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Button {
                            Haptics.tap()
                            pendingImages.remove(at: idx)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.5))
                                .font(.body)
                        }
                        .padding(2)
                        .accessibilityLabel("Remove photo")
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var inputField: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.s) {
            attachmentMenu

            TextField("Describe your meal…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.s)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .onSubmit { if canSend { send() } }

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: Theme.minTapTarget, height: Theme.minTapTarget)
                    .background(Theme.accentGradient.opacity(canSend ? 1 : 0.4), in: Circle())
            }
            .disabled(!canSend)
            .accessibilityLabel("Send message")
        }
    }

    /// The "+" attachment picker: camera, photo library (multi-select), barcode.
    private var attachmentMenu: some View {
        Menu {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { showCamera = true } label: { Label("Take photo", systemImage: "camera") }
            }
            // A PhotosPicker can't live inside a Menu action, so this button flips a
            // flag that presents the picker below.
            Button { showPhotoPicker = true } label: { Label("Choose photos", systemImage: "photo.on.rectangle") }
            if BarcodeScannerView.isSupported {
                Button { showScanner = true } label: { Label("Scan barcode", systemImage: "barcode.viewfinder") }
            }
            Button { startLabelScan() } label: { Label("Scan label", systemImage: "doc.text.viewfinder") }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.accentTeal)
                .frame(width: Theme.minTapTarget, height: Theme.minTapTarget)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
        .accessibilityLabel("Add photo or scan")
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems,
                      maxSelectionCount: maxImages, matching: .images)
    }

    @State private var showPhotoPicker = false

    private var scannerSheet: some View {
        ZStack {
            BarcodeScannerView { code in
                guard !resolvingBarcode else { return }
                showScanner = false
                Haptics.tap()
                Task { await resolveBarcode(code) }
            }
            .ignoresSafeArea()
            VStack {
                HStack {
                    Spacer()
                    Button { showScanner = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.4))
                            .font(.largeTitle)
                    }
                    .padding()
                    .accessibilityLabel("Close scanner")
                }
                Spacer()
                Text("Point at a product barcode")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.vertical, Theme.Spacing.s)
                    .padding(.horizontal, Theme.Spacing.ml)
                    .background(.black.opacity(0.4), in: Capsule())
                    .padding(.bottom, Theme.Spacing.xl)
            }
        }
    }

    // MARK: Attachment handling

    private func stage(_ image: UIImage) {
        Haptics.tap()
        // Respect the per-conversation cap across staged + already-sent images.
        let room = max(0, maxImages - (allImages.count + pendingImages.count))
        guard room > 0 else {
            errorText = "You can attach up to \(maxImages) photos per meal."
            return
        }
        pendingImages.append(image)
    }

    private func loadPickedPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    stage(image)
                }
            }
            photoItems = []
        }
    }

    private func loadPickedLabel(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                await analyzeLabel(image)
            }
            labelPickerItem = nil
        }
    }

    // MARK: Actions

    private func send() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!trimmed.isEmpty || !pendingImages.isEmpty), !isBusy else { return }
        Haptics.tap()
        inputFocused = false
        let attached = pendingImages
        withAnimation(reduceMotion ? nil : .snappy) {
            messages.append(MealChatMessage(role: .user, text: trimmed, images: attached))
            errorText = nil
        }
        allImages.append(contentsOf: attached)
        if allImages.count > maxImages { allImages = Array(allImages.suffix(maxImages)) }
        draft = ""
        pendingImages = []
        Task { await fetchReply() }
    }

    private func resolveBarcode(_ code: String) async {
        resolvingBarcode = true
        errorText = nil
        defer { resolvingBarcode = false }
        do {
            guard let product = try await functions.foodBarcode(code) else {
                errorText = "Product not found — try a photo or just describe it."
                return
            }
            let summary = Self.productSummary(product)
            withAnimation(reduceMotion ? nil : .snappy) {
                messages.append(MealChatMessage(role: .user, text: summary, isContext: true))
            }
            await fetchReply()
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Extract nutrition facts from a label photo (OCR + LLM on the backend) and
    /// inject them as a context turn — same handoff as a scanned barcode.
    private func analyzeLabel(_ image: UIImage) async {
        analyzingLabel = true
        errorText = nil
        defer { analyzingLabel = false }
        // OCR runs on-device; pair the recognized text with the image so the
        // backend parser has both signals (mirrors the LogHub label flow).
        let ocrText = await LabelOCR.recognizeText(in: image)
        let base64 = ImageEncoding.jpegBase64(image)
        guard ocrText != nil || base64 != nil else {
            errorText = "Couldn't read that photo — try again."
            return
        }
        do {
            let label = try await functions.parseLabel(ocrText: ocrText, jpegBase64: base64)
            let summary = Self.labelSummary(label)
            withAnimation(reduceMotion ? nil : .snappy) {
                messages.append(MealChatMessage(role: .user, text: summary, isContext: true))
            }
            await fetchReply()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func fetchReply() async {
        awaitingReply = true
        defer { awaitingReply = false }
        do {
            let response = try await functions.mealChat(messages: transcriptPayload(), images: imagePayload())
            withAnimation(reduceMotion ? nil : .snappy) {
                messages.append(MealChatMessage(role: .assistant, text: response.reply))
            }
            // No follow-up needed → advance straight to the editable log (per §7.3
            // AI estimates land in the confirmation sheet, never auto-saved).
            if !response.needsFollowUp && !response.items.isEmpty {
                confirmItems = response.items
                Haptics.success()
                showConfirm = true
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: Payloads

    /// Serialize the transcript for the callable. Image-only turns still carry a
    /// short placeholder so the backend keeps them in context.
    private func transcriptPayload() -> [[String: String]] {
        messages.map { msg in
            let role = msg.role == .assistant ? "assistant" : "user"
            var content = msg.text
            if content.isEmpty && !msg.images.isEmpty {
                content = "(attached \(msg.images.count) photo\(msg.images.count == 1 ? "" : "s"))"
            }
            return ["role": role, "content": content]
        }
    }

    private func imagePayload() -> [[String: String]] {
        allImages.compactMap { img in
            guard let base64 = ImageEncoding.jpegBase64(img) else { return nil }
            return ["base64": base64, "mimeType": "image/jpeg"]
        }
    }

    /// A one-line "Scanned: … macros …" summary the LLM can incorporate.
    private static func productSummary(_ p: FunctionsClient.CachedProduct) -> String {
        macroSummary(prefix: "Scanned",
                     name: [p.brand, p.productName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " "),
                     servingSize: p.servingSize, perServing: p.perServing, per100g: p.per100g)
    }

    /// The label-scan counterpart, rendered with prefix "Label:".
    private static func labelSummary(_ l: FunctionsClient.LabelResult) -> String {
        macroSummary(prefix: "Label",
                     name: [l.brand, l.productName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " "),
                     servingSize: l.servingSize, perServing: l.perServing, per100g: l.per100g)
    }

    private static func macroSummary(prefix: String, name: String, servingSize: String?,
                                     perServing: FunctionsClient.LabelResult.Macro,
                                     per100g: FunctionsClient.LabelResult.Macro) -> String {
        let m = perServing.calories != nil ? perServing : per100g
        let basis = perServing.calories != nil ? (servingSize ?? "1 serving") : "100g"
        var parts: [String] = []
        if let c = m.calories { parts.append("\(c) kcal") }
        if let pr = m.proteinG { parts.append("\(Int(pr))g protein") }
        if let ca = m.carbsG { parts.append("\(Int(ca))g carbs") }
        if let f = m.fatG { parts.append("\(Int(f))g fat") }
        let macros = parts.isEmpty ? "no nutrition data" : parts.joined(separator: ", ")
        return "\(prefix): \(name.isEmpty ? "product" : name) — \(macros) per \(basis)"
    }
}

/// "Coach is typing" animation for the meal chat (mirrors the diet coach's).
private struct MealTypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 7, height: 7)
                    .opacity(animating ? 1 : 0.3)
                    .animation(
                        reduceMotion ? nil
                            : .easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2),
                        value: animating
                    )
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.sm)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        .accessibilityLabel("Coach is typing")
        .onAppear { animating = true }
    }
}
