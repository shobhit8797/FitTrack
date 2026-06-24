import UIKit

// Image downscale + JPEG/base64 helper (spec §7.3, §13). Photos are only ever
// encoded here on explicit user action, then handed to the AI Cloud Functions —
// keep payloads small (≤ ~1024px, quality ~0.7) so calls stay fast and cheap.

enum ImageEncoding {
    /// Downscale so the longest edge is at most `maxDimension`, preserving aspect.
    static func downscaled(_ image: UIImage, maxDimension: CGFloat = 1024) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let scale = maxDimension / longest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1 // target is already in points-as-pixels
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
    }

    /// Downscale + JPEG-encode + base64 in one step, ready for the AI functions.
    static func jpegBase64(_ image: UIImage, maxDimension: CGFloat = 1024, quality: CGFloat = 0.7) -> String? {
        downscaled(image, maxDimension: maxDimension)
            .jpegData(compressionQuality: quality)?
            .base64EncodedString()
    }
}
