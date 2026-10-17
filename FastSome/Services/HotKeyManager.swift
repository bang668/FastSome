import AppKit
import Carbon

final class HotKeyManager {
    static let shared = HotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onToggle: (() -> Void)?
    /// Last registration error for UI feedback (nil = ok / cleared).
    private(set) var lastErrorMessage: String?

    private let hotKeyID = EventHotKeyID(signature: OSType(0x4649434E), id: 1) // 'FICN'

    private init() {}

    @discardableResult
    func register(combo: HotKeyCombo?) -> Bool {
        unregister()
        lastErrorMessage = nil
        guard let combo else { return true }

        if Self.isReserved(combo) {
            lastErrorMessage = "该快捷键被系统保留，请换一组。"
            return false
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
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
                if hkID.id == manager.hotKeyID.id {
                    DispatchQueue.main.async {
                        manager.onToggle?()
                    }
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &handlerRef
        )
        guard status == noErr else {
            lastErrorMessage = "无法监听快捷键。"
            return false
        }

        let reg = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        if reg != noErr {
            lastErrorMessage = "快捷键注册失败（可能与其他软件冲突）。"
            unregister()
            return false
        }
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
    }

    /// Combos we refuse to steal (app Settings / common system shortcuts).
    static func isReserved(_ combo: HotKeyCombo) -> Bool {
        let mods = combo.modifiers
        let key = combo.keyCode
        let cmd = UInt32(cmdKey)
        let opt = UInt32(optionKey)
        let ctrl = UInt32(controlKey)
        let shift = UInt32(shiftKey)

        // ⌘,  → Settings
        if mods == cmd && key == UInt32(kVK_ANSI_Comma) { return true }
        // ⌘Q / ⌘W / ⌘H / ⌘M — common app shortcuts
        let blockedWithCmd: Set<UInt32> = [
            UInt32(kVK_ANSI_Q), UInt32(kVK_ANSI_W), UInt32(kVK_ANSI_H), UInt32(kVK_ANSI_M)
        ]
        if mods == cmd && blockedWithCmd.contains(key) { return true }
        // Pure modifier-only is invalid
        if key == 0 { return true }
        _ = opt; _ = ctrl; _ = shift
        return false
    }
}
