import AppKit

/// Compact confirm window without the large NSAlert icon / empty icon gap.
@MainActor
enum ConfirmPrompt {
    static func run(title: String, message: String, confirmTitle: String = "删除") -> Bool {
        let controller = PromptController(title: title, message: message, confirmTitle: confirmTitle)
        NSApp.runModal(for: controller.window)
        return controller.confirmed
    }

    private final class PromptController: NSObject, NSWindowDelegate {
        let window: NSWindow
        var confirmed = false

        init(title: String, message: String, confirmTitle: String) {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.title = title
            window.isReleasedWhenClosed = false

            let content = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 120))
            window.contentView = content

            let label = NSTextField(wrappingLabelWithString: message)
            label.frame = NSRect(x: 20, y: 48, width: 300, height: 48)
            label.isEditable = false
            label.isBordered = false
            label.drawsBackground = false
            label.font = .systemFont(ofSize: NSFont.systemFontSize)
            content.addSubview(label)

            let cancel = NSButton(frame: NSRect(x: 168, y: 14, width: 72, height: 28))
            cancel.title = "取消"
            cancel.bezelStyle = .rounded
            cancel.keyEquivalent = "\u{1b}"
            content.addSubview(cancel)

            let ok = NSButton(frame: NSRect(x: 248, y: 14, width: 72, height: 28))
            ok.title = confirmTitle
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
        }

        @objc private func okClicked() {
            confirmed = true
            closeModal()
        }

        @objc private func cancelClicked() {
            confirmed = false
            closeModal()
        }

        private func closeModal() {
            window.orderOut(nil)
            NSApp.stopModal()
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            confirmed = false
            NSApp.stopModal()
            return true
        }
    }
}
