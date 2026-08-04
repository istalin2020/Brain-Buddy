import Foundation
import UIKit
import Vision

/// On-device OCR. Every photo and scanned page goes through here so that images
/// become searchable text instead of opaque blobs.
enum TextRecognizer {
    /// Recognizes text in an image, preserving reading order.
    static func recognizeText(in image: UIImage) async -> String {
        guard let cgImage = image.cgImage else { return "" }
        return await recognizeText(in: cgImage)
    }

    static func recognizeText(in cgImage: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            // Vision is synchronous and CPU-heavy; keep it off the main thread.
            DispatchQueue.global(qos: .userInitiated).async {
                // Leaving `recognitionLanguages` unset lets Vision use the
                // user's preferred languages, which is more accurate than
                // enabling every supported language at once.
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true

                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: "")
                    return
                }

                let observations = request.results ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
        }
    }

    /// JPEG preview sized for list rows, so scrolling never decodes full images.
    static func thumbnail(from image: UIImage, maximumDimension: CGFloat = 400) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maximumDimension / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: target)
        let scaled = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return scaled.jpegData(compressionQuality: 0.7)
    }

    /// Re-encodes a capture as JPEG. Photos arrive as HEIC or PNG at wildly
    /// different sizes; normalizing keeps CloudKit assets predictable.
    static func normalizedImageData(from image: UIImage, maximumDimension: CGFloat = 2400) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maximumDimension / max(size.width, size.height))
        guard scale < 1 else { return image.jpegData(compressionQuality: 0.85) }

        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let scaled = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return scaled.jpegData(compressionQuality: 0.85)
    }
}
