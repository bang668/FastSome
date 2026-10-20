import AppKit
import CoreGraphics
import Darwin
import IOKit

/// Adjusts vertical scroll from mice (including Magic Mouse): optional reverse + step scale.
/// Trackpad scrolling is left to the system "natural scrolling" preference.
final class MouseScrollReverser {
    static let shared = MouseScrollReverser()

    private var port: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastMultiTouchUptime: UInt64 = 0
    private var senderIsTrackpad: [UInt64: Bool] = [:]

    private var reverseEnabled = false
    private var stepMultiplier: Double = 1

    /// Treat continuous scroll as trackpad for this long after 2+ finger touch (covers momentum).
    private static let trackpadTouchGraceNs: UInt64 = 1_500_000_000

    var isInstalled: Bool { port != nil }

    /// Installs the tap when reverse is on or step is not 100%.
    func apply(reverseEnabled: Bool, stepPercent: Int) {
        self.reverseEnabled = reverseEnabled
        let percent = max(1, stepPercent)
        stepMultiplier = Double(percent) / 100.0
        let needsTap = reverseEnabled || percent != 100
        if needsTap {
            if !isInstalled {
                _ = start()
            }
        } else {
            stop()
        }
    }

    func setEnabled(_ enabled: Bool) {
        apply(reverseEnabled: enabled, stepPercent: Int((stepMultiplier * 100).rounded()))
    }

    @discardableResult
    func start() -> Bool {
        stop()
        let scrollMask: CGEventMask = 1 << CGEventType.scrollWheel.rawValue
        let gestureType = CGEventType(rawValue: UInt32(NSEvent.EventType.gesture.rawValue)) ?? .null
        let gestureMask: CGEventMask = gestureType == .null ? 0 : 1 << gestureType.rawValue
        let mask = scrollMask | gestureMask
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let reverser = Unmanaged<MouseScrollReverser>.fromOpaque(userInfo).takeUnretainedValue()
                return reverser.receive(type: type, event: event)
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
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
            self.port = nil
        }
        senderIsTrackpad.removeAll(keepingCapacity: true)
    }

    /// Re-enable after the system disables the tap (timeout / user input).
    func refresh() {
        guard let port else { return }
        if !CGEvent.tapIsEnabled(tap: port) {
            CGEvent.tapEnable(tap: port, enable: true)
        }
    }

    private func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            refresh()
            return Unmanaged.passUnretained(event)
        }

        let gestureType = CGEventType(rawValue: UInt32(NSEvent.EventType.gesture.rawValue))
        if let gestureType, type == gestureType {
            noteGesture(event)
            return Unmanaged.passUnretained(event)
        }

        guard type == .scrollWheel else {
            return Unmanaged.passUnretained(event)
        }

        if isMouseVerticalScroll(event) {
            if reverseEnabled {
                reverseVertical(event)
            }
            if abs(stepMultiplier - 1) > 0.001 {
                scaleVertical(event, factor: stepMultiplier)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    private func noteGesture(_ event: CGEvent) {
        guard let nsEvent = NSEvent(cgEvent: event) else { return }
        let touching = nsEvent.touches(matching: .touching, in: nil).count
        if touching >= 2 {
            lastMultiTouchUptime = DispatchTime.now().uptimeNanoseconds
        }
    }

    private func isMouseVerticalScroll(_ event: CGEvent) -> Bool {
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        if !continuous {
            // Discrete wheel → mouse.
            return true
        }

        if let trackpad = trackpadHintFromHID(event) {
            return !trackpad
        }

        // Continuous + recent multitouch → trackpad (incl. momentum). Otherwise mouse / Magic Mouse.
        let elapsed = DispatchTime.now().uptimeNanoseconds &- lastMultiTouchUptime
        if lastMultiTouchUptime != 0, elapsed < Self.trackpadTouchGraceNs {
            return false
        }
        return true
    }

    private func trackpadHintFromHID(_ event: CGEvent) -> Bool? {
        guard let hid = IOHIDSPI.copyIOHIDEvent(event) else { return nil }
        defer { hid.release() }
        let senderID = IOHIDSPI.senderID(hid.toOpaque())
        guard senderID != 0 else { return nil }
        if let cached = senderIsTrackpad[senderID] {
            return cached
        }
        let isTrackpad = Self.registryLooksLikeTrackpad(senderID: senderID)
        if let isTrackpad {
            senderIsTrackpad[senderID] = isTrackpad
        }
        return isTrackpad
    }

    private static func registryLooksLikeTrackpad(senderID: UInt64) -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(senderID))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        if let accel = IORegistryEntryCreateCFProperty(
            service,
            "HIDScrollAccelerationType" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String {
            if accel == "HIDTrackpadScrollAcceleration" { return true }
            if accel == "HIDMouseScrollAcceleration" { return false }
        }

        if conformsToTrackpadDriver(service) { return true }
        var parent: io_registry_entry_t = 0
        if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS {
            defer { IOObjectRelease(parent) }
            if conformsToTrackpadDriver(parent) { return true }
        }
        return false
    }

    private static func conformsToTrackpadDriver(_ service: io_service_t) -> Bool {
        IOObjectConformsTo(service, "AppleMultitouchTrackpadHIDEventDriver") != 0
    }

    /// Negate vertical scroll fields. Point/fixed must be set after DeltaAxis (Scroll Reverser note).
    private func reverseVertical(_ event: CGEvent) {
        let axis1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let point1 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let fixed1 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)

        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -axis1)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixed1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -point1)

        if let hid = IOHIDSPI.copyIOHIDEvent(event) {
            defer { hid.release() }
            let y = IOHIDSPI.getFloat(hid.toOpaque(), field: IOHIDSPI.scrollYField)
            IOHIDSPI.setFloat(hid.toOpaque(), field: IOHIDSPI.scrollYField, value: -y)
        }
    }

    private func scaleVertical(_ event: CGEvent, factor: Double) {
        let axis1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let point1 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let fixed1 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)

        let scaledAxis = Int64((Double(axis1) * factor).rounded())
        let scaledPoint = Int64((Double(point1) * factor).rounded())
        // Keep at least one line/point if the source had a non-zero tick (avoid swallowing notches).
        let axisOut = (axis1 != 0 && scaledAxis == 0) ? (axis1 > 0 ? 1 : -1) : scaledAxis
        let pointOut = (point1 != 0 && scaledPoint == 0) ? (point1 > 0 ? 1 : -1) : scaledPoint

        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: axisOut)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixed1 * factor)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: pointOut)

        if let hid = IOHIDSPI.copyIOHIDEvent(event) {
            defer { hid.release() }
            let y = IOHIDSPI.getFloat(hid.toOpaque(), field: IOHIDSPI.scrollYField)
            IOHIDSPI.setFloat(hid.toOpaque(), field: IOHIDSPI.scrollYField, value: y * factor)
        }
    }
}

// MARK: - Private IOHID helpers (SPI used by Scroll Reverser for WebKit)

private enum IOHIDSPI {
    /// kIOHIDEventTypeScroll (12) << 16 | 1
    static let scrollYField: UInt32 = (12 << 16) | 1

    private typealias CopyFn = @convention(c) (CGEvent?) -> Unmanaged<AnyObject>?
    private typealias GetFloatFn = @convention(c) (UnsafeRawPointer?, UInt32) -> Double
    private typealias SetFloatFn = @convention(c) (UnsafeRawPointer?, UInt32, Double) -> Void
    private typealias GetSenderFn = @convention(c) (UnsafeRawPointer?) -> UInt64

    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

    private static let copyFn: CopyFn? = load("CGEventCopyIOHIDEvent")
    private static let getFloatFn: GetFloatFn? = load("IOHIDEventGetFloatValue")
    private static let setFloatFn: SetFloatFn? = load("IOHIDEventSetFloatValue")
    private static let getSenderFn: GetSenderFn? = load("IOHIDEventGetSenderID")

    private static func load<T>(_ name: String) -> T? {
        guard let sym = dlsym(rtldDefault, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    static func copyIOHIDEvent(_ event: CGEvent) -> Unmanaged<AnyObject>? {
        copyFn?(event)
    }

    static func getFloat(_ event: UnsafeRawPointer?, field: UInt32) -> Double {
        getFloatFn?(event, field) ?? 0
    }

    static func setFloat(_ event: UnsafeRawPointer?, field: UInt32, value: Double) {
        setFloatFn?(event, field, value)
    }

    static func senderID(_ event: UnsafeRawPointer?) -> UInt64 {
        getSenderFn?(event) ?? 0
    }
}
