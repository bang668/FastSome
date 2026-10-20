import AppKit
import Carbon

/// System-wide clipboard-history hotkey via Carbon.
///
/// Important: this is intentionally separate from `HotKeyManager` (launcher panel).
/// Sharing one register/unregister path caused the clipboard combo to die whenever
/// the panel activated the app. This type only touches its own hotkey ref.
final class ClipboardHotKeyMonitor {
    static let shared = ClipboardHotKeyMonitor()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var registeredCombo: HotKeyCombo?

    var onToggle: (() -> Void)?
    private(set) var lastErrorMessage: String?

    /// Distinct from launcher panel ('FICN').
    private let hotKeyID = EventHotKeyID(signature: OSType(0x46534843), id: 1) // 'FSHC'

    private init() {}

    @discardableResult
    func setCombo(_ combo: HotKeyCombo?) -> Bool {
        if combo == registeredCombo {
            if combo?.isDoubleModifier == true { return true }
            if (combo == nil) == (hotKeyRef == nil) { return true }
        }

        unregister()
        lastErrorMessage = nil
        guard let combo else { return true }

        if combo.isDoubleModifier {
            registeredCombo = combo
            return true
        }

        if HotKeyManager.isReserved(combo) {
            lastErrorMessage = "该快捷键被系统保留，请换一组。"
            return false
        }

        guard installHandler() else {
            lastErrorMessage = "无法监听剪贴板快捷键。"
            return false
        }

        var id = hotKeyID
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers,
            id,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        if status != noErr {
            NSLog("FastSome: clipboard RegisterEventHotKey failed status=\(status) key=\(combo.keyCode) mods=\(combo.modifiers)")
            removeHandler()
            return false
        }
        hotKeyRef = ref
        registeredCombo = combo
        NSLog("FastSome: clipboard hotkey registered \(combo.displayString)")
        return true
    }

    private func installHandler() -> Bool {
        if handlerRef != nil { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData, let event else { return noErr }
                let monitor = Unmanaged<ClipboardHotKeyMonitor>.fromOpaque(userData).takeUnretainedValue()
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
                if hkID.signature == monitor.hotKeyID.signature, hkID.id == monitor.hotKeyID.id {
                    NSLog("FastSome clipboard hotkey Carbon fire")
                    DispatchQueue.main.async {
                        monitor.onToggle?()
                    }
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &handlerRef
        )
        if status != noErr {
            NSLog("FastSome: clipboard InstallEventHandler failed status=\(status)")
            handlerRef = nil
            return false
        }
        return true
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        removeHandler()
        registeredCombo = nil
    }

    private func removeHandler() {
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }
}
