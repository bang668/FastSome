import AppKit
import Carbon
import CoreGraphics

/// Per-app modifier remapping via a keyboard event tap.
///
/// The tap is session-wide (CGEventTap cannot filter by app), but the hot path only
/// remaps when a cached frontmost bundle id matches a non-identity rule. App switches
/// update that cache via workspace notifications — not via NSWorkspace on every key.
final class ModifierRemapper {
    static let shared = ModifierRemapper()

    private var port: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let lock = NSLock()
    private var enabled = false
    private var rulesByBundle: [String: AppModifierRemapRule] = [:]
    /// Frontmost bundle id from workspace notifications / explicit refresh (not per-key).
    private var cachedFrontmostBundleId: String?
    /// Precomputed rule for `cachedFrontmostBundleId` when remapping is needed; nil = passthrough.
    private var cachedActiveRule: AppModifierRemapRule?
    private var workspaceObserver: NSObjectProtocol?

    private static let replayMark: Int64 = 0x4653_4D52 // FSMR

    var isInstalled: Bool { port != nil }

    func apply(enabled: Bool, rules: [AppModifierRemapRule]) {
        lock.lock()
        self.enabled = enabled
        rulesByBundle = Dictionary(uniqueKeysWithValues: rules.map { ($0.bundleIdentifier, $0) })
        lock.unlock()

        if enabled, !rules.isEmpty {
            _ = start()
            refreshFrontmostCache()
        } else {
            lock.lock()
            let wasRemapping = cachedActiveRule != nil
            lock.unlock()
            if wasRemapping {
                clearStuckModifiersIfNeeded()
            }
            stop()
            lock.lock()
            cachedFrontmostBundleId = nil
            cachedActiveRule = nil
            lock.unlock()
        }
    }

    func refresh() {
        guard let port else { return }
        if !CGEvent.tapIsEnabled(tap: port) {
            CGEvent.tapEnable(tap: port, enable: true)
        }
        refreshFrontmostCache()
    }

    @discardableResult
    private func start() -> Bool {
        if port != nil {
            ensureWorkspaceObserver()
            return true
        }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let remapper = Unmanaged<ModifierRemapper>.fromOpaque(userInfo).takeUnretainedValue()
                return remapper.receive(type: type, event: event)
            },
            userInfo: userInfo
        ) else {
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.runLoopSource = source
        ensureWorkspaceObserver()
        return true
    }

    private func stop() {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
            self.port = nil
        }
    }

    private func ensureWorkspaceObserver() {
        guard workspaceObserver == nil else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshFrontmostCache()
        }
    }

    /// Updates cached frontmost + active rule. Safe (and intended) outside the key hot path.
    private func refreshFrontmostCache() {
        let newId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        lock.lock()
        let previousHadRule = cachedActiveRule != nil
        let previousId = cachedFrontmostBundleId
        cachedFrontmostBundleId = newId
        if enabled, let newId, let rule = rulesByBundle[newId], !rule.isIdentity {
            cachedActiveRule = rule
        } else {
            cachedActiveRule = nil
        }
        let nowHasRule = cachedActiveRule != nil
        lock.unlock()

        // Leaving a remapping app (or switching between remapped apps): clear sticky modifiers.
        if previousHadRule, previousId != newId || !nowHasRule {
            clearStuckModifiersIfNeeded()
        }
    }

    private func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            refresh()
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == Self.replayMark {
            return Unmanaged.passUnretained(event)
        }

        // Hot path: only the precomputed rule. No NSWorkspace lookup per key.
        lock.lock()
        let rule = cachedActiveRule
        lock.unlock()

        guard let rule else {
            return Unmanaged.passUnretained(event)
        }

        return apply(rule: rule, type: type, event: event)
    }

    private func apply(rule: AppModifierRemapRule, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let physicalFlags = event.flags

        if type == .flagsChanged || type == .keyDown || type == .keyUp {
            if let source = ModifierKeyCode.source(for: keyCode) {
                let target = rule.target(for: source)
                if target == .none {
                    return nil
                }
                if let mapped = ModifierKeyCode.keyCode(for: target, side: ModifierKeyCode.side(of: keyCode)) {
                    event.setIntegerValueField(.keyboardEventKeycode, value: Int64(mapped))
                }
            }
        }

        event.flags = mappedFlags(from: physicalFlags, rule: rule)
        return Unmanaged.passUnretained(event)
    }

    private func mappedFlags(from flags: CGEventFlags, rule: AppModifierRemapRule) -> CGEventFlags {
        var out = flags
        out.remove([.maskCommand, .maskControl, .maskAlternate, .maskAlphaShift])

        func contribute(_ flag: CGEventFlags, target: ModifierRemapTarget) {
            guard flags.contains(flag) else { return }
            switch target {
            case .none: break
            case .capsLock: out.insert(.maskAlphaShift)
            case .control: out.insert(.maskControl)
            case .option: out.insert(.maskAlternate)
            case .command: out.insert(.maskCommand)
            }
        }

        contribute(.maskAlphaShift, target: rule.capsLock)
        contribute(.maskControl, target: rule.control)
        contribute(.maskAlternate, target: rule.option)
        contribute(.maskCommand, target: rule.command)
        return out
    }

    /// Best-effort release so a remapped modifier doesn't stick after leaving the app.
    private func clearStuckModifiersIfNeeded() {
        let codes: [CGKeyCode] = [
            CGKeyCode(kVK_Command),
            CGKeyCode(kVK_RightCommand),
            CGKeyCode(kVK_Control),
            CGKeyCode(kVK_RightControl),
            CGKeyCode(kVK_Option),
            CGKeyCode(kVK_RightOption),
            CGKeyCode(kVK_CapsLock),
        ]
        for code in codes {
            guard let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { continue }
            up.flags = []
            up.setIntegerValueField(.eventSourceUserData, value: Self.replayMark)
            up.post(tap: .cgSessionEventTap)
        }
    }
}

private enum ModifierKeyCode {
    enum Side {
        case left
        case right
        case other
    }

    static func source(for keyCode: CGKeyCode) -> ModifierRemapSource? {
        switch Int(keyCode) {
        case kVK_CapsLock: return .capsLock
        case kVK_Control, kVK_RightControl: return .control
        case kVK_Option, kVK_RightOption: return .option
        case kVK_Command, kVK_RightCommand: return .command
        default: return nil
        }
    }

    static func side(of keyCode: CGKeyCode) -> Side {
        switch Int(keyCode) {
        case kVK_RightCommand, kVK_RightControl, kVK_RightOption: return .right
        case kVK_Command, kVK_Control, kVK_Option: return .left
        default: return .other
        }
    }

    static func keyCode(for target: ModifierRemapTarget, side: Side) -> CGKeyCode? {
        switch target {
        case .none:
            return nil
        case .capsLock:
            return CGKeyCode(kVK_CapsLock)
        case .control:
            return CGKeyCode(side == .right ? kVK_RightControl : kVK_Control)
        case .option:
            return CGKeyCode(side == .right ? kVK_RightOption : kVK_Option)
        case .command:
            return CGKeyCode(side == .right ? kVK_RightCommand : kVK_Command)
        }
    }
}
