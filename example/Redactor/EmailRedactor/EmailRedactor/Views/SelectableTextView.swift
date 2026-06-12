import SwiftUI
import UIKit

struct SelectableTextView: UIViewRepresentable {
    @Binding var text: String
    var onSelection: (String) -> Void

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = UIColor.systemBackground
        textView.text = text
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelection: onSelection)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private var onSelection: (String) -> Void

        init(onSelection: @escaping (String) -> Void) {
            self.onSelection = onSelection
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard let range = textView.selectedTextRange else { return }
            let selected = textView.text(in: range) ?? ""
            onSelection(selected.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
