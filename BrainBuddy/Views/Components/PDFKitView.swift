import PDFKit
import SwiftUI

/// Thin `PDFView` wrapper so stored PDFs are readable in place rather than
/// needing an export to another app.
struct PDFKitView: UIViewRepresentable {
    let data: Data

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        view.document = PDFDocument(data: data)
        context.coordinator.loadedByteCount = data.count
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        // Rebuilding the document on every layout pass would reset the reader's
        // scroll position, and re-parsing a large PDF is expensive — so only
        // reload when the bytes actually changed.
        guard context.coordinator.loadedByteCount != data.count else { return }
        context.coordinator.loadedByteCount = data.count
        view.document = PDFDocument(data: data)
    }

    final class Coordinator {
        var loadedByteCount: Int?
    }
}
