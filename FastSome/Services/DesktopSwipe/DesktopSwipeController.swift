import AppKit
import ApplicationServices

@MainActor
final class MouseGestureController: ObservableObject {
    static let shared = MouseGestureController()

    @Published private(set) var statusMessage: String?
    @Published private(set) var accessibilityTrusted = false

    private let monitor = DesktopSwipeMonitor()
    private let trail = DesktopSwipeTrail()
    private let tip = MouseGestureTip()
    private var retry: Timer?

    private init() {
        accessibilityTrusted = Self.isTrusted(prompt: false)
        monitor.onStroke = { points, effects in
            Task { @MainActor in
                MouseGestureController.shared.render(points: points, effects: effects)
            }
        }
        monitor.onPostResult = { message in
            Task { @MainActor in
                MouseGestureController.shared.statusMessage = message
            }
        }
    }

    /// Re-check without showing the system dialog. Starts listening again once access is granted.
    func refreshAccessibility() {
        let trusted = noteTrust(Self.isTrusted(prompt: false))
        guard trusted else { return }
        apply(gestures: AppSettings.shared.mouseGestures, prompt: false)
    }

    /// Asks macOS to put FastSome back into「设备控制和数据访问」.
    /// Only shows the system trust sheet; that sheet’s「打开系统设置」opens the privacy pane.
    func requestAccessibility() {
        _ = Self.isTrusted(prompt: true)
        refreshAccessibility()
    }

    func tapWasDisabled() {
        guard !AppSettings.shared.mouseGestures.isEmpty else {
            stopListening()
            statusMessage = nil
            cancelRetry()
            return
        }
        if noteTrust(Self.isTrusted(prompt: false)) {
            let ended = monitor.cancelGesture()
            render(points: ended.points, effects: ended.effects)
            monitor.reenable()
            return
        }
        stopListening()
        statusMessage = "需要在「隐私与安全性 → 设备控制和数据访问」中允许 FastSome。允许之前不会拦截鼠标。"
        scheduleRetry()
    }

    func apply(gestures: [MouseGestureDefinition], prompt: Bool) {
        let buttons = Set(gestures.map(\.button))
        guard !gestures.isEmpty else {
            _ = noteTrust(Self.isTrusted(prompt: false))
            stopListening()
            statusMessage = nil
            cancelRetry()
            return
        }
        guard noteTrust(Self.isTrusted(prompt: prompt)) else {
            stopListening()
            statusMessage = "需要在「隐私与安全性 → 设备控制和数据访问」中允许 FastSome。允许之前不会拦截鼠标。"
            scheduleRetry()
            return
        }
        if monitor.isInstalled, monitor.listenedButtons == buttons {
            monitor.definitions = gestures
            statusMessage = nil
            cancelRetry()
            return
        }
        if monitor.start(buttons: buttons) {
            monitor.definitions = gestures
            trail.prepare()
            tip.hide()
            statusMessage = nil
            cancelRetry()
        } else {
            statusMessage = "鼠标手势当前未生效。"
            scheduleRetry()
        }
    }

    private func stopListening() {
        let ended = monitor.cancelGesture()
        render(points: ended.points, effects: ended.effects)
        monitor.stop()
        tip.hide()
        trail.clearImmediately()
    }

    private func render(points: [CGPoint], effects: [MouseGestureEffect]) {
        var cleared = false
        var painted = false
        for effect in effects {
            switch effect {
            case .beginTrail:
                trail.show(points)
                painted = true
            case .clearTrail:
                trail.clearImmediately()
                cleared = true
            case .showTip(let text):
                tip.show(text, near: points.last ?? .zero)
                SwipeLog.write("tip \(text)")
            case .hideTip:
                tip.hide()
            case .fadeTip:
                tip.fadeOut()
            case .fireShortcut(let shortcut):
                SwipeLog.write("fire \(shortcut.displayString)")
                monitor.postShortcut(shortcut)
            case .pasteText(let text):
                SwipeLog.write("paste \(MouseGestureAction.preview(text, limit: 24))")
                monitor.postPasteText(text)
            case .replayClick(let button, let point):
                monitor.postClick(button, at: point)
            case .replayDrag(let button, let path):
                monitor.postDrag(button, path: path)
            }
        }
        if !cleared, !painted, trail.isShowing {
            trail.update(points)
        }
    }

    private func scheduleRetry() {
        guard retry == nil else { return }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let gestures = AppSettings.shared.mouseGestures
                guard !gestures.isEmpty else { return }
                self.apply(gestures: gestures, prompt: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retry = timer
    }

    private func cancelRetry() {
        retry?.invalidate()
        retry = nil
    }

    private func noteTrust(_ trusted: Bool) -> Bool {
        if accessibilityTrusted != trusted {
            accessibilityTrusted = trusted
        }
        return trusted
    }

    private static func isTrusted(prompt: Bool) -> Bool {
        let ax: Bool
        if prompt {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [key: true] as CFDictionary
            ax = AXIsProcessTrustedWithOptions(options)
        } else {
            ax = AXIsProcessTrusted()
        }
        // Probe with the same HID defaultTap the real monitor installs.
        // A session/listenOnly probe can fail (or demand 输入监控) even when gestures would work.
        let tap = canInstallTap()
        if !ax || !tap {
            SwipeLog.write("trust ax=\(ax) tap=\(tap)")
        }
        return ax && tap
    }

    /// `AXIsProcessTrusted` can stay true after FastSome is removed from the list.
    /// A new tap fails immediately in that case.
    private static func canInstallTap() -> Bool {
        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.leftMouseDown.rawValue),
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        ) else { return false }
        CFMachPortInvalidate(port)
        return true
    }
}
