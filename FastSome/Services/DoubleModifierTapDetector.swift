import Foundation

/// Pure state machine for double-tapping Control / Option / Command.
///
/// Only **clean** taps count: modifier down → up with no other key in between.
/// Fires on the **second clean lift**, so chords like ⌘V never look like a double-tap
/// (the second ⌘-down would otherwise fire before V arrives).
struct DoubleModifierTapDetector: Sendable {
    var interval: TimeInterval = 0.35

    private var armed: DoubleModifierKind?
    private var armedAt: Date?
    /// Modifier currently held for an in-progress tap, if any.
    private var pressKind: DoubleModifierKind?
    /// True if a non-modifier (or other interrupt) happened while `pressKind` was down.
    private var pressContaminated = false

    enum Event: Sendable {
        case modifierDown(DoubleModifierKind)
        case modifierUp(DoubleModifierKind)
        /// Any non-modifier key, or an interrupt that means this is not a lone modifier tap.
        case otherKey
    }

    mutating func reset() {
        armed = nil
        armedAt = nil
        pressKind = nil
        pressContaminated = false
    }

    /// Returns the kind when a double-tap completes (on the second clean key-up).
    mutating func handle(_ event: Event, now: Date = Date()) -> DoubleModifierKind? {
        switch event {
        case .otherKey:
            if pressKind != nil {
                pressContaminated = true
            }
            armed = nil
            armedAt = nil
            return nil

        case .modifierDown(let kind):
            pressKind = kind
            pressContaminated = false
            return nil

        case .modifierUp(let kind):
            let contaminated = (pressKind == kind) && pressContaminated
            if pressKind == kind {
                pressKind = nil
                pressContaminated = false
            }

            if contaminated {
                if armed == kind {
                    armed = nil
                    armedAt = nil
                }
                return nil
            }

            // Clean lift. Second clean tap within the window → fire.
            if let armed, armed == kind, let armedAt, now.timeIntervalSince(armedAt) <= interval {
                reset()
                return kind
            }

            // First clean tap (or a late second tap) → wait for another.
            self.armed = kind
            self.armedAt = now
            return nil
        }
    }
}
