import AppKit

@MainActor
final class StatusItemController {
    static let shared = StatusItemController()

    private var statusItem: NSStatusItem?

    var statusButton: NSStatusBarButton? { statusItem?.button }

    private init() {}

    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // Vector PDF template: set point size, AppKit rasterizes sharply for the display scale.
            let image = NSImage(named: "MenuBarIcon")
                ?? NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "FastSome")
            image?.isTemplate = true
            image?.size = NSSize(width: 18, height: 18)
            button.image = image
            button.action = #selector(clicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        // Panel off: keep the icon, but only offer Settings / Quit.
        guard AppSettings.shared.panelEnabled else {
            showMenu(sender)
            return
        }
        guard let event = NSApp.currentEvent else {
            PanelController.shared.toggle(anchor: .statusItem(sender))
            return
        }
        if event.type == .rightMouseUp {
            showMenu(sender)
        } else {
            PanelController.shared.toggle(anchor: .statusItem(sender))
        }
    }

    private func showMenu(_ sender: NSStatusBarButton) {
        let menu = NSMenu()
        if AppSettings.shared.clipboardHistoryEnabled {
            let clip = menu.addItem(
                withTitle: "剪贴板历史",
                action: #selector(openClipboardHistory),
                keyEquivalent: "v"
            )
            clip.keyEquivalentModifierMask = [.command, .option]
        }
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出 FastSome", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items {
            item.target = self
        }
        let point = NSPoint(x: sender.bounds.minX, y: sender.bounds.maxY + 2)
        menu.popUp(positioning: nil, at: point, in: sender)
    }

    @objc private func openClipboardHistory() {
        ClipboardHistoryPanelController.shared.show()
    }

    @objc private func openSettings() {
        SettingsOpener.open()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
