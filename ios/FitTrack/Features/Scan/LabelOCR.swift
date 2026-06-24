import UIKit
import Vision

// Nutrition-label OCR (spec §7.3): run Vision's text recognizer on a captured
// label image to extract raw text, which we send (with the image) to
// functions.parseLabel for structured per-serving / per-100g macros.

enum LabelOCR {
    /// Recognize text in `image` and return the joined lines, or nil if none.
    /// Uses accurate recognition with language correction for printed labels.
    static func recognizeText(in image: UIImage) async -> String? {
        guard let cgImage = image.cgImage else { return nil }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                let joined = lines.joined(separator: "\n")
                continuation.resume(returning: joined.isEmpty ? nil : joined)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: image.cgOrientation, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}

private extension UIImage {
    /// Map UIImage orientation onto the CGImagePropertyOrientation Vision expects.
    var cgOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
