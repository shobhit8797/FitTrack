import AuthenticationServices
import CryptoKit
import GoogleSignIn
import SwiftUI

// Sign-in screen offering all three methods (spec §6a, §15 phase 3). After any
// method succeeds the rest of the app is identical (carries the Firebase session).
struct SignInView: View {
    @Environment(AuthService.self) private var auth
    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false
    @State private var error: String?
    @State private var busy = false
    @State private var currentNonce: String?
    @State private var resetSentTo: String?

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.l) {
                VStack(spacing: Theme.Spacing.m) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 84, height: 84)
                        .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: Theme.accentTeal.opacity(0.35), radius: 14, y: 8)
                        .accessibilityHidden(true)
                    VStack(spacing: Theme.Spacing.xs) {
                        Text("FitTrack")
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        Text("Your plan, your numbers.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.s)

                // Apple
                SignInWithAppleButton(.signIn) { request in
                    let nonce = randomNonce()
                    currentNonce = nonce
                    request.requestedScopes = [.fullName, .email]
                    request.nonce = sha256(nonce)
                } onCompletion: { result in
                    handleApple(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // Google (delegates to the Google Identity SDK in GoogleSignInHelper)
                Button {
                    Task { await signInWithGoogle() }
                } label: {
                    Label("Continue with Google", systemImage: "g.circle.fill")
                        .frame(maxWidth: .infinity).frame(height: 50)
                }
                .buttonStyle(.bordered)

                HStack { Divider(); Text("or").foregroundStyle(.secondary); Divider() }

                // Email
                VStack(spacing: Theme.Spacing.s) {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $password)
                        .textContentType(isSignUp ? .newPassword : .password)
                }
                .textFieldStyle(.roundedBorder)

                Button {
                    Haptics.tap()
                    Task { await submitEmail() }
                } label: {
                    Text(busy ? "Please wait…" : (isSignUp ? "Create account" : "Sign in"))
                }
                .buttonStyle(PrimaryButtonStyle(enabled: !(busy || email.isEmpty || password.isEmpty)))
                .disabled(busy || email.isEmpty || password.isEmpty)

                Button(isSignUp ? "Have an account? Sign in" : "New here? Create an account") {
                    isSignUp.toggle()
                    error = nil
                    resetSentTo = nil
                }
                .font(.footnote)

                // Recovery path for email/password users (Firebase sends the link).
                if !isSignUp {
                    Button("Forgot password?") {
                        Haptics.tap()
                        Task { await sendReset() }
                    }
                    .font(.footnote)
                    .disabled(busy)
                }

                if let resetSentTo {
                    Label("Reset link sent to \(resetSentTo). Check your inbox, set a new password, then sign in here.",
                          systemImage: "envelope.badge.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.accentTeal)
                        .multilineTextAlignment(.center)
                }

                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                }

                Text("FitTrack provides general fitness information and is not medical advice.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top)
            }
            .padding(Theme.Spacing.l)
            .frame(maxWidth: 440) // keeps the column comfortable on larger phones
            .frame(maxWidth: .infinity)
        }
        .background(ScreenBackground())
    }

    private func submitEmail() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            if isSignUp {
                try await auth.signUp(email: email, password: password)
            } else {
                try await auth.signIn(email: email, password: password)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func sendReset() async {
        guard !email.isEmpty else {
            error = "Enter your email above first, then tap Forgot password."
            return
        }
        busy = true; error = nil; resetSentTo = nil
        defer { busy = false }
        do {
            try await auth.sendPasswordReset(email: email)
            Haptics.success()
            resetSentTo = email
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let token = String(data: tokenData, encoding: .utf8),
                let nonce = currentNonce
            else { error = "Apple sign-in failed."; return }
            Task {
                do {
                    try await auth.signInWithApple(idTokenString: token, rawNonce: nonce, fullName: credential.fullName)
                } catch { self.error = error.localizedDescription }
            }
        case .failure(let err):
            error = err.localizedDescription
        }
    }

    private func signInWithGoogle() async {
        do {
            let tokens = try await GoogleSignInHelper.signIn()
            try await auth.signInWithGoogle(idToken: tokens.idToken, accessToken: tokens.accessToken)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // Nonce helpers required by Sign in with Apple + Firebase.
    private func randomNonce(length: Int = 32) -> String {
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var random: UInt8 = 0
            _ = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            if random < UInt8(chars.count) {
                result.append(chars[Int(random)])
                remaining -= 1
            }
        }
        return result
    }

    private func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// Thin seam over the Google Identity SDK (spec §6a). Drives
// GIDSignIn.sharedInstance.signIn(withPresenting:) and returns its tokens, which
// AuthService.signInWithGoogle(idToken:accessToken:) trades for a Firebase session.
//
// Xcode/project setup required (outside these files):
//   • Add the GoogleSignIn SDK via Swift Package Manager.
//   • Set `GIDClientID` in Info.plist (== `CLIENT_ID` from GoogleService-Info.plist),
//     or configure GIDConfiguration with that client ID at launch.
//   • Add the reversed client ID (`REVERSED_CLIENT_ID`) as a URL scheme under
//     CFBundleURLTypes so the OAuth callback can return to the app, and forward
//     the callback URL via `GIDSignIn.sharedInstance.handle(_:)` from
//     `onOpenURL`/the scene delegate.
enum GoogleSignInHelper {
    struct Tokens { let idToken: String; let accessToken: String }

    @MainActor
    static func signIn() async throws -> Tokens {
        // GIDSignIn reads its client ID from `GIDClientID` in Info.plist by default.
        // If you prefer to configure programmatically, set
        // `GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID:)`
        // with the CLIENT_ID from GoogleService-Info.plist before calling signIn.
        guard let presenter = topViewController() else {
            throw AuthError.underlying("No presenting view controller for Google Sign-In.")
        }

        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthError.missingToken
        }
        let accessToken = result.user.accessToken.tokenString
        return Tokens(idToken: idToken, accessToken: accessToken)
    }

    /// Resolves the foreground key window's top-most view controller to present from.
    @MainActor
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let keyWindow = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
