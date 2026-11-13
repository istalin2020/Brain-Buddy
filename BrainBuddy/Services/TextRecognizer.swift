import Foundation
import UIKit
import Vision

/// On-device OCR. Every photo and scanned page goes through here so that images
/// become searchable text instead of opaque blobs.
///
/// Recognition is Apple's; the reading order is ours. See `TextLayout` for why
/// the boxes Vision returns are regrouped into printed rows rather than joined
/// in the order they arrive.
enum TextRecognizer {
    /// Bumped whenever how text is read out of an image changes, so anything
    /// read the old way is read again once — see
    /// `IngestService.rereadDocumentsIfNeeded`.
    static let layoutVersion = 2

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

                let pieces: [TextLayout.Piece] = (request.results ?? []).compactMap { observation in
                    guard let text = observation.topCandidates(1).first?.string else { return nil }
                    // The observation is a quadrilateral, so its top edge gives
                    // the text's own slope — which is how a tilted photo of a
                    // table is read back as level rows.
                    let run = observation.topRight.x - observation.topLeft.x
                    let rise = observation.topRight.y - observation.topLeft.y
                    return TextLayout.Piece(
                        text: text,
                        box: observation.boundingBox,
                        slope: run > 0.001 ? Double(rise / run) : 0
                    )
                }
                continuation.resume(returning: TextLayout.text(from: pieces))
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
