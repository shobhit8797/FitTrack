import AuthenticationServices
import FirebaseAuth
import Foundation

// Identity (spec §6a). Firebase Auth handles Apple / Google / email and persists
// the session token in the Keychain itself, issuing one unified user regardless
// of provider. Account-linking by verified email is Firebase-native.

enum AuthError: LocalizedError {
    case missingToken
    case cancelled
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .missingToken: return "Sign-in token was missing."
        case .cancelled: return "Sign-in was cancelled."
        case .underlying(let m): return m
        }
    }
}

@Observable
final class AuthService {
    private(set) var uid: String?
    private(set) var isSignedIn = false
    private(set) var displayName: String?
    private var handle: AuthStateDidChangeListenerHandle?

    init() {
        // Demo mode: present a signed-in "Alex" without touching Firebase Auth so
        // the marketing walkthrough lands straight on the populated main tabs.
        if Demo.isActive {
            uid = "demo"
            isSignedIn = true
            displayName = "Alex"
            return
        }
        handle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            self?.uid = user?.uid
            self?.isSignedIn = user != nil
            self?.displayName = user?.displayName
            // Signed out: blank the home-screen widgets rather than leave the
            // previous account's numbers on the home screen.
            if user == nil { Repository.clearWidgetSnapshot() }
        }
    }

    deinit {
        if let handle { Auth.auth().removeStateDidChangeListener(handle) }
    }

    // MARK: Email + password (spec §6a)
    func signUp(email: String, password: String) async throws {
        do {
            let result = try await Auth.auth().createUser(withEmail: email, password: password)
            try await result.user.sendEmailVerification()
        } catch {
            throw AuthError.underlying(error.localizedDescription)
        }
    }

    func signIn(email: String, password: String) async throws {
        do {
            try await Auth.auth().signIn(withEmail: email, password: password)
        } catch {
            throw AuthError.underlying(error.localizedDescription)
        }
    }

    func sendPasswordReset(email: String) async throws {
        try await Auth.auth().sendPasswordReset(withEmail: email)
    }

    // MARK: Apple (spec §6a)
    /// Pass the nonce used in the ASAuthorizationAppleIDRequest (raw, unhashed).
    func signInWithApple(idTokenString: String, rawNonce: String, fullName: PersonNameComponents?) async throws {
        let credential = OAuthProvider.appleCredential(
            withIDToken: idTokenString,
            rawNonce: rawNonce,
            fullName: fullName
        )
        do {
            let result = try await Auth.auth().signIn(with: credential)
            // Apple returns the name only on first consent — capture it once.
            if let fullName, result.user.displayName == nil {
                let req = result.user.createProfileChangeRequest()
                req.displayName = PersonNameComponentsFormatter().string(from: fullName)
                try? await req.commitChanges()
            }
        } catch {
            throw AuthError.underlying(error.localizedDescription)
        }
    }

    // MARK: Google (spec §6a)
    /// `idToken`/`accessToken` come from the Google Identity SDK sign-in result.
    func signInWithGoogle(idToken: String, accessToken: String) async throws {
        let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: accessToken)
        do {
            try await Auth.auth().signIn(with: credential)
        } catch {
            throw AuthError.underlying(error.localizedDescription)
        }
    }

    func signOut() throws {
        try Auth.auth().signOut()
    }
}
