import AppKit
import Carbon

/// Carbon hotkey for the launcher panel only.
/// Clipboard history uses `ClipboardHotKeyMonitor` (NSEvent) instead.
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var registeredCombo: HotKeyCombo?

    var onPanelToggle: (() -> Void)?
    /// Compatibility alias.
    var onToggle: (() -> Void)? {
        get { onPanelToggle }
        set { onPanelToggle = newValue }
    }

    /// Unused — kept so older call sites that assigned clipboard handlers still compile if any remain.
    var onClipboardToggle: (() -> Void)?

    private(set) var lastErrorMessage: String?

    private let hotKeyID = EventHotKeyID(signature: OSType(0x4649434E), id: 1) // 'FICN'

    private init() {}

    @discardableResult
    func sync(panel: HotKeyCombo?, clipboard _: HotKeyCombo? = nil) -> (panelOK: Bool, clipboardOK: Bool) {
        (register(combo: panel), true)
    }

    @discardableResult
    func register(combo: HotKeyCombo?) -> Bool {
        if combo == registeredCombo {
            if combo?.isDoubleModifier == true { return true }
            if (combo == nil) == (hotKeyRef == nil) { return true }
        }

        unregister()
        lastErrorMessage = nil
        registeredCombo = nil

        guard let combo else { return true }

        // Double-modifier bindings are handled by DoubleModifierHotKeyMonitor.
        if combo.isDoubleModifier {
            registeredCombo = combo
            return true
        }

        if Self.isReserved(combo) {
            lastErrorMessage = "该快捷键被系统保留，请换一组。"
            return false
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData, let event else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hkID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                if hkID.signature == manager.hotKeyID.signature, hkID.id == manager.hotKeyID.id {
                    DispatchQueue.main.async {
                        manager.onPanelToggle?()
                    }
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &handlerRef
        )
        guard handlerStatus == noErr else {
            lastErrorMessage = "无法监听快捷键。"
            return false
        }

        var hotKeyID = hotKeyID
        let reg = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        if reg != noErr {
            NSLog("FastSome: panel RegisterEventHotKey failed status=\(reg)")
            unregister()
            return false
        }
        registeredCombo = combo
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        registeredCombo = nil
    }

    static func isReserved(_ combo: HotKeyCombo) -> Bool {
        if combo.isDoubleModifier { return false }
        let mods = combo.modifiers
        let key = combo.keyCode
        let cmd = UInt32(cmdKey)

        if mods == cmd && key == UInt32(kVK_ANSI_Comma) { return true }
        let blockedWithCmd: Set<UInt32> = [
            UInt32(kVK_ANSI_Q), UInt32(kVK_ANSI_W), UInt32(kVK_ANSI_H), UInt32(kVK_ANSI_M)
        ]
        if mods == cmd && blockedWithCmd.contains(key) { return true }
        if key == 0 { return true }
        return false
    }
}

/// Shared suspend/resume for settings hotkey recording.
/// Carbon must be cleared while recording, or the existing shortcut steals the keypress
/// (opens panel/clipboard) before the recorder can show a conflict toast.
enum HotKeyBinding {
    @MainActor
    static func suspendForRecording() {
        HotKeyManager.shared.register(combo: nil)
        ClipboardHotKeyMonitor.shared.setCombo(nil)
        DoubleModifierHotKeyMonitor.shared.sync(panel: nil, clipboard: nil)
    }

    @MainActor
    static func applyFromSettings() {
        let settings = AppSettings.shared
        let panelCombo: HotKeyCombo? = {
            guard settings.panelEnabled, settings.hotKeyEnabled else { return nil }
            return settings.hotKey
        }()
        _ = HotKeyManager.shared.register(combo: panelCombo)

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
}

