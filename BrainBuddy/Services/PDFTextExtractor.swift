import Foundation
import PDFKit
import UIKit

/// Pulls searchable text out of a PDF.
///
/// Most PDFs carry a text layer, which is fast and exact. Scanned PDFs do not,
/// so when the text layer comes back near-empty we rasterize pages and OCR them
/// — otherwise a scanned contract would sit in your brain permanently unfindable.
enum PDFTextExtractor {
    struct Result {
        var text: String = ""
        var pageCount: Int = 0
        var thumbnail: Data?
        var usedOCR: Bool = false
    }

    /// Below this many characters per page we assume there is no real text layer.
    private static let charactersPerPageThreshold = 24
    /// OCR is expensive; cap it so importing a 900-page scan cannot hang.
    private static let maximumOCRPages = 40

    static func extract(from url: URL) async -> Result {
        guard let document = PDFDocument(url: url) else { return Result() }
        return await extract(from: document)
    }

    static func extract(from data: Data) async -> Result {
        guard let document = PDFDocument(data: data) else { return Result() }
        return await extract(from: document)
    }

    static func extract(from document: PDFDocument) async -> Result {
        var result = Result()
        result.pageCount = document.pageCount
        result.thumbnail = thumbnail(for: document)

        var pieces: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let text = page.string else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { pieces.append(trimmed) }
        }

        let layerText = pieces.joined(separator: "\n\n")
        let density = document.pageCount > 0 ? layerText.count / document.pageCount : layerText.count

        if density >= charactersPerPageThreshold {
            result.text = layerText
            return result
        }

        let recognized = await ocrText(in: document)
        result.usedOCR = !recognized.isEmpty
        // Keep whatever thin text layer existed; it costs nothing and sometimes
        // holds the title even when the body is a scan.
        result.text = [layerText, recognized]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return result
    }

    // MARK: - Internals

    private static func ocrText(in document: PDFDocument) async -> String {
        let pageLimit = min(document.pageCount, maximumOCRPages)
        guard pageLimit > 0 else { return "" }

        var pages: [String] = []
        for index in 0..<pageLimit {
            guard let page = document.page(at: index) else { continue }
            let image = render(page: page)
            guard let cgImage = image?.cgImage else { continue }
            let text = await TextRecognizer.recognizeText(in: cgImage)
            if !text.isEmpty { pages.append(text) }
        }
        return pages.joined(separator: "\n\n")
    }

    /// Renders at 2x so small print survives OCR.
    private static func render(page: PDFPage, scale: CGFloat = 2.0) -> UIImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        return page.thumbnail(of: size, for: .mediaBox)
    }

    private static func thumbnail(for document: PDFDocument) -> Data? {
        guard let page = document.page(at: 0) else { return nil }
        let image = page.thumbnail(of: CGSize(width: 300, height: 400), for: .mediaBox)
        return image.jpegData(compressionQuality: 0.7)
    }
}
