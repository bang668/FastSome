import AppKit
import ApplicationServices

/// Global double-tap listener for Control / Option / Command.
/// Chord hotkeys stay on Carbon; this only handles `HotKeyCombo.doubleModifier`.
@MainActor
final class DoubleModifierHotKeyMonitor {
    static let shared = DoubleModifierHotKeyMonitor()

    var onPanelToggle: (() -> Void)?
    var onClipboardToggle: (() -> Void)?

    private var panelKind: DoubleModifierKind?
    private var clipboardKind: DoubleModifierKind?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var detector = DoubleModifierTapDetector()
    private var lastFlags: NSEvent.ModifierFlags = []
    private(set) var isListening = false

    private init() {}

    var needsAccessibility: Bool {
        panelKind != nil || clipboardKind != nil
    }

    var accessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    func refreshIfNeeded() {
        guard panelKind != nil || clipboardKind != nil else { return }
        start()
    }

    func sync(panel: DoubleModifierKind?, clipboard: DoubleModifierKind?) {
        panelKind = panel
        clipboardKind = clipboard
        detector.reset()
        lastFlags = []
        if panel == nil && clipboard == nil {
            stop()
        } else {
            start()
        }
    }

    private func start() {
        stopMonitorsOnly()
        guard AXIsProcessTrusted() else {
            isListening = false
            NSLog("FastSome: double-modifier hotkey needs Accessibility")
            return
        }

        let handler: (NSEvent) -> Void = { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            handler(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            handler(event)
        }
        isListening = localMonitor != nil || globalMonitor != nil
    }

    private func stop() {
        stopMonitorsOnly()
        isListening = false
    }

    private func stopMonitorsOnly() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            if DoubleModifierKind.from(keyCode: event.keyCode) == nil {
                _ = detector.handle(.otherKey)
            }
            return
        }

        guard event.type == .flagsChanged else { return }
        let code = event.keyCode
        guard let kind = DoubleModifierKind.from(keyCode: code) else {
            _ = detector.handle(.otherKey)
            lastFlags = event.modifierFlags.intersection([.control, .option, .command, .shift])
            return
        }

        let bit = kind.nsFlag
        let nowDown = event.modifierFlags.contains(bit)
        let wasDown = lastFlags.contains(bit)
        lastFlags = event.modifierFlags.intersection([.control, .option, .command, .shift])

        if nowDown && !wasDown {
            _ = detector.handle(.modifierDown(kind))
        } else if !nowDown && wasDown {
            if let fired = detector.handle(.modifierUp(kind)) {
                fire(fired)
            }
        }
    }

    private func fire(_ kind: DoubleModifierKind) {
        if panelKind == kind {
            onPanelToggle?()
        }
        if clipboardKind == kind {
            onClipboardToggle?()
        }
    }
}

private extension DoubleModifierKind {
    var nsFlag: NSEvent.ModifierFlags {
        switch self {
        case .control: return .control
        case .option: return .option
        case .command: return .command
        }
    }
}
