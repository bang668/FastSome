import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppActivation.applyPreferredPolicy()

        StatusItemController.shared.setup()

        // Callbacks must be set before the first hotkey registration.
        HotKeyManager.shared.onPanelToggle = {
            guard AppSettings.shared.panelEnabled else { return }
            PanelController.shared.toggleFromMenuBar()
        }
        ClipboardHotKeyMonitor.shared.onToggle = {
            guard AppSettings.shared.clipboardHistoryEnabled else { return }
            ClipboardHistoryPanelController.shared.toggle()
        }
        DoubleModifierHotKeyMonitor.shared.onPanelToggle = {
            guard AppSettings.shared.panelEnabled else { return }
            PanelController.shared.toggleFromMenuBar()
        }
        DoubleModifierHotKeyMonitor.shared.onClipboardToggle = {
            guard AppSettings.shared.clipboardHistoryEnabled else { return }
            ClipboardHistoryPanelController.shared.toggle()
        }

        // Persist first-run clipboard defaults (init does not fire didSet).
        persistClipboardDefaultsIfNeeded()

        bindAllHotKeys()
        bindClipboardHistory()
        bindMouseGestures(prompt: false)
        bindMouseScrollReverse()
        bindModifierRemap()
        // Apply preferred login-item state, then snap the toggle to reality.
        _ = LoginItemService.setEnabled(AppSettings.shared.launchAtLogin)
        let actualLogin = LoginItemService.isEnabled
        if AppSettings.shared.launchAtLogin != actualLogin {
            AppSettings.shared.launchAtLogin = actualLogin
        }

        AppSettings.shared.$hotKey
            .combineLatest(
                AppSettings.shared.$hotKeyEnabled,
                AppSettings.shared.$panelEnabled,
                AppSettings.shared.$clipboardHotKey
            )
            .combineLatest(
                AppSettings.shared.$clipboardHotKeyEnabled,
                AppSettings.shared.$clipboardHistoryEnabled
            )
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.bindAllHotKeys()
            }
            .store(in: &cancellables)

        AppSettings.shared.$clipboardHistoryEnabled
            .combineLatest(
                AppSettings.shared.$clipboardMaxItems,
                AppSettings.shared.$clipboardRetentionDays
            )
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.bindClipboardHistory()
            }
            .store(in: &cancellables)

        AppSettings.shared.$panelEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { enabled in
                if !enabled {
                    PanelController.shared.dismiss()
                }
            }
            .store(in: &cancellables)

        AppSettings.shared.$mouseGestures
            .combineLatest(AppSettings.shared.$mouseGesturesEnabled)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] gestures, gesturesEnabled in
                self?.bindMouseGestures(prompt: gesturesEnabled && !gestures.isEmpty)
            }
            .store(in: &cancellables)

        AppSettings.shared.$mouseScrollReverseEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.bindMouseScrollReverse()
            }
            .store(in: &cancellables)

        AppSettings.shared.$modifierRemapEnabled
            .combineLatest(AppSettings.shared.$modifierRemapRules)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.bindModifierRemap()
            }
            .store(in: &cancellables)

        UpdateChecker.shared.scheduleLaunchCheck()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MouseGestureController.shared.refreshAccessibility()
        // Do NOT rebind hotkeys here. Showing the clipboard panel calls NSApp.activate,
        // which re-enters this method; unregister/register mid-hotkey leaves Carbon dead.
        if AppSettings.shared.mouseScrollReverseEnabled {
            if MouseScrollReverser.shared.isInstalled {
                MouseScrollReverser.shared.refresh()
            } else {
                bindMouseScrollReverse()
            }
        }
        if AppSettings.shared.modifierRemapEnabled {
            if ModifierRemapper.shared.isInstalled {
                ModifierRemapper.shared.refresh()
            } else {
                bindModifierRemap()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Dock may be visible while Settings forces .regular even if showInDock is off.
        if SettingsOpener.isShowing {
            SettingsOpener.open()
            return true
        }
        guard AppSettings.shared.showInDock else { return false }
        guard AppSettings.shared.panelEnabled else {
            SettingsOpener.open()
            return true
        }
        PanelController.shared.toggleFromDock()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func bindMouseGestures(prompt: Bool) {
        let settings = AppSettings.shared
        let gestures = settings.mouseGesturesEnabled ? settings.mouseGestures : []
        MouseGestureController.shared.apply(gestures: gestures, prompt: prompt)
    }

    private func bindMouseScrollReverse() {
        MouseScrollReverser.shared.setEnabled(AppSettings.shared.mouseScrollReverseEnabled)
    }

    private func bindModifierRemap() {
        let settings = AppSettings.shared
        ModifierRemapper.shared.apply(
            enabled: settings.modifierRemapEnabled,
            rules: settings.modifierRemapRules
        )
    }

    private func persistClipboardDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        let settings = AppSettings.shared
        if defaults.object(forKey: "settings.clipboardHistoryEnabled") == nil {
            settings.clipboardHistoryEnabled = true
        }
        if defaults.object(forKey: "settings.clipboardHotKeyCode") == nil {
            settings.clipboardHotKey = .optionCommandV
            settings.clipboardHotKeyEnabled = true
        }
    }

    private func bindAllHotKeys() {
        let settings = AppSettings.shared
        let panelCombo: HotKeyCombo? = {
            guard settings.panelEnabled, settings.hotKeyEnabled else { return nil }
            return settings.hotKey
        }()
        _ = HotKeyManager.shared.register(combo: panelCombo)

        // Clipboard hotkey is a separate Carbon registration — never tied to panel show/hide.
        let clipboardCombo: HotKeyCombo? = {
            guard settings.clipboardHistoryEnabled, settings.clipboardHotKeyEnabled else { return nil }
            return settings.clipboardHotKey
        }()
        let ok = ClipboardHotKeyMonitor.shared.setCombo(clipboardCombo)
        if !ok, clipboardCombo != nil {
            NSLog("FastSome: clipboard hotkey bind failed: \(ClipboardHotKeyMonitor.shared.lastErrorMessage ?? "?")")
        }

        let panelDouble = panelCombo?.isDoubleModifier == true ? panelCombo?.doubleModifier : nil
        let clipboardDouble = clipboardCombo?.isDoubleModifier == true ? clipboardCombo?.doubleModifier : nil
        DoubleModifierHotKeyMonitor.shared.sync(panel: panelDouble, clipboard: clipboardDouble)
    }

    private func bindClipboardHistory() {
        let settings = AppSettings.shared
        ClipboardHistoryMonitor.shared.setEnabled(settings.clipboardHistoryEnabled)
        if settings.clipboardHistoryEnabled {
            ClipboardHistoryMonitor.shared.applyRetentionFromSettings()
        } else {
            ClipboardHotKeyMonitor.shared.setCombo(nil)
            ClipboardHistoryPanelController.shared.hide(reason: "clipboard-disabled", force: true)
        }
    }
}
