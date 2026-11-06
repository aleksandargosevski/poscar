import AppKit
import SwiftUI

/// A borderless text field that takes keyboard focus as soon as it is on screen.
/// SwiftUI's @FocusState is unreliable for fields inside overlays that appear with an animation.
struct FocusedTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat = 17

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> AutoFocusTextField {
        let field = AutoFocusTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: AutoFocusTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

final class AutoFocusTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }
}
