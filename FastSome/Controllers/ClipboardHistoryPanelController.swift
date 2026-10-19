import AppKit
import SwiftUI

@MainActor
final class ClipboardHistoryPanelController: NSObject, NSWindowDelegate {
    static let shared = ClipboardHistoryPanelController()

    private var panel: NSPanel?
    private var localKeyMonitor: Any?
    private var globalMouseMonitor: Any?
    private var mouseMonitorWork: DispatchWorkItem?
    private var isPresented = false
    /// When true, only unpinning (or force-hide for settings/disable) closes the panel.
    private(set) var isPinned = false
    /// Carbon hotkeys can fire more than once per chord (key-repeat). Ignore
    /// hotkey-driven hide for a short window after show.
    private var ignoreHotkeyHideUntil: Date = .distantPast

    private let panelSize = NSSize(width: 720, height: 500)
    /// Shift above vertical center so the panel sits a bit higher on screen.
    private let panelVerticalOffset: CGFloat = 48

    func toggle() {
        Self.log("toggle isPresented=\(isPresented) ignoreHide=\(Date() < ignoreHotkeyHideUntil)")
        guard AppSettings.shared.clipboardHistoryEnabled else {
            hide(reason: "clipboard-disabled", force: true)
            return
        }
        if isPresented {
            if isPinned {
                Self.log("toggle ignored (pinned)")
                return
            }
            if Date() < ignoreHotkeyHideUntil {
                Self.log("toggle ignored (debounce)")
                return
            }
            hide(reason: "toggle-hide")
        } else {
            show()
        }
    }

    func show() {
        Self.log("show begin")
        guard AppSettings.shared.clipboardHistoryEnabled else {
            hide(reason: "clipboard-disabled-on-show", force: true)
            return
        }
        isPresented = true
        // Absorb a second Carbon fire / key-repeat from the same key-down.
        ignoreHotkeyHideUntil = Date().addingTimeInterval(0.45)

        let panel = ensurePanel()
        panel.alphaValue = 1
        positionCentered(panel)
        // Do NOT NSApp.activate / makeKeyAndOrderFront here — that switches away from
        // another app's fullscreen Space (panel lands on a different desktop/browser).
        panel.orderFrontRegardless()
        panel.makeKey()

        installKeyMonitor()
        scheduleOutsideClickMonitor()

        NotificationCenter.default.post(name: .clipboardHistoryPanelDidShow, object: nil)
        Self.log("show done visible=\(panel.isVisible) key=\(panel.isKeyWindow) frame=\(NSStringFromRect(panel.frame))")
    }

    func hide(reason: String = "unspecified", force: Bool = false) {
        if isPinned, !force {
            Self.log("hide ignored (pinned) reason=\(reason)")
            return
        }
        Self.log("hide reason=\(reason)\n\(Thread.callStackSymbols.prefix(12).joined(separator: "\n"))")
        isPresented = false
        isPinned = false
        ignoreHotkeyHideUntil = .distantPast
        mouseMonitorWork?.cancel()
        mouseMonitorWork = nil
        removeMonitors()
        panel?.orderOut(nil)
        NotificationCenter.default.post(name: .clipboardHistoryPinDidChange, object: nil)
    }

    func setPinned(_ pinned: Bool) {
        guard isPresented || pinned == false else { return }
        isPinned = pinned
        Self.log("pin=\(pinned)")
        NotificationCenter.default.post(name: .clipboardHistoryPinDidChange, object: nil)
    }

    func togglePinned() {
        setPinned(!isPinned)
    }

    private static func log(_ message: String) {
        let line = "\(Date()) \(message)\n"
        let url = URL(fileURLWithPath: "/tmp/fastsome-clipboard-panel.log")
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: url)
            }
        }
        NSLog("FastSome clipboard panel: \(message)")
    }

    /// Compatibility with older call sites.
    func dismiss() { hide(reason: "dismiss") }

    func selectItem(_ item: ClipboardHistoryItem) {
        // Pinned panel stays key; ⌘V would land in the search field. Copy only.
        if isPinned {
            guard ClipboardHistoryStore.shared.writeToPasteboard(item) else { return }
            NotificationCenter.default.post(name: .clipboardHistoryDidCopy, object: nil)
            return
        }

        let action = AppSettings.shared.clipboardSelectionAction
        hide(reason: "select-item")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let store = ClipboardHistoryStore.shared
            guard store.writeToPasteboard(item) else { return }
            if action == .paste {
                SystemEventsPaste.postCommandV { _ in }
            }
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        // `.nonactivatingPanel` keeps us on the active fullscreen Space.
        // Borderless (no titlebar strip). Opaque fill keeps hit-testing reliable.
        let panel = ClipboardHistoryPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .canJoinAllApplications
        ]
        // Clear window chrome so rounded content corners are visible (not a square slab).
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovableByWindowBackground = false
        panel.delegate = self

        let root = ClipboardHistoryView()
            .environmentObject(ClipboardHistoryStore.shared)
            .environmentObject(AppSettings.shared)

        let fill = ClipboardPanelChrome.fillNSColor
        let radius = ClipboardPanelChrome.cornerRadius
        let container = NSView(frame: NSRect(origin: .zero, size: panelSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = fill.cgColor
        container.layer?.cornerRadius = radius
        container.layer?.masksToBounds = true
        container.layer?.cornerCurve = .continuous
        let hosting = NSHostingView(rootView: root)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(hosting)
        panel.contentView = container

        self.panel = panel
        return panel
    }

    private func positionCentered(_ panel: NSPanel) {
        panel.setContentSize(panelSize)
        // Prefer the screen under the mouse so fullscreen Spaces land correctly.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let originY = visible.midY - panelSize.height / 2 + panelVerticalOffset
        let minY = visible.minY + 12
        let maxY = visible.maxY - panelSize.height - 12
        panel.setFrameOrigin(CGPoint(
            x: visible.midX - panelSize.width / 2,
            y: min(max(originY, minY), maxY)
        ))
    }

    private func installKeyMonitor() {
        if localKeyMonitor != nil { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func scheduleOutsideClickMonitor() {
        mouseMonitorWork?.cancel()
        removeMouseMonitor()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isPresented else { return }
            self.removeMouseMonitor()
            // Clicks inside FastSome (our panel) are local and never reach this.
            self.globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
                self?.hide(reason: "outside-click")
            }
        }
        mouseMonitorWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func removeMonitors() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        removeMouseMonitor()
    }

    private func removeMouseMonitor() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let editing = isSearchFieldEditing
        if event.keyCode == 53 { // Esc
            hide(reason: "escape")
            return true
        }
        // ⌘, → clipboard settings (also while the search field is focused).
        if event.keyCode == 43, event.modifierFlags.contains(.command) {
            SettingsOpener.open(.clipboard)
            return true
        }
        if editing { return false }
        if event.keyCode == 36 || event.keyCode == 76 {
            NotificationCenter.default.post(name: .clipboardHistoryActivateRequested, object: nil)
            return true
        }
        if event.keyCode == 125 {
            NotificationCenter.default.post(
                name: .clipboardHistoryMoveSelection,
                object: nil,
                userInfo: ["delta": 1]
            )
            return true
        }
        if event.keyCode == 126 {
            NotificationCenter.default.post(
                name: .clipboardHistoryMoveSelection,
                object: nil,
                userInfo: ["delta": -1]
            )
            return true
        }
        return false
    }

    private var isSearchFieldEditing: Bool {
        guard let panel, let responder = panel.firstResponder else { return false }
        if responder is NSText { return true }
        if let control = responder as? NSControl, control.currentEditor() != nil { return true }
        return false
    }
}

private final class ClipboardHistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

extension Notification.Name {
    static let clipboardHistoryPanelDidShow = Notification.Name("clipboardHistoryPanelDidShow")
    static let clipboardHistoryActivateRequested = Notification.Name("clipboardHistoryActivateRequested")
    static let clipboardHistoryMoveSelection = Notification.Name("clipboardHistoryMoveSelection")
    static let clipboardHistoryPinDidChange = Notification.Name("clipboardHistoryPinDidChange")
    static let clipboardHistoryDidCopy = Notification.Name("clipboardHistoryDidCopy")
}
