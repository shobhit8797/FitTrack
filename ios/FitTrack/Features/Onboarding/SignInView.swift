import AuthenticationServices
import CryptoKit
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

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.l) {
                VStack(spacing: Theme.Spacing.s) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Theme.accentTeal)
                    Text("FitTrack").font(.largeTitle.bold())
                    Text("Your plan, your numbers.")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, Theme.Spacing.xl)

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

                Button(isSignUp ? "Create account" : "Sign in") {
                    Task { await submitEmail() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accentTeal)
                .frame(maxWidth: .infinity)
                .disabled(busy || email.isEmpty || password.isEmpty)

                Button(isSignUp ? "Have an account? Sign in" : "New here? Create an account") {
                    isSignUp.toggle()
                }
                .font(.footnote)

                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                }

                Text("FitTrack provides general fitness information and is not medical advice.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top)
            }
            .padding(Theme.Spacing.l)
        }
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

// Thin seam over the Google Identity SDK. Real implementation calls
// GIDSignIn.sharedInstance.signIn(withPresenting:) and returns its tokens.
enum GoogleSignInHelper {
    struct Tokens { let idToken: String; let accessToken: String }
    static func signIn() async throws -> Tokens {
        throw AuthError.underlying("Google Sign-In SDK not yet wired — add GoogleSignIn via SPM and implement GIDSignIn flow.")
    }
}
