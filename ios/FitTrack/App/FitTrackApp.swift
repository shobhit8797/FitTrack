import FirebaseCore
import FirebaseFirestore
import SwiftUI

@main
struct FitTrackApp: App {
    @State private var auth: AuthService
    @State private var repo: Repository
    @State private var functions: FunctionsClient
    @State private var health = HealthKitService()

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
                .tint(Theme.accentTeal)
        }
    }
}

/// Routes between sign-in, onboarding, and the main tabs based on auth +
/// whether this user has generated targets yet (no app-wide defaults — spec §2).
struct RootView: View {
    @Environment(AuthService.self) private var auth
    @Environment(Repository.self) private var repo
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
    }
}

struct MainTabView: View {
    // The ➕ lives in the middle of the tab bar (spec §8). Tapping it opens the
    // Log hub as a sheet rather than switching tabs, so we track the prior tab
    // and a sheet flag instead of letting the placeholder tab actually show.
    @State private var selection = 0
    @State private var showLog = false

    var body: some View {
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
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(5)
        }
        .onChange(of: selection) { previous, new in
            guard new == 2 else { return }
            selection = previous // stay on the current tab; the ➕ only logs.
            showLog = true
        }
        .sheet(isPresented: $showLog) { LogHubView() }
    }
}
