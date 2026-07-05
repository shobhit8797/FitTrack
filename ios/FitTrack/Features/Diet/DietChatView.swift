import SwiftUI

// "Diet coach" chat (presented from the Diet tab). The user describes what they
// want to eat this week in a short, natural conversation; when ready they tap
// Generate and the backend turns the transcript + their targets into a 7-day
// plan, written to dietPlans/current and streamed straight into the Diet tab.
//
// The transcript is kept in-memory for the session (each planning chat is a fresh
// start) — the durable artifact is the generated plan, not the conversation.

/// One chat turn in the coach conversation.
struct DietChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant }
    let id = UUID()
    let role: Role
    var content: String
}

struct DietChatView: View {
    @Environment(FunctionsClient.self) private var functions
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var messages: [DietChatMessage] = []
    @State private var draft = ""
    @State private var awaitingReply = false
    @State private var generating = false
    @State private var errorText: String?
    @FocusState private var inputFocused: Bool

    // The coach's opening line + a few taps to lower the blank-page barrier.
    private let intro = "Hey! I'm your nutrition coach 🥗 Tell me what you're in the mood for this week — favorite cuisines, anything to avoid, how much time you like to spend cooking — and I'll build you a 7-day plan around your targets."
    private let suggestions = [
        "High protein", "Vegetarian", "Quick 15-min meals",
        "Budget-friendly", "Indian food", "Lots of variety",
    ]

    /// The Generate CTA appears once the coach has replied at least once, so the
    /// plan is informed by the conversation.
    private var hasConversation: Bool { messages.contains { $0.role == .assistant } }
    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !awaitingReply && !generating
    }

    var body: some View {
        NavigationStack {
            conversation
                .background(ScreenBackground())
                .safeAreaInset(edge: .bottom) { bottomBar }
                .navigationTitle("Diet coach")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Close")
                            .disabled(generating)
                    }
                }
                .interactiveDismissDisabled(generating)
        }
    }

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

                    if awaitingReply {
                        coachRow { TypingIndicator() }
                    }

                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.top, Theme.Spacing.m)
                .padding(.bottom, Theme.Spacing.s)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages) { scrollToBottom(proxy) }
            .onChange(of: awaitingReply) { scrollToBottom(proxy) }
            .onChange(of: generating) { scrollToBottom(proxy) }
        }
    }

    private let bottomAnchor = "bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : .snappy) {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }

    // MARK: Bubbles

    @ViewBuilder private func messageRow(_ msg: DietChatMessage) -> some View {
        switch msg.role {
        case .user:
            HStack {
                Spacer(minLength: Theme.Spacing.xl)
                Text(msg.content)
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.Spacing.m)
                    .padding(.vertical, Theme.Spacing.s)
                    .background(Theme.accentGradient, in: bubbleShape(isUser: true))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You said")
            .accessibilityValue(msg.content)
        case .assistant:
            coachRow {
                Text(msg.content)
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
            .accessibilityValue(msg.content)
        }
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

    /// Coach side: small avatar + the bubble, left-aligned with a trailing gutter.
    private func coachRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.s) {
            Image(systemName: "leaf.fill")
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

    // MARK: Suggestions

    private var suggestionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                ForEach(suggestions, id: \.self) { chip in
                    Button {
                        send(chip)
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
                    .accessibilityHint("Send \"\(chip)\" to the coach")
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
        .padding(.leading, 36) // line up under the coach bubble, past the avatar
    }

    // MARK: Bottom bar (error + generate CTA + input)

    private var bottomBar: some View {
        VStack(spacing: Theme.Spacing.s) {
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }

            if hasConversation {
                Button {
                    Haptics.tap()
                    inputFocused = false
                    Task { await generate() }
                } label: {
                    if generating {
                        HStack(spacing: Theme.Spacing.s) {
                            ProgressView().tint(.white)
                            Text("Building your 7-day plan…")
                        }
                    } else {
                        Label("Generate 7-day plan", systemImage: "sparkles")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(enabled: !generating))
                .disabled(generating)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            inputField
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.top, Theme.Spacing.s)
        .padding(.bottom, Theme.Spacing.s)
        .background(.bar)
        .animation(reduceMotion ? nil : .snappy, value: hasConversation)
        .animation(reduceMotion ? nil : .snappy, value: generating)
        .animation(reduceMotion ? nil : .snappy, value: errorText)
    }

    private var inputField: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.s) {
            TextField("Message your coach…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.s)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .disabled(generating)
                .onSubmit { if canSend { send(draft) } }

            Button {
                send(draft)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: Theme.minTapTarget, height: Theme.minTapTarget)
                    .background(
                        Theme.accentGradient.opacity(canSend ? 1 : 0.4),
                        in: Circle()
                    )
            }
            .disabled(!canSend)
            .accessibilityLabel("Send message")
        }
    }

    // MARK: Actions

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !awaitingReply, !generating else { return }
        Haptics.tap()
        withAnimation(reduceMotion ? nil : .snappy) {
            messages.append(DietChatMessage(role: .user, content: trimmed))
            errorText = nil
        }
        draft = ""
        Task { await fetchReply() }
    }

    private func fetchReply() async {
        awaitingReply = true
        defer { awaitingReply = false }
        do {
            let reply = try await functions.dietCoachReply(messages: payload())
            withAnimation(reduceMotion ? nil : .snappy) {
                messages.append(DietChatMessage(role: .assistant, content: reply.reply))
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func generate() async {
        guard !generating else { return }
        generating = true
        defer { generating = false }
        errorText = nil
        do {
            let status = try await functions.generateDietPlanFromChat(messages: payload())
            if status == "ready" {
                Haptics.success()
                dismiss()
            } else {
                errorText = "Couldn't build your plan. Please try again."
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Serialize the transcript for the callable payload.
    private func payload() -> [[String: String]] {
        messages.map { ["role": $0.role.rawValue, "content": $0.content] }
    }
}

/// Three-dot "coach is typing" animation shown while awaiting a reply. Each dot
/// pulses on a staggered repeatForever — an implicit animation SwiftUI tears down
/// automatically when the bubble is removed (no manual timer/task to leak).
private struct TypingIndicator: View {
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
