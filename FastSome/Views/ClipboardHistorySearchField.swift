import AppKit
import SwiftUI

/// Borderless AppKit text field for the clipboard panel search bar.
///
/// IMPORTANT: Do not set `target`/`action` for submit.
/// AppKit can call the action from `textDidEndEditing` when the field gains/loses
/// first responder — that was instantly closing the panel on show (selectItem).
struct ClipboardHistorySearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    var focusToken: Int
    var syncToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: "")
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.isEditable = true
        field.isSelectable = true
        field.focusRingType = .none
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.font = .systemFont(ofSize: 20, weight: .regular)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.usesSingleLineMode = true
        // No target/action — submit only via Return in the field editor.
        field.target = nil
        field.action = nil
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 20, weight: .regular)

        if syncToken != context.coordinator.lastSyncToken {
            context.coordinator.lastSyncToken = syncToken
            field.stringValue = text
        }

        if focusToken != context.coordinator.lastFocusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                // Avoid makeKeyAndOrderFront — it can yank the user out of a
                // fullscreen Space. makeKey is enough for the search field.
                if !window.isKeyWindow {
                    window.makeKey()
                }
                window.makeFirstResponder(field)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ClipboardHistorySearchField
        weak var field: NSTextField?
        var lastFocusToken: Int = -1
        var lastSyncToken: Int = -1

        init(_ parent: ClipboardHistorySearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let value = field.stringValue
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.parent.text != value {
                    self.parent.text = value
                }
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                NotificationCenter.default.post(
                    name: .clipboardHistoryMoveSelection,
                    object: nil,
                    userInfo: ["delta": 1]
                )
                return true
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                NotificationCenter.default.post(
                    name: .clipboardHistoryMoveSelection,
                    object: nil,
                    userInfo: ["delta": -1]
                )
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                DispatchQueue.main.async {
                    ClipboardHistoryPanelController.shared.hide(reason: "search-escape")
                }
                return true
            }
            return false
        }
    }
}
