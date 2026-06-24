import FirebaseFunctions
import Foundation

// Exercise-catalog lookup (spec §7.2): resolve a planned exercise to its catalog
// entry so the plan view can link to the real how-to videoUrl. Wraps the
// "getExercise" callable; falls back to searchExercises when only a name is known.
//
// Note: Repository/FunctionsClient keep their generic `call<T>` helper file-private,
// so this extension mirrors that wrap-and-decode pattern inline rather than reusing it.

extension FunctionsClient {
    private struct ExerciseEnvelope: Decodable { let exercise: Exercise? }

    /// Fetch a catalog exercise by id. Returns nil if the catalog has no match.
    func getExercise(id: String) async throws -> Exercise? {
        let functions = Functions.functions(region: "us-central1")
        do {
            let result = try await functions.httpsCallable("getExercise").call(["id": id])
            let data = try JSONSerialization.data(withJSONObject: result.data)
            return try JSONDecoder.fittrack.decode(ExerciseEnvelope.self, from: data).exercise
        } catch let error as NSError {
            if error.domain == FunctionsErrorDomain,
               FunctionsErrorCode(rawValue: error.code) == .unavailable {
                throw FunctionsError.aiUnavailable
            }
            throw FunctionsError.underlying(error.localizedDescription)
        }
    }

    /// Resolve a planned exercise (id when present, else name) to its catalog
    /// entry. Used by the plan view to surface the real videoUrl.
    func resolveExercise(id: String?, name: String) async throws -> Exercise? {
        if let id, !id.isEmpty {
            if let ex = try await getExercise(id: id) { return ex }
        }
        let results = try await searchExercises(name)
        // Prefer an exact (case-insensitive) name match, else the first result.
        return results.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            ?? results.first
    }
}
