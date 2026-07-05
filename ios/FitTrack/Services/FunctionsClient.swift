import FirebaseFunctions
import Foundation

// Typed wrappers over the callable Cloud Functions (spec §10–11). The app never
// holds an AI key — it calls these, which proxy to OpenRouter/Gemini server-side.

enum FunctionsError: LocalizedError {
    case aiUnavailable
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .aiUnavailable:
            return "Couldn't read the AI response — please try again."
        case .underlying(let m):
            return m
        }
    }
}

@Observable
final class FunctionsClient {
    private let functions = Functions.functions(region: "us-central1")

    private func call<T: Decodable>(_ name: String, _ payload: [String: Any], as: T.Type) async throws -> T {
        do {
            let result = try await functions.httpsCallable(name).call(payload)
            let data = try JSONSerialization.data(withJSONObject: result.data)
            return try JSONDecoder.fittrack.decode(T.self, from: data)
        } catch let error as NSError {
            if error.domain == FunctionsErrorDomain,
               FunctionsErrorCode(rawValue: error.code) == .unavailable {
                throw FunctionsError.aiUnavailable
            }
            throw FunctionsError.underlying(error.localizedDescription)
        }
    }

    // MARK: Onboarding / targets
    // completeOnboarding now returns only the computed targets — the workout plan
    // is generated asynchronously server-side and streamed in via the profile's
    // planStatus + Repository.planStream(), so onboarding never blocks on the LLM.
    struct OnboardingResult: Decodable {
        let targets: Targets
    }

    func completeOnboarding(profile: [String: Any]) async throws -> OnboardingResult {
        try await call("completeOnboarding", ["profile": profile], as: OnboardingResult.self)
    }

    /// Persist edits to an existing profile and recompute targets server-side
    /// (spec §5). Same payload shape as onboarding; returns the fresh targets.
    /// Does not regenerate plans — the user does that explicitly from Settings.
    func updateProfile(profile: [String: Any]) async throws -> Targets {
        try await call("updateProfile", ["profile": profile], as: OnboardingResult.self).targets
    }

    /// Request (or re-request) workout / diet plan generation. Flips the relevant
    /// *PlanStatus to "generating" server-side; the async trigger runs the matching
    /// Lyzr agent and streams the plan + status back into the profile.
    struct WorkoutPlanStatusResult: Decodable { let workoutPlanStatus: String }
    @discardableResult
    func generateWorkoutPlan() async throws -> String {
        try await call("generateWorkoutPlan", [:], as: WorkoutPlanStatusResult.self).workoutPlanStatus
    }

    struct DietPlanStatusResult: Decodable { let dietPlanStatus: String }
    @discardableResult
    func generateDietPlan() async throws -> String {
        try await call("generateDietPlan", [:], as: DietPlanStatusResult.self).dietPlanStatus
    }

    // MARK: Diet coach chat (build a 7-day plan by chatting)
    struct CoachReply: Decodable { let reply: String; let readyToGenerate: Bool }

    /// One conversational turn. The full transcript is relayed each call (the
    /// backend is stateless); returns the coach's reply + whether it's ready to build.
    func dietCoachReply(messages: [[String: String]]) async throws -> CoachReply {
        try await call("dietCoachReply", ["messages": messages], as: CoachReply.self)
    }

    /// Generate a 7-day plan from the planning transcript. Flips dietPlanStatus
    /// server-side and writes dietPlans/current; the Diet tab streams it in.
    @discardableResult
    func generateDietPlanFromChat(messages: [[String: String]]) async throws -> String {
        try await call("generateDietPlanFromChat", ["messages": messages],
                       as: DietPlanStatusResult.self).dietPlanStatus
    }

    struct TargetsResult: Decodable { let targets: Targets }
    func recomputeTargets(inputs: [String: Any]) async throws -> Targets {
        try await call("recomputeTargets", ["inputs": inputs], as: TargetsResult.self).targets
    }

    // MARK: AI food
    struct FoodAnalysisResult: Decodable { let items: [AnalyzedFoodItem] }

    func analyzeMeal(jpegBase64: String) async throws -> [AnalyzedFoodItem] {
        try await call(
            "analyzeMeal",
            ["image": ["base64": jpegBase64, "mimeType": "image/jpeg"]],
            as: FoodAnalysisResult.self
        ).items
    }

    func estimateText(_ description: String) async throws -> [AnalyzedFoodItem] {
        try await call("estimateText", ["description": description], as: FoodAnalysisResult.self).items
    }

    struct LabelResult: Decodable {
        struct Macro: Decodable {
            let calories: Int?; let proteinG: Double?; let carbsG: Double?; let fatG: Double?; let fiberG: Double?
        }
        let productName: String?
        let brand: String?
        let servingSize: String?
        let perServing: Macro
        let per100g: Macro
        let confidence: Double
    }
    struct LabelEnvelope: Decodable { let label: LabelResult }

    func parseLabel(ocrText: String?, jpegBase64: String?) async throws -> LabelResult {
        var payload: [String: Any] = [:]
        if let ocrText { payload["ocrText"] = ocrText }
        if let jpegBase64 { payload["image"] = ["base64": jpegBase64, "mimeType": "image/jpeg"] }
        return try await call("parseLabel", payload, as: LabelEnvelope.self).label
    }

    // MARK: Food / exercise lookup
    struct BarcodeResult: Decodable {
        let product: CachedProduct?
        let notFound: Bool?
    }
    struct CachedProduct: Decodable {
        let barcode: String
        let productName: String?
        let brand: String?
        let servingSize: String?
        let perServing: LabelResult.Macro
        let per100g: LabelResult.Macro
    }
    func foodBarcode(_ code: String) async throws -> CachedProduct? {
        try await call("foodBarcode", ["barcode": code], as: BarcodeResult.self).product
    }

    struct ExerciseSearchResult: Decodable { let results: [Exercise] }
    func searchExercises(_ query: String) async throws -> [Exercise] {
        try await call("searchExercises", ["search": query], as: ExerciseSearchResult.self).results
    }
}

extension JSONDecoder {
    /// Shared decoder: Firestore callable JSON uses seconds-based timestamps and
    /// ISO strings in places — keep it lenient.
    static let fittrack: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
