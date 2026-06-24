import FirebaseFunctions
import SwiftUI

// Settings (spec §8, §13): account, HealthKit perms, data export/delete,
// disclaimer. The AI provider switch is intentionally NOT here — it's a backend
// config (spec §10).
struct SettingsView: View {
    @Environment(AuthService.self) private var auth
    @Environment(HealthKitService.self) private var health
    @State private var showDeleteConfirm = false
    @State private var error: String?
    @State private var exportURL: URL?
    @State private var isExporting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Signed in as", value: auth.displayName ?? "—")
                    Button("Sign out") { try? auth.signOut() }
                }

                Section("Apple Health") {
                    Button("Connect / refresh permissions") {
                        Task { try? await health.requestAuthorization() }
                    }
                    Text("Steps, active energy, and body mass sync from Apple Watch via HealthKit. Health data stays on device unless you choose to send a value.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Your data") {
                    Button("Export my data (JSON)") { Task { await exportData() } }
                        .disabled(isExporting)
                    if let exportURL {
                        ShareLink("Share export", item: exportURL)
                    }
                    Button("Delete account & all data", role: .destructive) {
                        showDeleteConfirm = true
                    }
                }

                Section {
                    Text("FitTrack provides general fitness and nutrition information and is not a medical device. Consult a professional for medical advice.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Delete everything?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete permanently", role: .destructive) { Task { await deleteAccount() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes your profile, logs, photos, and sign-in. It cannot be undone.")
            }
        }
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
