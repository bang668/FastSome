import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppActivation.applyPreferredPolicy()

        StatusItemController.shared.setup()
        bindHotKey()
        // Apply preferred login-item state, then snap the toggle to reality.
        _ = LoginItemService.setEnabled(AppSettings.shared.launchAtLogin)
        let actualLogin = LoginItemService.isEnabled
        if AppSettings.shared.launchAtLogin != actualLogin {
            AppSettings.shared.launchAtLogin = actualLogin
        }

        AppSettings.shared.$hotKey
            .combineLatest(AppSettings.shared.$hotKeyEnabled)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.bindHotKey()
            }
            .store(in: &cancellables)

        HotKeyManager.shared.onToggle = {
            PanelController.shared.toggleFromMenuBar()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Dock may be visible while Settings forces .regular even if showInDock is off.
        if SettingsOpener.isShowing {
            SettingsOpener.open()
            return true
        }
        guard AppSettings.shared.showInDock else { return false }
        PanelController.shared.toggleFromDock()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func bindHotKey() {
        let settings = AppSettings.shared
        if settings.hotKeyEnabled {
            let ok = HotKeyManager.shared.register(combo: settings.hotKey)
            if !ok {
                // Keep the displayed combo but mark disabled so UI isn't lying.
                settings.hotKeyEnabled = false
            }
        } else {
            HotKeyManager.shared.register(combo: nil)
        }
    }
}
