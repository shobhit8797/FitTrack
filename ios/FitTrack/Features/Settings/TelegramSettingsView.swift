import SwiftUI
import UIKit

// Settings → Telegram. Connects a Telegram chat to this account so the user can
// log food (text or photo), check today's numbers, and see today's workout
// without opening the app.
//
// The flow: the backend mints a single-use 6-character code, the user hands it
// to the bot (tapping "Open Telegram" sends it automatically as /start <code>),
// and the bot writes the binding server-side. This view never has to poll for
// that — it streams the profile, so `telegram` appearing on the doc flips the
// screen to its connected state on its own.
struct TelegramSettingsView: View {
    @Environment(Repository.self) private var repo
    @Environment(FunctionsClient.self) private var functions
    @Environment(\.openURL) private var openURL

    @State private var profile: UserProfile?
    @State private var loaded = false
    @State private var linkCode: FunctionsClient.TelegramLinkCode?
    @State private var isWorking = false
    @State private var showDisconnectConfirm = false
    @State private var error: String?

    private var link: TelegramLink? { profile?.telegram }

    var body: some View {
        Form {
            if !loaded {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if let link {
                connectedSection(link)
            } else {
                pitchSection
                connectSection
            }

            capabilitiesSection

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.caption)
                }
            }
        }
        .tint(Theme.accentTeal)
        .navigationTitle("Telegram")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                for try await streamed in repo.profileStream() {
                    profile = streamed
                    loaded = true
                    // The bot redeemed the code — retire the now-stale card.
                    if streamed?.telegram != nil { linkCode = nil }
                }
            } catch {
                loaded = true
                self.error = error.localizedDescription
            }
        }
        .confirmationDialog(
            "Disconnect Telegram?", isPresented: $showDisconnectConfirm, titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) { Task { await disconnect() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The bot will stop accepting messages for your account. Everything you've already logged stays put.")
        }
    }

    // MARK: Connected

    @ViewBuilder private func connectedSection(_ link: TelegramLink) -> some View {
        Section {
            HStack(spacing: Theme.Spacing.m) {
                Image(systemName: "paperplane.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.accentTeal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connected").font(.headline)
                    Text(link.displayHandle)
                        .font(.caption).foregroundStyle(.secondary)
                    if let linkedAt = link.linkedAt {
                        Text("Since \(linkedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.xs)

            Button {
                Haptics.tap()
                openBotChat()
            } label: {
                Label("Open chat in Telegram", systemImage: "arrow.up.right.square")
            }

            Button(role: .destructive) {
                Haptics.warning()
                showDisconnectConfirm = true
            } label: {
                Label("Disconnect", systemImage: "link.badge.plus")
            }
            .disabled(isWorking)
        } footer: {
            Text("Send the bot a meal in plain words or a photo of your plate. It shows the macro breakdown and waits for you to tap Save — nothing is logged behind your back.")
        }
    }

    // MARK: Not connected

    private var pitchSection: some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Image(systemName: "paperplane.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.accentTeal)
                Text("Log from Telegram")
                    .font(.headline)
                Text("Message the FitTrack bot what you ate — or send a photo of it — and it lands in your log instantly. Handy when your hands are full and the app is two taps too far.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }

    @ViewBuilder private var connectSection: some View {
        Section {
            if let linkCode {
                codeCard(linkCode)
            } else {
                Button {
                    Haptics.tap()
                    Task { await generateCode() }
                } label: {
                    HStack {
                        Label("Connect Telegram", systemImage: "link")
                        if isWorking {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isWorking)
            }
        } footer: {
            Text(linkCode == nil
                 ? "You'll get a one-time code to hand to the bot. It stays valid for an hour."
                 : "This screen updates by itself the moment the bot accepts your code.")
        }
    }

    @ViewBuilder private func codeCard(_ code: FunctionsClient.TelegramLinkCode) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Your code")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(code.code)
                    // Monospaced + wide tracking: this gets read off the screen
                    // and retyped in another app.
                    .font(.system(.title, design: .monospaced, weight: .bold))
                    .tracking(4)
                Spacer()
                Button {
                    UIPasteboard.general.string = code.code
                    Haptics.tap()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy code")
            }
            Text("Expires \(code.expiresAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, Theme.Spacing.xs)

        if let url = code.deepLinkURL {
            Button {
                Haptics.tap()
                openURL(url)
            } label: {
                Label("Open Telegram & connect", systemImage: "arrow.up.right.square")
            }
        } else {
            // No bot username configured server-side — the code still works, the
            // user just types it into the chat themselves.
            Text("Send this to the bot as: /link \(code.code)")
                .font(.caption).foregroundStyle(.secondary)
        }

        Button {
            Haptics.tap()
            Task { await generateCode() }
        } label: {
            Label("Get a new code", systemImage: "arrow.clockwise")
        }
        .disabled(isWorking)
    }

    // MARK: What the bot can do

    private var capabilitiesSection: some View {
        Section("What the bot can do") {
            capability("text.bubble", "Log food in plain words",
                       "\"150g chicken thigh + 100g rice\" — it estimates the macros and shows the breakdown.")
            capability("camera", "Log food from a photo",
                       "Send a picture of your plate. Add a caption like \"half of this\" to sharpen the portion.")
            capability("chart.bar", "/today",
                       "Calories and protein against your targets, plus everything logged so far.")
            capability("figure.strengthtraining.traditional", "/workout",
                       "Today's session from your plan, with a button to mark it done.")
            capability("scalemass", "/weight 72.5",
                       "Log a weigh-in and see the change since your last one.")
        }
    }

    private func capability(_ icon: String, _ title: String, _ detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon).foregroundStyle(Theme.accentTeal)
        }
        .padding(.vertical, 2)
    }

    // MARK: Actions

    private func generateCode() async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            linkCode = try await functions.createTelegramLinkCode()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func disconnect() async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            try await functions.unlinkTelegram()
            linkCode = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Open the bot's chat. The handle is stamped onto the binding at link time,
    /// so it's available long after the link code itself is gone.
    private func openBotChat() {
        let username = link?.botUsername ?? linkCode?.botUsername ?? ""
        let target = username.isEmpty ? "https://t.me" : "https://t.me/\(username)"
        if let url = URL(string: target) { openURL(url) }
    }
}
