import FirebaseFunctions
import SwiftUI

// Settings (spec §8, §13): account, HealthKit perms, data export/delete,
// disclaimer. The AI provider switch is intentionally NOT here — it's a backend
// config (spec §10).
struct SettingsView: View {
    @Environment(AuthService.self) private var auth
    @Environment(HealthKitService.self) private var health
    @Environment(Repository.self) private var repo
    @Environment(FunctionsClient.self) private var functions
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false
    @State private var showSignOutConfirm = false
    @State private var error: String?
    @State private var exportURL: URL?
    @State private var isExporting = false
    @State private var workoutStatus: String?
    @State private var dietStatus: String?
    @State private var profile: UserProfile?
    @State private var working: Set<String> = []

    /// The name shown on the account card. Prefer the freshly-streamed profile
    /// name (updates the instant an edit is saved) over the cached auth name.
    private var accountName: String {
        profile?.displayName ?? auth.displayName ?? "Your account"
    }

    /// One-line profile recap for the Settings row (goal + pace when set).
    private var profileSummary: String {
        guard let profile else { return "View and edit your profile" }
        var parts = [profile.goal.label]
        if profile.goal.usesWeeklyRate, let rate = profile.weeklyWeightChangeKg, rate > 0 {
            let kg = rate.formatted(.number.precision(.fractionLength(0...2)))
            parts.append("\(kg) kg/wk")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // The account card is the entry point for editing the
                    // profile: tapping it opens the full editor. It shows the
                    // user's name (not a generic "Account" label) so Settings
                    // opens on something personal.
                    NavigationLink {
                        ProfileEditView()
                    } label: {
                        HStack(spacing: Theme.Spacing.m) {
                            initialsAvatar
                            VStack(alignment: .leading, spacing: 2) {
                                Text(accountName)
                                    .font(.headline)
                                Text(profileSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, Theme.Spacing.xs)
                    }
                    Button("Sign out", role: .destructive) {
                        Haptics.warning()
                        showSignOutConfirm = true
                    }
                } footer: {
                    Text("Tap your name to edit your stats, goal, and how fast you want to lose or gain weight. Your calorie and macro targets update on save.")
                }

                Section {
                    planRow(kind: "workout", title: "Workout plan", status: workoutStatus) {
                        await generateWorkout()
                    }
                    planRow(kind: "diet", title: "Diet plan", status: dietStatus) {
                        await generateDiet()
                    }
                } header: {
                    Text("Plans")
                } footer: {
                    Text("Generate a workout plan, a diet plan, or both. Each is built from your profile by your AI coach and appears in its tab.")
                }

                Section("Apple Health") {
                    Button {
                        Haptics.tap()
                        Task { try? await health.requestAuthorization() }
                    } label: {
                        Label("Connect / refresh permissions", systemImage: "heart.fill")
                    }
                    Text("Steps, active energy, and body mass sync from Apple Watch via HealthKit. Health data stays on device unless you choose to send a value.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Your data") {
                    Button {
                        Haptics.tap()
                        Task { await exportData() }
                    } label: {
                        HStack {
                            Label("Export my data (JSON)", systemImage: "square.and.arrow.up")
                            if isExporting {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isExporting)
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Share export", systemImage: "doc.badge.arrow.up")
                        }
                    }
                    Button(role: .destructive) {
                        Haptics.warning()
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete account & all data", systemImage: "trash")
                    }
                }

                Section {
                    Label {
                        Text("FitTrack provides general fitness and nutrition information and is not a medical device. Consult a professional for medical advice.")
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .tint(Theme.accentTeal)
            .navigationTitle("Settings")
            // Presented as a sheet from the Today toolbar (it's no longer a tab).
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .task {
                do {
                    for try await streamed in repo.profileStream() {
                        profile = streamed
                        workoutStatus = streamed?.workoutPlanStatus
                        dietStatus = streamed?.dietPlanStatus
                    }
                } catch {}
            }
            .confirmationDialog("Sign out?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { try? auth.signOut() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll need to sign back in to see your plans and logs.")
            }
            .confirmationDialog("Delete everything?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete permanently", role: .destructive) { Task { await deleteAccount() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes your profile, logs, photos, and sign-in. It cannot be undone.")
            }
        }
    }

    /// Accent-gradient circle with the user's initials — a friendly identity
    /// anchor at the top of Settings.
    private var initialsAvatar: some View {
        let initials = (auth.displayName ?? "?")
            .split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
        return Text(initials.isEmpty ? "?" : initials)
            .font(.system(.headline, design: .rounded, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 48, height: 48)
            .background(Theme.accentGradient, in: Circle())
            .accessibilityHidden(true)
    }

    /// A plan row: shows current generation status and a Generate/Regenerate button.
    @ViewBuilder private func planRow(
        kind: String, title: String, status: String?, action: @escaping () async -> Void
    ) -> some View {
        // Disable only while THIS device has a call in flight. We deliberately do
        // NOT also disable on status == "generating": a backend run that was killed
        // mid-flight (e.g. agent timeout) leaves the status stuck on 'generating'
        // forever, which would otherwise permanently lock this button. Honoring only
        // the local in-flight flag means a stranded status is always retryable —
        // tapping Generate re-runs the callable, which writes a fresh terminal status.
        let busy = working.contains(kind)
        HStack(spacing: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Label {
                    Text(statusLabel(status))
                } icon: {
                    Image(systemName: busy ? "arrow.triangle.2.circlepath" : statusIcon(status))
                }
                .font(.caption)
                .foregroundStyle(statusColor(status, busy: busy))
                .contentTransition(.opacity)
            }
            Spacer()
            Button {
                Haptics.tap()
                Task { await action() }
            } label: {
                if busy {
                    ProgressView()
                } else {
                    Text(buttonLabel(status: status, busy: busy))
                }
            }
            .buttonStyle(.bordered)
            .tint(Theme.accentTeal)
            .disabled(busy)
            .accessibilityLabel("\(buttonLabel(status: status, busy: busy)) \(title)")
        }
        .animation(.snappy, value: busy)
        .animation(.snappy, value: status)
    }

    private func statusIcon(_ status: String?) -> String {
        switch status {
        case "generating": return "arrow.triangle.2.circlepath"
        case "ready": return "checkmark.circle.fill"
        case "failed": return "exclamationmark.triangle.fill"
        default: return "circle.dashed"
        }
    }

    private func statusColor(_ status: String?, busy: Bool) -> Color {
        if busy { return Theme.accentTeal }
        switch status {
        case "ready": return Theme.accentTeal
        case "failed": return .red
        default: return .secondary
        }
    }

    private func statusLabel(_ status: String?) -> String {
        switch status {
        case "generating": return "Generating…"
        case "ready": return "Ready — view in its tab"
        case "failed": return "Last run failed"
        default: return "Not generated yet"
        }
    }

    private func buttonLabel(status: String?, busy: Bool) -> String {
        if busy { return "Working…" }
        switch status {
        case "ready": return "Regenerate"
        case "failed": return "Retry"
        default: return "Generate"
        }
    }

    private func generateWorkout() async {
        working.insert("workout"); defer { working.remove("workout") }
        do { try await functions.generateWorkoutPlan() } catch { self.error = error.localizedDescription }
    }

    private func generateDiet() async {
        working.insert("diet"); defer { working.remove("diet") }
        do { try await functions.generateDietPlan() } catch { self.error = error.localizedDescription }
    }

    // Export (spec §13): call the exportData callable, write the returned tree to
    // a JSON file on disk, then surface a ShareLink so the user can save/send it.
    private func exportData() async {
        isExporting = true
        defer { isExporting = false }
        do {
            let result = try await Functions.functions(region: "us-central1")
                .httpsCallable("exportData").call([:])
            guard let payload = result.data as? [String: Any] else {
                self.error = "Export returned an unexpected response."
                return
            }
            let json = try JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("fittrack-export.json")
            try json.write(to: url, options: .atomic)
            self.exportURL = url
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteAccount() async {
        do {
            _ = try await Functions.functions(region: "us-central1")
                .httpsCallable("deleteAccount").call([:])
            try? auth.signOut()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
