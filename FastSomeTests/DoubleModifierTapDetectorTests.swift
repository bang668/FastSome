import XCTest
@testable import FastSome

final class DoubleModifierTapDetectorTests: XCTestCase {
    func testCleanDoubleTapFiresOnSecondUp() {
        var d = DoubleModifierTapDetector(interval: 0.35)
        let t0 = Date()
        XCTAssertNil(d.handle(.modifierDown(.command), now: t0))
        XCTAssertNil(d.handle(.modifierUp(.command), now: t0.addingTimeInterval(0.05)))
        XCTAssertNil(d.handle(.modifierDown(.command), now: t0.addingTimeInterval(0.10)))
        XCTAssertEqual(d.handle(.modifierUp(.command), now: t0.addingTimeInterval(0.15)), .command)
    }

    func testCommandVTwiceDoesNotFire() {
        var d = DoubleModifierTapDetector(interval: 0.35)
        let t0 = Date()
        // ⌘V
        XCTAssertNil(d.handle(.modifierDown(.command), now: t0))
        XCTAssertNil(d.handle(.otherKey, now: t0.addingTimeInterval(0.02)))
        XCTAssertNil(d.handle(.modifierUp(.command), now: t0.addingTimeInterval(0.04)))
        // ⌘V again quickly
        XCTAssertNil(d.handle(.modifierDown(.command), now: t0.addingTimeInterval(0.08)))
        XCTAssertNil(d.handle(.otherKey, now: t0.addingTimeInterval(0.10)))
        XCTAssertNil(d.handle(.modifierUp(.command), now: t0.addingTimeInterval(0.12)))
    }

    func testCleanTapThenChordDoesNotFire() {
        var d = DoubleModifierTapDetector(interval: 0.35)
        let t0 = Date()
        XCTAssertNil(d.handle(.modifierDown(.command), now: t0))
        XCTAssertNil(d.handle(.modifierUp(.command), now: t0.addingTimeInterval(0.05)))
        // Second press is ⌘V
        XCTAssertNil(d.handle(.modifierDown(.command), now: t0.addingTimeInterval(0.10)))
        XCTAssertNil(d.handle(.otherKey, now: t0.addingTimeInterval(0.12)))
        XCTAssertNil(d.handle(.modifierUp(.command), now: t0.addingTimeInterval(0.14)))
    }

    func testSlowSecondTapDoesNotFireButRearms() {
        var d = DoubleModifierTapDetector(interval: 0.35)
        let t0 = Date()
        XCTAssertNil(d.handle(.modifierDown(.option), now: t0))
        XCTAssertNil(d.handle(.modifierUp(.option), now: t0.addingTimeInterval(0.05)))
        XCTAssertNil(d.handle(.modifierDown(.option), now: t0.addingTimeInterval(0.50)))
        XCTAssertNil(d.handle(.modifierUp(.option), now: t0.addingTimeInterval(0.55)))
        // Now a quick third+fourth within window from the re-arm at 0.55
        XCTAssertNil(d.handle(.modifierDown(.option), now: t0.addingTimeInterval(0.60)))
        XCTAssertEqual(d.handle(.modifierUp(.option), now: t0.addingTimeInterval(0.65)), .option)
    }
}
