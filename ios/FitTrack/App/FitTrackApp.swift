import FirebaseCore
import FirebaseFirestore
import SwiftUI
import UserNotifications

@main
struct FitTrackApp: App {
    @State private var auth: AuthService
    @State private var repo: Repository
    @State private var functions: FunctionsClient
    @State private var health = HealthKitService()
    @State private var notifications = NotificationService()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        FirebaseApp.configure()
        // Firestore offline persistence is the local cache + sync (spec §9).
        let settings = FirestoreSettings()
        settings.cacheSettings = PersistentCacheSettings()
        Firestore.firestore().settings = settings
        // These touch Firebase (Firestore/Functions) at init, so they must be
        // constructed AFTER FirebaseApp.configure() — not as default property
        // values, which Swift evaluates before this init body runs.
        _auth = State(initialValue: AuthService())
        _repo = State(initialValue: Repository())
        _functions = State(initialValue: FunctionsClient())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .environment(repo)
                .environment(functions)
                .environment(health)
                .environment(notifications)
                .tint(Theme.accentTeal)
        }
        // Rewrite the widget snapshot on every foreground so the widgets heal
        // after reinstall, sign-out on another device, or the day rolling over.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            repo.refreshWidgetSnapshot()
            Task {
                // The widget's "Start Gym" button schedules a local reminder but
                // can't request notification permission — only the app can.
                // Provisional never prompts, so it's safe on every foreground.
                await notifications.requestProvisionalAuthorizationIfNeeded()
                await Self.healGymClock()
            }
        }
    }

    /// Best-effort repair of the widget's gym clock on foreground: re-assert
    /// the 1-hour clock-out reminder if it went missing (e.g. reinstall), and
    /// clear a session left running past the staleness cutoff.
    private static func healGymClock() async {
        if let startedAt = GymClock.startedAt {
            let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
            if !pending.contains(where: { $0.identifier == GymClock.notificationId }) {
                // No-op once the hour has already passed.
                GymClock.scheduleClockOutReminder(startedAt: startedAt)
            }
        } else if let defaults = UserDefaults(suiteName: WidgetStore.appGroupId),
                  defaults.double(forKey: GymClock.startKey) > 0 {
            GymClock.end() // startedAt is nil but the key survives → stale (>12h)
        }
    }
}

/// Routes between sign-in, onboarding, and the main tabs based on auth +
/// whether this user has generated targets yet (no app-wide defaults — spec §2).
struct RootView: View {
    @Environment(AuthService.self) private var auth
    @Environment(Repository.self) private var repo
    @Environment(NotificationService.self) private var notifications
    @State private var profile: UserProfile?
    @State private var loadingProfile = true

    var body: some View {
        Group {
            if !auth.isSignedIn {
                SignInView()
            } else if loadingProfile {
                ProgressView("Loading…")
            } else if profile?.hasTargets != true {
                OnboardingFlow(existingProfile: profile)
            } else {
                MainTabView()
            }
        }
        .task(id: auth.uid) {
            guard auth.isSignedIn else { loadingProfile = false; return }
            loadingProfile = true
            do {
                for try await p in repo.profileStream() {
                    profile = p
                    loadingProfile = false
                }
            } catch {
                loadingProfile = false
            }
        }
        // Keep local supplement/medication notifications in sync with the user's
        // Firestore reminders — reschedules on launch (e.g. after reinstall) and
        // whenever the list changes on any device. Runs independently of the
        // profile stream above (SwiftUI supports multiple .task modifiers).
        .task(id: auth.uid) {
            guard auth.isSignedIn else { return }
            do {
                for try await reminders in repo.remindersStream() {
                    await notifications.sync(reminders: reminders)
                }
            } catch {}
        }
    }
}

/// Cross-tab UI state: any screen can summon the Log hub (e.g. the empty-state
/// "Log a meal" CTA on Today) without owning the sheet itself.
@Observable
final class AppState {
    var showLog = false
    /// Meal type a widget deep link asked to preselect (fittrack://log/meal?type=…);
    /// consumed by the next meal confirmation, then cleared.
    var pendingMealType: MealType?
    /// Set by fittrack://log/workout; consumed by WorkoutView once its plan loads.
    var pendingWorkoutLog = false
}

struct MainTabView: View {
    // Four content tabs + the center ➕ (spec §8). Settings is deliberately NOT
    // a tab — it's reached from the Today toolbar, keeping the bar focused on
    // the things people do daily. Tapping ➕ opens the Log hub as a sheet rather
    // than switching tabs, so we restore the prior tab and flip a sheet flag.
    @State private var selection = 0
    @State private var appState = AppState()

    var body: some View {
        @Bindable var appState = appState
        TabView(selection: $selection) {
            TodayView()
                .tabItem { Label("Today", systemImage: "house.fill") }
                .tag(0)
            WorkoutView()
                .tabItem { Label("Workout", systemImage: "dumbbell.fill") }
                .tag(1)
            // Center "+" entry point. Its content is never displayed — selecting
            // it is intercepted below to present the Log hub.
            Color.clear
                .tabItem { Label("Log", systemImage: "plus.circle.fill") }
                .tag(2)
            DietView()
                .tabItem { Label("Diet", systemImage: "fork.knife") }
                .tag(3)
            ProgressDashboardView()
                .tabItem { Label("Progress", systemImage: "chart.xyaxis.line") }
                .tag(4)
        }
        .onChange(of: selection) { previous, new in
            guard new == 2 else { return }
            selection = previous // stay on the current tab; the ➕ only logs.
            appState.showLog = true
        }
        .sheet(isPresented: $appState.showLog) { LogHubView() }
        .onOpenURL { handleWidgetLink($0) }
        // Outside the .sheet so the Log hub (sheet content) sees AppState too.
        .environment(appState)
    }

    /// Widget deep links (see WidgetDeepLink in Shared/WidgetShared.swift).
    /// Anything that isn't the `fittrack` scheme — e.g. the Google Sign-In
    /// reversed-client-id OAuth callback — is ignored here.
    private func handleWidgetLink(_ url: URL) {
        guard url.scheme == "fittrack", url.host == "log" else { return }
        switch url.path {
        case "/meal":
            let type = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "type" }?.value
            appState.pendingMealType = type.flatMap(MealType.init(rawValue:))
            appState.showLog = true
        case "/workout":
            appState.showLog = false
            appState.pendingWorkoutLog = true
            selection = 1
        default:
            break
        }
    }
}
