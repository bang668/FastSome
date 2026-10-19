import AppKit
import SwiftUI

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let shared = PanelController()

    private var panel: NSPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var suppressOutsideClickHide = false
    /// Bumped to cancel an in-flight fade-out when showing again.
    private var dismissGeneration = 0
    /// Which saved size the currently shown (or last shown) panel uses.
    private var activeSizeSource: PanelSizeSource = .menuBar

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(anchor: PanelAnchor) {
        guard AppSettings.shared.panelEnabled else {
            dismiss()
            return
        }
        if isVisible {
            // Explicit toggles (menu bar / Dock / hotkey) bypass modal outside-click suppress.
            dismiss()
        } else {
            show(anchor: anchor)
        }
    }

    /// Show or hide anchored under the menu bar status item.
    func toggleFromMenuBar() {
        guard AppSettings.shared.panelEnabled else {
            dismiss()
            return
        }
        if let button = StatusItemController.shared.statusButton {
            toggle(anchor: .statusItem(button))
        } else {
            toggle(anchor: .screenCenter)
        }
    }

    /// Show or hide anchored beside this app's Dock icon.
    func toggleFromDock() {
        guard AppSettings.shared.panelEnabled else {
            dismiss()
            return
        }
        toggle(anchor: .dockIcon)
    }

    func show(anchor: PanelAnchor) {
        guard AppSettings.shared.panelEnabled else {
            dismiss()
            return
        }
        dismissGeneration += 1
        activeSizeSource = anchor.sizeSource
        let panel = ensurePanel()
        panel.alphaValue = 0
        position(panel, anchor: anchor)
        AppState.shared.refreshMissingFlags()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        installMonitors()
    }

    func hide() {
        // Used by outside-click monitors; suppressed while a modal (file picker / alert) is up.
        guard !suppressOutsideClickHide else { return }
        dismiss()
    }

    /// Always hide the launcher panel (used when opening Settings).
    func dismiss() {
        persistPanelSize()
        AppState.shared.isEditing = false
        AppState.shared.commandKeyHeld = false
        AppState.shared.optionKeyHeld = false
        removeMonitors()

        guard let panel, panel.isVisible else {
            panel?.alphaValue = 1
            suppressOutsideClickHide = false
            return
        }

        dismissGeneration += 1
        let generation = dismissGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.dismissGeneration else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
                self.suppressOutsideClickHide = false
            }
        })
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        persistPanelSize()
    }

    /// Keep the launcher panel visible while a system modal (e.g. open panel) runs.
    func performModal(_ work: () -> Void) {
        suppressOutsideClickHide = true
        removeMonitors()
        defer {
            suppressOutsideClickHide = false
            if let panel {
                panel.orderFront(nil)
                panel.makeKeyAndOrderFront(nil)
                installMonitors()
            }
        }
        work()
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let initial = AppSettings.clampedPanelSize(
            AppState.shared.settings.panelSize(for: activeSizeSource)
        )

        // Do not use `.nonactivatingPanel` — group rename TextField needs key-window focus.
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: initial),
            styleMask: [.borderless, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovableByWindowBackground = false
        panel.minSize = AppSettings.minPanelSize
        panel.maxSize = AppSettings.maxPanelSize
        panel.delegate = self

        let root = PanelView()
            .environmentObject(AppState.shared)
            .environmentObject(AppState.shared.store)
            .environmentObject(AppState.shared.settings)

        let container = NSView(frame: NSRect(origin: .zero, size: initial))
        let hosting = NSHostingView(rootView: root)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        let resizeOverlay = EdgeResizeOverlay(frame: container.bounds)
        resizeOverlay.autoresizingMask = [.width, .height]
        container.addSubview(resizeOverlay)

        panel.contentView = container

        self.panel = panel
        return panel
    }

    private func persistPanelSize() {
        guard let panel else { return }
        let size = panel.contentRect(forFrameRect: panel.frame).size
        AppState.shared.settings.setPanelSize(size, for: activeSizeSource)
    }

    private func position(_ panel: NSPanel, anchor: PanelAnchor) {
        let size = AppSettings.clampedPanelSize(
            AppState.shared.settings.panelSize(for: anchor.sizeSource)
        )
        panel.setContentSize(size)

        switch anchor {
        case .statusItem(let button):
            guard let window = button.window else { return }
            let buttonRect = button.convert(button.bounds, to: nil)
            let screenRect = window.convertToScreen(buttonRect)
            var origin = CGPoint(
                x: screenRect.midX - size.width / 2,
                y: screenRect.minY - size.height - 6
            )
            if let screen = window.screen ?? NSScreen.main {
                origin.x = min(max(origin.x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
                if origin.y < screen.visibleFrame.minY {
                    origin.y = screenRect.maxY + 6
                }
            }
            panel.setFrameOrigin(origin)
        case .dockIcon:
            positionNearDock(panel, size: size)
        case .screenCenter:
            let screen = NSScreen.main ?? NSScreen.screens.first
            guard let visible = screen?.visibleFrame else { return }
            let origin = CGPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2
            )
            panel.setFrameOrigin(origin)
        }
    }

    private func positionNearDock(_ panel: NSPanel, size: NSSize) {
        let icon = DockIconLocator.iconFrame()
        let screen = icon.flatMap { rect in
            NSScreen.screens.first { NSMouseInRect(CGPoint(x: rect.midX, y: rect.midY), $0.frame, false) }
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let gap: CGFloat = 8
        var origin = CGPoint.zero

        switch DockIconLocator.dockEdge {
        case .bottom:
            let midX = icon?.midX ?? visible.midX
            origin.x = midX - size.width / 2
            origin.y = (icon?.maxY ?? visible.minY) + gap
            // Prefer above the Dock; if not enough room, sit above visible bottom.
            if origin.y + size.height > visible.maxY {
                origin.y = visible.maxY - size.height - gap
            }
        case .left:
            let midY = icon?.midY ?? visible.midY
            origin.x = (icon?.maxX ?? visible.minX) + gap
            origin.y = midY - size.height / 2
        case .right:
            let midY = icon?.midY ?? visible.midY
            origin.x = (icon?.minX ?? visible.maxX) - size.width - gap
            origin.y = midY - size.height / 2
        }

        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }

    private func installMonitors() {
        removeMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            // Returning nil consumes the event (avoids system beep for ⌥/⌘+digit).
            return self.handle(event) ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            guard let self else { return }
            // Keep panel open while editing, renaming, or showing a file picker.
            if self.suppressOutsideClickHide || AppState.shared.isEditing {
                return
            }
            self.hide()
        }
    }

    private func removeMonitors() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    /// Returns `true` when the event was handled and should not propagate.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .flagsChanged:
            let editing = AppState.shared.isEditing
            AppState.shared.commandKeyHeld = event.modifierFlags.contains(.command) && !editing
            AppState.shared.optionKeyHeld = event.modifierFlags.contains(.option) && !editing
            return false
        case .keyDown:
            if event.keyCode == 53 { // esc
                if AppState.shared.isEditing {
                    AppState.shared.isEditing = false
                    return true
                }
                hide()
                return true
            }
            // ⌘, → panel settings (works even while editing).
            if event.keyCode == 43, event.modifierFlags.contains(.command) {
                SettingsOpener.open(.panel)
                return true
            }
            guard !AppState.shared.isEditing else { return false }
            if let digit = Self.digit(from: event) {
                // ⌘ takes priority over ⌥ when both are held.
                if event.modifierFlags.contains(.command) {
                    launchByIndex(digit)
                    return true
                }
                if event.modifierFlags.contains(.option) {
                    selectGroupByIndex(digit)
                    return true
                }
            }
            return false
        case .leftMouseDown:
            if suppressOutsideClickHide || AppState.shared.isEditing {
                return false
            }
            if let panel, let content = panel.contentView {
                let point = content.convert(event.locationInWindow, from: nil)
                if !content.bounds.contains(point) {
                    hide()
                }
            }
            return false
        default:
            return false
        }
    }

    private func launchByIndex(_ index: Int) {
        guard let items = AppState.shared.store.selectedGroup?.items, items.indices.contains(index) else { return }
        let item = items[index]
        if Launcher.open(item, store: AppState.shared.store),
           AppState.shared.settings.closePanelAfterLaunch {
            hide()
        }
    }

    private func selectGroupByIndex(_ index: Int) {
        let groups = AppState.shared.store.library.groups
        guard groups.indices.contains(index) else { return }
        AppState.shared.store.selectGroup(groups[index].id)
    }

    private static func digit(from event: NSEvent) -> Int? {
        if let chars = event.charactersIgnoringModifiers, let c = chars.first, c.isNumber {
            let value = Int(String(c)) ?? -1
            if value == 0 { return 9 }
            if (1...9).contains(value) { return value - 1 }
        }
        return nil
    }
}

enum PanelAnchor {
    case statusItem(NSStatusBarButton)
    case dockIcon
    case screenCenter

    var sizeSource: PanelSizeSource {
        switch self {
        case .dockIcon: return .dock
        case .statusItem, .screenCenter: return .menuBar
        }
    }
}
