import SwiftUI
import VisionKit

/// VisionKit's document scanner, which handles edge detection, perspective
/// correction and multi-page capture far better than a raw camera shot — and
/// straight pages make OCR dramatically more accurate.
struct DocumentScannerView: UIViewControllerRepresentable {
    /// Declared `@MainActor` because that is the truth: VisionKit delivers these
    /// callbacks on the main thread, and the handlers touch view state and the
    /// model context. Saying so lets the call site stay ordinary SwiftUI instead
    /// of hopping actors by hand.
    var onFinish: @MainActor ([UIImage]) -> Void
    var onCancel: @MainActor () -> Void

    /// The scanner needs a real camera; the Simulator has none.
    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let onFinish: @MainActor ([UIImage]) -> Void
        private let onCancel: @MainActor () -> Void

        init(
            onFinish: @escaping @MainActor ([UIImage]) -> Void,
            onCancel: @escaping @MainActor () -> Void
        ) {
            self.onFinish = onFinish
            self.onCancel = onCancel
        }

        // VisionKit guarantees main-thread delivery for these, so asserting the
        // isolation is accurate — and it keeps the handlers synchronous, which
        // matters for `onCancel`: dismissing a sheet a run loop late is visible.
        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            var pages: [UIImage] = []
            for index in 0..<scan.pageCount {
                pages.append(scan.imageOfPage(at: index))
            }
            MainActor.assumeIsolated { onFinish(pages) }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            MainActor.assumeIsolated { onCancel() }
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            MainActor.assumeIsolated { onCancel() }
        }
    }
}
