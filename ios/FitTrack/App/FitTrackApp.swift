import FirebaseCore
import FirebaseFirestore
import SwiftUI

@main
struct FitTrackApp: App {
    @State private var auth: AuthService
    @State private var repo = Repository()
    @State private var functions = FunctionsClient()
    @State private var health = HealthKitService()

    init() {
        FirebaseApp.configure()
        // Firestore offline persistence is the local cache + sync (spec §9).
        let settings = FirestoreSettings()
        settings.cacheSettings = PersistentCacheSettings()
        Firestore.firestore().settings = settings
        _auth = State(initialValue: AuthService())
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
    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("Today", systemImage: "circle.dashed") }
            LogHubView()
                .tabItem { Label("Log", systemImage: "plus.circle.fill") }
            WorkoutView()
                .tabItem { Label("Workout", systemImage: "dumbbell.fill") }
            ProgressDashboardView()
                .tabItem { Label("Progress", systemImage: "chart.xyaxis.line") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}
