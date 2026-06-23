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
    struct OnboardingResult: Decodable {
        let targets: Targets
        let plan: WorkoutPlan?
        let planError: String?
    }

    func completeOnboarding(profile: [String: Any]) async throws -> OnboardingResult {
        try await call("completeOnboarding", ["profile": profile], as: OnboardingResult.self)
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
            let calories: Int?; let proteinG: Double?; let carbsG: Double?; let fatG: Double?
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
