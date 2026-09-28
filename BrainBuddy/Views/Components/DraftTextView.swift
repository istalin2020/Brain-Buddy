import SwiftUI
import UIKit

/// The Input box: a text view that says where the cursor is.
///
/// SwiftUI's `TextEditor` cannot report the cursor on iOS 17 — the selection
/// binding arrived in iOS 18 — and without the cursor, dictation had nowhere
/// to put words but the end of the note. This wraps `UITextView`, which has
/// always known, and reports two different things separately, because the
/// dictation splice treats them differently:
///
/// - **`onEdit`** — you changed the text: typed, deleted, pasted.
/// - **`onSelect`** — you moved the cursor or selected, and nothing changed.
///
/// Changes the app makes itself — words arriving while you dictate — are
/// applied without echoing back as either, so they can never be mistaken for
/// something you did.
struct DraftTextView: UIViewRepresentable {
    let text: String
    let selection: NSRange
    @Binding var isFocused: Bool
    var minHeight: CGFloat = 104
    var onEdit: (String, NSRange) -> Void
    var onSelect: (String, NSRange) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        // Grows with its text rather than scrolling inside a scroll view.
        view.isScrollEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        // Never while the keyboard is composing — a transliterating or
        // predictive keyboard holds marked text, and replacing the text under
        // it breaks what you are in the middle of typing.
        guard view.markedTextRange == nil else { return }

        if view.text != text {
            coordinator.isApplying = true
            view.text = text
            coordinator.isApplying = false
        }

        let length = (view.text as NSString).length
        let location = min(max(0, selection.location), length)
        let wanted = NSRange(location: location, length: min(max(0, selection.length), length - location))
        if view.selectedRange != wanted {
            coordinator.isApplying = true
            view.selectedRange = wanted
            coordinator.isApplying = false
            if view.isFirstResponder { view.scrollRangeToVisible(wanted) }
        }

        // Focus follows the binding, a pass later: changing the first
        // responder inside a view update is what SwiftUI warns about.
        if isFocused != view.isFirstResponder {
            let shouldFocus = isFocused
            DispatchQueue.main.async {
                if shouldFocus { view.becomeFirstResponder() } else { view.resignFirstResponder() }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(minHeight, fitted.height))
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: DraftTextView
        /// True while the app itself is changing the text or cursor.
        var isApplying = false

        init(_ parent: DraftTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ view: UITextView) {
            guard !isApplying, view.markedTextRange == nil else { return }
            parent.onEdit(view.text, view.selectedRange)
        }

        func textViewDidChangeSelection(_ view: UITextView) {
            guard !isApplying, view.markedTextRange == nil else { return }
            // Sent with the text as it stands, so a cursor move that arrives
            // a moment before its own edit can be recognised and ignored — the
            // edit that follows carries the same cursor.
            parent.onSelect(view.text, view.selectedRange)
        }

        func textViewDidBeginEditing(_ view: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ view: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }
    }
}
