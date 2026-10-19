import AppKit
import SwiftUI

/// Menu-bar (accessory) apps cannot reliably show SwiftUI `Settings`.
/// We host settings in our own window, and briefly switch to `.regular` while it is open.
@MainActor
enum SettingsOpener {
    enum Pane: String, Sendable {
        case general
        case panel
        case gestures
        case scroll
        case modifiers
        case clipboard
        case about
    }

    private static var window: NSWindow?
    private static var closeObserver: NSObjectProtocol?
    private static var miniaturizeObserver: NSObjectProtocol?
    private static var deminiaturizeObserver: NSObjectProtocol?
    private static var sessionOpen = false
    private static var pendingPane: Pane = .general

    static var isShowing: Bool { sessionOpen }

    /// Opens settings, selecting the given sidebar pane (default: 通用).
    static func open(_ pane: Pane = .general) {
        pendingPane = pane
        PanelController.shared.dismiss()
        // Clipboard panel sits above normal windows (.statusBar); hide it so it
        // cannot cover Settings (e.g. ⌘, from the clipboard history panel).
        ClipboardHistoryPanelController.shared.hide(reason: "open-settings", force: true)

        // Accessory apps cannot present normal windows until policy is regular.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        sessionOpen = true
        MouseGestureController.shared.refreshAccessibility()

        let settingsWindow = ensureWindow()
        if settingsWindow.isMiniaturized {
            settingsWindow.deminiaturize(nil)
        }
        settingsWindow.setContentSize(NSSize(width: 640, height: 560))
        settingsWindow.center()
        settingsWindow.makeKeyAndOrderFront(nil)
        settingsWindow.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.post(
            name: .fastSomeSelectSettingsPane,
            object: nil,
            userInfo: ["pane": pane.rawValue]
        )
    }

    /// Pane requested for the next / current settings presentation.
    static func consumePendingPane() -> Pane {
        let pane = pendingPane
        pendingPane = .general
        return pane
    }

    private static func ensureWindow() -> NSWindow {
        if let window {
            installObservers(for: window)
            return window
        }

        let root = SettingsRootView()
            .environmentObject(AppState.shared)
            .environmentObject(AppState.shared.store)
            .environmentObject(AppState.shared.settings)

        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "FastSome 设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 640, height: 560))
        window.level = .normal
        self.window = window
        installObservers(for: window)
        return window
    }

    private static func installObservers(for window: NSWindow) {
        clearObservers()

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in
                sessionOpen = false
                AppActivation.applyPreferredPolicy()
            }
        }

        // Minimizing must not leave a phantom Dock icon when showInDock is off.
        miniaturizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMiniaturizeNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in
                sessionOpen = false
                AppActivation.applyPreferredPolicy()
            }
        }

        deminiaturizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didDeminiaturizeNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in
                sessionOpen = true
                NSApp.setActivationPolicy(.regular)
            }
        }
    }

    private static func clearObservers() {
        for observer in [closeObserver, miniaturizeObserver, deminiaturizeObserver] {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        closeObserver = nil
        miniaturizeObserver = nil
        deminiaturizeObserver = nil
    }
}

extension Notification.Name {
    static let fastSomeSelectSettingsPane = Notification.Name("fastSomeSelectSettingsPane")
}
