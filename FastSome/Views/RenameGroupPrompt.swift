import AppKit

/// Plain rename window: title, text field, OK / Cancel. No alert icon.
@MainActor
enum RenameGroupPrompt {
    static func run(currentName: String) -> String? {
        let controller = PromptController(currentName: currentName)
        NSApp.runModal(for: controller.window)
        return controller.result
    }

    private final class PromptController: NSObject, NSWindowDelegate {
        let window: NSWindow
        private let field: NSTextField
        var result: String?

        init(currentName: String) {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 110),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.title = "重命名分组"
            window.isReleasedWhenClosed = false

            let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 110))
            window.contentView = content

            let field = NSTextField(frame: NSRect(x: 20, y: 52, width: 280, height: 24))
            field.stringValue = currentName
            field.isEditable = true
            field.isSelectable = true
            field.bezelStyle = .roundedBezel
            content.addSubview(field)
            self.field = field

            let cancel = NSButton(frame: NSRect(x: 148, y: 14, width: 72, height: 28))
            cancel.title = "取消"
            cancel.bezelStyle = .rounded
            cancel.keyEquivalent = "\u{1b}"
            content.addSubview(cancel)

            let ok = NSButton(frame: NSRect(x: 228, y: 14, width: 72, height: 28))
            ok.title = "确定"
            ok.bezelStyle = .rounded
            ok.keyEquivalent = "\r"
            content.addSubview(ok)

            self.window = window
            super.init()

            window.delegate = self
            ok.target = self
            ok.action = #selector(okClicked)
            cancel.target = self
            cancel.action = #selector(cancelClicked)

            window.center()
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(field)
            field.selectText(nil)
        }

        @objc private func okClicked() {
            result = field.stringValue
            closeModal()
        }

        @objc private func cancelClicked() {
            result = nil
            closeModal()
        }

        private func closeModal() {
            window.orderOut(nil)
            NSApp.stopModal()
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            result = nil
            NSApp.stopModal()
            return true
        }
    }
}
