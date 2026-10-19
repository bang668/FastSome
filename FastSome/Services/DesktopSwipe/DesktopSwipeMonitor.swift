import AppKit
import Carbon
import CoreGraphics

/// Session-wide mouse tap for the buttons used by saved gestures.
/// Keyboard events are not observed, so posted shortcuts are not seen here.
final class DesktopSwipeMonitor {
    private var port: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var primaryHeight: CGFloat = 0
    private static let replayMark: Int64 = 0x4653_5747
    private var recognizer = MouseGestureRecognizer()
    private var stroke: [CGPoint] = []
    private var activeButton: MouseGestureButton?
    private(set) var listenedButtons: Set<MouseGestureButton> = []
    var definitions: [MouseGestureDefinition] = []

    /// Runs after the tap callback has returned. Safe to touch AppKit here.
    var onStroke: (([CGPoint], [MouseGestureEffect]) -> Void)?

    /// Coalesce HID callbacks so the main thread only paints the latest stroke.
    private var pendingPoints: [CGPoint]?
    private var pendingEffects: [MouseGestureEffect] = []
    private var deliverScheduled = false

    /// Skip near-duplicate samples for drawing / replay; recognition still sees every event.
    private static let minSampleDistance: CGFloat = 3

    var isInstalled: Bool { port != nil }

    func start(buttons: Set<MouseGestureButton>) -> Bool {
        stop()
        guard !buttons.isEmpty else { return false }
        refreshPrimaryHeight()
        listenedButtons = buttons
        var mask: CGEventMask = 0
        if buttons.contains(.left) {
            mask |= (1 << CGEventType.leftMouseDown.rawValue)
            mask |= (1 << CGEventType.leftMouseDragged.rawValue)
            mask |= (1 << CGEventType.leftMouseUp.rawValue)
        }
        if buttons.contains(.right) {
            mask |= (1 << CGEventType.rightMouseDown.rawValue)
            mask |= (1 << CGEventType.rightMouseDragged.rawValue)
            mask |= (1 << CGEventType.rightMouseUp.rawValue)
        }
        if !buttons.isDisjoint(with: [.middle, .back, .forward]) {
            mask |= (1 << CGEventType.otherMouseDown.rawValue)
            mask |= (1 << CGEventType.otherMouseDragged.rawValue)
            mask |= (1 << CGEventType.otherMouseUp.rawValue)
        }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<DesktopSwipeMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                return monitor.receive(type: type, event: event)
            },
            userInfo: userInfo
        ) else { return false }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.runLoopSource = source
        SwipeLog.write("tap started \(buttons.map(\.rawValue).sorted())")
        return true
    }

    func cancelGesture() -> (points: [CGPoint], effects: [MouseGestureEffect]) {
        let effects = recognizer.cancel()
        let points = stroke
        stroke = []
        activeButton = nil
        return (points, effects)
    }

    func reenable() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func stop() {
        activeButton = nil
        stroke = []
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        port = nil
        runLoopSource = nil
        listenedButtons = []
    }

    /// Called on the main queue after a shortcut is handed to System Events.
    /// The string is an error message; nil means it was sent.
    var onPostResult: ((String?) -> Void)?

    func postShortcut(_ combo: HotKeyCombo) {
        let script = Self.systemEventsScript(for: combo)
        let label = combo.displayString
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let pipe = Pipe()
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let err = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let failed = process.terminationStatus != 0
                SwipeLog.write("posted \(label) status \(process.terminationStatus) \(err)")
                let message: String?
                if failed {
                    message = "快捷键没有发出去。请允许 FastSome 控制「系统事件」。"
                } else {
                    message = nil
                }
                DispatchQueue.main.async {
                    self?.onPostResult?(message)
                }
            } catch {
                SwipeLog.write("posted \(label) failed \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.onPostResult?("快捷键没有发出去。请允许 FastSome 控制「系统事件」。")
                }
            }
        }
    }

    /// Writes text to the pasteboard, posts ⌘V, then restores the previous string.
    ///
    /// Restore must wait longer than many apps take to read the pasteboard; 0.25s
    /// was racing the paste and looked like “sometimes works”.
    func postPasteText(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            let pasteboard = NSPasteboard.general
            let previous = pasteboard.string(forType: .string)
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            let token = pasteboard.changeCount
            // Mouse-up / focus settle, then paste the same way shortcuts use System Events.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                SystemEventsPaste.postCommandV { failed in
                    // osascript finishes off the main thread; hop back before UI / pasteboard work.
                    DispatchQueue.main.async {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                            // Avoid clobbering if the user copied something else in between.
                            guard pasteboard.changeCount == token
                                    || pasteboard.string(forType: .string) == text else { return }
                            pasteboard.clearContents()
                            if let previous {
                                pasteboard.setString(previous, forType: .string)
                            }
                        }
                        self?.onPostResult?(
                            failed ? "文本没有粘贴出去。请允许 FastSome 控制「系统事件」。" : nil
                        )
                    }
                }
            }
        }
    }

    /// Mission Control ignores a synthetic Control+arrow from CGEvent. System Events
    /// posts the same chord the keyboard uses.
    static func systemEventsScript(for combo: HotKeyCombo) -> String {
        var parts: [String] = []
        if combo.modifiers & 4096 != 0 { parts.append("control down") }
        if combo.modifiers & 2048 != 0 { parts.append("option down") }
        if combo.modifiers & 512 != 0 { parts.append("shift down") }
        if combo.modifiers & 256 != 0 { parts.append("command down") }
        if parts.isEmpty {
            return "tell application \"System Events\" to key code \(combo.keyCode)"
        }
        return "tell application \"System Events\" to key code \(combo.keyCode) using {\(parts.joined(separator: ", "))}"
    }

    /// Arrow keys are created with a function bit. Keeping it turns Control+Left
    /// into Control+Fn+Left, which is a different shortcut.
    static func chordFlags(modifiers: UInt32, base: CGEventFlags) -> CGEventFlags {
        var flags = shortcutFlags(modifiers: modifiers, base: base)
        flags.subtract(CGEventFlags(rawValue: 0x20000000))
        flags.subtract(.maskSecondaryFn)
        flags.formUnion(modifierFlags(modifiers))
        return flags
    }

    static func modifierFlags(_ modifiers: UInt32) -> CGEventFlags {
        var flags = CGEventFlags()
        if modifiers & 4096 != 0 {
            flags.insert(.maskControl)
            flags.insert(CGEventFlags(rawValue: 0x00000001))
        }
        if modifiers & 2048 != 0 {
            flags.insert(.maskAlternate)
            flags.insert(CGEventFlags(rawValue: 0x00000020))
        }
        if modifiers & 512 != 0 {
            flags.insert(.maskShift)
            flags.insert(CGEventFlags(rawValue: 0x00000002))
        }
        if modifiers & 256 != 0 {
            flags.insert(.maskCommand)
            flags.insert(CGEventFlags(rawValue: 0x00000008))
        }
        return flags
    }

    private static func modifierKeyCodes(_ modifiers: UInt32) -> [CGKeyCode] {
        var keys: [CGKeyCode] = []
        if modifiers & 4096 != 0 { keys.append(0x3B) }
        if modifiers & 2048 != 0 { keys.append(0x3A) }
        if modifiers & 512 != 0 { keys.append(0x38) }
        if modifiers & 256 != 0 { keys.append(0x37) }
        return keys
    }

    private static func postKey(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags, source: CGEventSource?) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    private static func postFlagsChanged(_ keyCode: CGKeyCode, flags: CGEventFlags, source: CGEventSource?) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        event?.type = .flagsChanged
        event?.flags = flags
        event?.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
        event?.post(tap: .cghidEventTap)
    }

    func postClick(_ button: MouseGestureButton, at point: CGPoint) {
        postPath(button, points: [point], click: true)
    }

    func postDrag(_ button: MouseGestureButton, path: [CGPoint]) {
        postPath(button, points: path, click: false)
    }

    private func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor in
                MouseGestureController.shared.tapWasDisabled()
            }
            return Unmanaged.passUnretained(event)
        }
        if Self.isReplay(event) {
            return Unmanaged.passUnretained(event)
        }
        guard let phase = Self.phase(type),
              let button = Self.button(for: type, event: event),
              listenedButtons.contains(button) else {
            return Unmanaged.passUnretained(event)
        }
        let point = Self.appKitPoint(fromQuartz: event.location, height: primaryHeight)
        switch phase {
        case .down:
            if activeButton != nil {
                return Unmanaged.passUnretained(event)
            }
            activeButton = button
            stroke = [point]
            recognizer.press(button, at: point, definitions: definitions)
            deliver(points: stroke, effects: [])
            return nil
        case .drag:
            guard activeButton == button else { return Unmanaged.passUnretained(event) }
            Self.appendSample(point, to: &stroke)
            let effects = recognizer.move(to: point)
            deliver(points: stroke, effects: effects)
            return nil
        case .up:
            guard activeButton == button else { return Unmanaged.passUnretained(event) }
            Self.appendSample(point, to: &stroke)
            let effects = recognizer.release()
            activeButton = nil
            deliver(points: stroke, effects: effects)
            stroke = []
            return nil
        }
    }

    private func deliver(points: [CGPoint], effects: [MouseGestureEffect]) {
        pendingPoints = points
        if !effects.isEmpty {
            pendingEffects.append(contentsOf: effects)
        }
        guard !deliverScheduled else { return }
        deliverScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.deliverScheduled = false
            let points = self.pendingPoints ?? []
            let effects = self.pendingEffects
            self.pendingPoints = nil
            self.pendingEffects = []
            self.onStroke?(points, effects)
        }
    }

    private static func appendSample(_ point: CGPoint, to points: inout [CGPoint]) {
        guard let last = points.last else {
            points = [point]
            return
        }
        if hypot(point.x - last.x, point.y - last.y) < minSampleDistance, points.count > 1 {
            points[points.count - 1] = point
        } else {
            points.append(point)
        }
    }

    private func postPath(_ button: MouseGestureButton, points: [CGPoint], click: Bool) {
        let samples = click ? [points.first ?? .zero] : Self.samples(points)
        guard let first = samples.first else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        func make(_ phase: Phase, at point: CGPoint) -> CGEvent? {
            let event = CGEvent(
                mouseEventSource: source,
                mouseType: Self.eventType(button: button, phase: phase),
                mouseCursorPosition: quartzPoint(fromAppKit: point),
                mouseButton: Self.cgButton(button)
            )
            event?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(Self.cgButton(button).rawValue))
            if let event { Self.markReplay(event) }
            return event
        }
        make(.down, at: first)?.post(tap: .cghidEventTap)
        if !click {
            for point in samples.dropFirst().dropLast() {
                make(.drag, at: point)?.post(tap: .cghidEventTap)
            }
        }
        make(.up, at: samples.last ?? first)?.post(tap: .cghidEventTap)
    }

    private func refreshPrimaryHeight() {
        primaryHeight = Self.primaryHeight()
    }

    private static func samples(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let stride = max(1, points.count / 12)
        var result = points.enumerated().compactMap { index, point in
            index % stride == 0 ? point : nil
        }
        if result.last != points.last, let last = points.last {
            result.append(last)
        }
        return result
    }

    private enum Phase {
        case down
        case drag
        case up
    }

    private static func phase(_ type: CGEventType) -> Phase? {
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: return .down
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: return .drag
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: return .up
        default: return nil
        }
    }

    private static func button(for type: CGEventType, event: CGEvent) -> MouseGestureButton? {
        switch type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            return .left
        case .rightMouseDown, .rightMouseDragged, .rightMouseUp:
            return .right
        case .otherMouseDown, .otherMouseDragged, .otherMouseUp:
            switch event.getIntegerValueField(.mouseEventButtonNumber) {
            case 2: return .middle
            case 3: return .back
            case 4: return .forward
            default: return nil
            }
        default:
            return nil
        }
    }

    private static func eventType(button: MouseGestureButton, phase: Phase) -> CGEventType {
        switch button {
        case .left:
            switch phase {
            case .down: return .leftMouseDown
            case .drag: return .leftMouseDragged
            case .up: return .leftMouseUp
            }
        case .right:
            switch phase {
            case .down: return .rightMouseDown
            case .drag: return .rightMouseDragged
            case .up: return .rightMouseUp
            }
        case .middle, .back, .forward:
            switch phase {
            case .down: return .otherMouseDown
            case .drag: return .otherMouseDragged
            case .up: return .otherMouseUp
            }
        }
    }

    private static func cgButton(_ button: MouseGestureButton) -> CGMouseButton {
        switch button {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        case .back: return CGMouseButton(rawValue: 3)!
        case .forward: return CGMouseButton(rawValue: 4)!
        }
    }

    /// Arrow keys are created with the function and numeric-pad bits set.
    /// Replacing the whole mask with only Control drops those bits, and the
    /// system shortcut for moving between spaces does not match.
    static func shortcutFlags(modifiers: UInt32, base: CGEventFlags) -> CGEventFlags {
        var flags = base
        flags.subtract([.maskControl, .maskAlternate, .maskShift, .maskCommand, .maskAlphaShift])
        if modifiers & 4096 != 0 { flags.insert(.maskControl) }
        if modifiers & 2048 != 0 { flags.insert(.maskAlternate) }
        if modifiers & 512 != 0 { flags.insert(.maskShift) }
        if modifiers & 256 != 0 { flags.insert(.maskCommand) }
        return flags
    }

    private static func markReplay(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: replayMark)
    }

    private static func isReplay(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == replayMark
    }

    private static func primaryHeight() -> CGFloat {
        if let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
            return screen.frame.height
        }
        return NSScreen.main?.frame.height ?? 0
    }

    private static func appKitPoint(fromQuartz point: CGPoint, height: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: height - point.y)
    }

    private func quartzPoint(fromAppKit point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}

enum SwipeLog {
    /// Off by default. Set true temporarily when debugging gestures; never needed for normal use.
    static var enabled = false

    private static let queue = DispatchQueue(label: "com.fastsome.swipe-log", qos: .utility)
    private static let formatter = ISO8601DateFormatter()
    private static let url = URL(fileURLWithPath: "/tmp/fastsome-swipe.log")
    private static let maxBytes = 512 * 1024

    static func write(_ message: String) {
        guard enabled else { return }
        let stamp = formatter.string(from: Date())
        queue.async {
            let line = "\(stamp) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? NSNumber,
               size.intValue > maxBytes {
                try? FileManager.default.removeItem(at: url)
            }
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
