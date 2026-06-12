import SwiftUI
import UIKit

struct PromptTextView: UIViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> PromptUITextView {
        let textView = PromptUITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = UIColor.secondarySystemBackground
        textView.layer.cornerRadius = 8
        textView.layer.borderWidth = 1
        textView.layer.borderColor = UIColor.separator.cgColor
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.isScrollEnabled = true
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.textContainer.widthTracksTextView = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.returnKeyType = .send
        textView.shiftEnterHandler = { [weak textView, weak coordinator = context.coordinator] in
            guard let textView, let coordinator else { return }
            coordinator.insertNewline(in: textView)
        }
        return textView
    }

    func updateUIView(_ uiView: PromptUITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        uiView.shiftEnterHandler = { [weak uiView, weak coordinator = context.coordinator] in
            guard let uiView, let coordinator else { return }
            coordinator.insertNewline(in: uiView)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PromptTextView
        private var isInsertingNewline = false

        init(parent: PromptTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n" && !isInsertingNewline {
                handleSubmit()
                return false
            }
            return true
        }

        func handleSubmit() {
            parent.onSubmit()
        }

        func insertNewline(in textView: UITextView) {
            isInsertingNewline = true
            textView.insertText("\n")
            parent.text = textView.text
            isInsertingNewline = false
        }
    }
}

final class PromptUITextView: UITextView {
    var shiftEnterHandler: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: "\r", modifierFlags: [.shift], action: #selector(handleShiftEnter), discoverabilityTitle: "Insert Line Break")
        ]
    }

    @objc private func handleShiftEnter(_ sender: UIKeyCommand) {
        shiftEnterHandler?()
    }
}
