import SwiftUI
import UIKit

struct ReaderHardwareKeyCapture: UIViewRepresentable {
    var onKey: (ReaderHardwareKey) -> Void

    func makeUIView(context: Context) -> KeyView {
        let view = KeyView()
        view.onKey = onKey
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ uiView: KeyView, context: Context) { uiView.onKey = onKey; uiView.requestFocus() }

    final class KeyView: UIView {
        var onKey: ((ReaderHardwareKey) -> Void)?
        override var canBecomeFirstResponder: Bool { true }
        override func didMoveToWindow() { super.didMoveToWindow(); requestFocus() }
        func requestFocus() { DispatchQueue.main.async { [weak self] in _ = self?.becomeFirstResponder() } }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var handled = false
            for press in presses {
                guard let code = press.key?.keyCode, let mapped = Self.map(code) else { continue }
                handled = true; onKey?(mapped)
            }
            if !handled { super.pressesBegan(presses, with: event) }
        }

        private static func map(_ code: UIKeyboardHIDUsage) -> ReaderHardwareKey? {
            switch code {
            case .keyboardLeftArrow: return .left
            case .keyboardRightArrow: return .right
            case .keyboardUpArrow: return .up
            case .keyboardDownArrow: return .down
            case .keyboardPageUp: return .pageUp
            case .keyboardPageDown: return .pageDown
            case .keyboardSpacebar: return .space
            case .keyboardReturnOrEnter: return .enter
            default: return nil
            }
        }
    }
}
