import CoreGraphics
import XCTest
@testable import FastSome

final class DesktopSwipeGestureTests: XCTestCase {
    private let controlRight = HotKeyCombo(keyCode: 124, modifiers: 4096)
    private let controlLeft = HotKeyCombo(keyCode: 123, modifiers: 4096)

    func testSystemEventsScriptUsesControlLeft() {
        XCTAssertEqual(
            DesktopSwipeMonitor.systemEventsScript(for: controlLeft),
            "tell application \"System Events\" to key code 123 using {control down}"
        )
    }

    func testControlLeftChordKeepsArrowMarks() {
        let base = CGEventFlags(rawValue: 0x20a00000)
        let merged = DesktopSwipeMonitor.chordFlags(modifiers: controlLeft.modifiers, base: base)
        XCTAssertTrue(merged.contains(.maskControl))
        XCTAssertFalse(merged.contains(.maskSecondaryFn))
        XCTAssertTrue(merged.contains(.maskNumericPad))
        XCTAssertEqual(merged.rawValue & 0x20000000, 0)
        XCTAssertEqual(merged.rawValue & 0x1, 0x1)
    }

    func testArrowShortcutKeepsFunctionFlag() {
        let base = CGEventFlags(rawValue: 0x20a00000)
        let merged = DesktopSwipeMonitor.shortcutFlags(modifiers: controlRight.modifiers, base: base)
        XCTAssertTrue(merged.contains(.maskControl))
        XCTAssertTrue(merged.contains(.maskSecondaryFn))
        XCTAssertTrue(merged.contains(.maskNumericPad))
    }

    func testLiveShortcutTextShowsHeldKeys() {
        XCTAssertEqual(HotKeyCombo.liveText(modifiers: 4096, keyCode: nil), "Control")
        XCTAssertEqual(HotKeyCombo.liveText(modifiers: 4096, keyCode: 124), "Control+→")
        XCTAssertEqual(
            HotKeyCombo.liveText(modifiers: 4096, keyCode: 3, modifierKeyCodes: [59]),
            "左 Control+F"
        )
        XCTAssertEqual(HotKeyCombo.liveText(modifiers: 4096, keyCode: 122), "Control+F1")
        XCTAssertEqual(HotKeyCombo.liveText(modifiers: 0, keyCode: nil), "")
        XCTAssertEqual(controlLeft.displayString, "Control+←")
        XCTAssertEqual(MouseGestureDirection.left.title, "左 ←")
    }

    func testPlainRightClickReplays() {
        var gesture = MouseGestureRecognizer()
        gesture.press(.right, at: CGPoint(x: 8, y: 8), definitions: [])
        XCTAssertEqual(gesture.move(to: CGPoint(x: 10, y: 8)), [])
        XCTAssertEqual(gesture.release(), [.replayClick(.right, CGPoint(x: 8, y: 8))])
    }

    func testLeftStrokeShowsTipAndFiresOnRelease() {
        let gestureDefinition = try! MouseGestureLibrary.make(
            button: .right,
            strokes: [.left],
            shortcut: controlRight,
            existing: []
        ).get()
        var gesture = MouseGestureRecognizer()
        gesture.press(.right, at: .zero, definitions: [gestureDefinition])
        XCTAssertEqual(gesture.move(to: CGPoint(x: -10, y: 0)), [.beginTrail])
        XCTAssertEqual(gesture.move(to: CGPoint(x: -40, y: 0)), [])
        XCTAssertEqual(gesture.move(to: CGPoint(x: -80, y: 0)), [])
        XCTAssertEqual(
            gesture.move(to: CGPoint(x: -100, y: 0)),
            [.showTip("松开后 Control+→")]
        )
        XCTAssertEqual(gesture.move(to: CGPoint(x: -140, y: 0)), [])
        XCTAssertEqual(
            gesture.release(),
            [.fadeTip, .clearTrail, .fireShortcut(controlRight)]
        )
    }

    func testUpwardCornerReplacesTheHorizontalMatch() {
        let horizontal = try! MouseGestureLibrary.make(
            button: .right, strokes: [.left], shortcut: controlRight, existing: []
        ).get()
        let corner = try! MouseGestureLibrary.make(
            button: .right, strokes: [.left, .up], shortcut: controlLeft, existing: [horizontal]
        ).get()
        var gesture = MouseGestureRecognizer()
        gesture.press(.right, at: .zero, definitions: [horizontal, corner])
        XCTAssertEqual(gesture.move(to: CGPoint(x: -100, y: 0)), [.beginTrail, .showTip("松开后 Control+→")])
        XCTAssertEqual(gesture.move(to: CGPoint(x: -100, y: 100)), [.showTip("松开后 Control+←")])
        XCTAssertEqual(gesture.release(), [.fadeTip, .clearTrail, .fireShortcut(controlLeft)])
    }

    func testExtraStrokeWithNoMatchClearsWithoutClick() {
        let horizontal = try! MouseGestureLibrary.make(
            button: .right, strokes: [.left], shortcut: controlRight, existing: []
        ).get()
        var gesture = MouseGestureRecognizer()
        gesture.press(.right, at: .zero, definitions: [horizontal])
        _ = gesture.move(to: CGPoint(x: -100, y: 0))
        XCTAssertEqual(gesture.move(to: CGPoint(x: -100, y: 100)), [.hideTip])
        XCTAssertEqual(gesture.release(), [.fadeTip, .clearTrail])
    }

    func testSmallShakeStaysOneStroke() {
        let horizontal = try! MouseGestureLibrary.make(
            button: .right, strokes: [.left], shortcut: controlRight, existing: []
        ).get()
        var gesture = MouseGestureRecognizer()
        gesture.press(.right, at: .zero, definitions: [horizontal])
        _ = gesture.move(to: CGPoint(x: -100, y: 0))
        XCTAssertEqual(gesture.move(to: CGPoint(x: -98, y: 3)), [])
        XCTAssertEqual(gesture.release(), [.fadeTip, .clearTrail, .fireShortcut(controlRight)])
    }

    func testUnmatchedLeftDragIsReturned() {
        var gesture = MouseGestureRecognizer()
        let start = CGPoint(x: 5, y: 5)
        gesture.press(.left, at: start, definitions: [])
        _ = gesture.move(to: CGPoint(x: 30, y: 5))
        let effects = gesture.release()
        XCTAssertEqual(effects.first, .fadeTip)
        guard case .replayDrag(let button, let path) = effects.last else {
            return XCTFail("expected a replayed drag")
        }
        XCTAssertEqual(button, .left)
        XCTAssertEqual(path.first, start)
        XCTAssertEqual(path.last, CGPoint(x: 30, y: 5))
    }

    func testShorterGestureDoesNotFireForALongerDrawing() {
        let horizontal = try! MouseGestureLibrary.make(
            button: .right, strokes: [.left], shortcut: controlRight, existing: []
        ).get()
        var gesture = MouseGestureRecognizer()
        gesture.press(.right, at: .zero, definitions: [horizontal])
        _ = gesture.move(to: CGPoint(x: -100, y: 0))
        _ = gesture.move(to: CGPoint(x: 20, y: 0))
        XCTAssertEqual(gesture.release(), [.fadeTip, .clearTrail])
    }

    func testDirectionsQuantizeToEightWays() {
        XCTAssertEqual(MouseGestureDirection.quantize(dx: -1, dy: 0), .left)
        XCTAssertEqual(MouseGestureDirection.quantize(dx: 1, dy: 0), .right)
        XCTAssertEqual(MouseGestureDirection.quantize(dx: 0, dy: 1), .up)
        XCTAssertEqual(MouseGestureDirection.quantize(dx: 0, dy: -1), .down)
        XCTAssertEqual(MouseGestureDirection.quantize(dx: -1, dy: 1), .upLeft)
        XCTAssertEqual(MouseGestureDirection.quantize(dx: 1, dy: -1), .downRight)
        // Cardinals prefer a dominant axis so L-corners stay left/down, not downLeft.
        XCTAssertEqual(MouseGestureDirection.quantize(dx: -0.3, dy: -1), .down)
        XCTAssertEqual(MouseGestureDirection.quantize(dx: -1, dy: 0.2), .left)
        XCTAssertEqual(MouseGestureDirection.quantize(dx: -1, dy: 0.6), .upLeft)
    }

    func testLeftThenDownCornerStillMatchesWithRoundedTurn() {
        let definition = try! MouseGestureLibrary.make(
            button: .right,
            strokes: [.left, .down],
            action: .text("ok"),
            existing: []
        ).get()
        var gesture = MouseGestureRecognizer()
        gesture.press(.right, at: .zero, definitions: [definition])
        // First stroke left.
        XCTAssertEqual(
            gesture.move(to: CGPoint(x: -100, y: 0)),
            [.beginTrail]
        )
        // Second stroke mostly down, with leftover left from a rounded corner.
        // Old quantize called this downLeft and never showed the tip.
        XCTAssertEqual(
            gesture.move(to: CGPoint(x: -130, y: -100)),
            [.showTip("松开后 粘贴：ok")]
        )
    }

    func testLibraryRejectsAdjacentRepeatAndDuplicate() {
        let shortcut = controlRight
        let first = try! MouseGestureLibrary.make(
            button: .right, strokes: [.left], shortcut: shortcut, existing: []
        ).get()
        XCTAssertEqual(
            MouseGestureLibrary.make(button: .right, strokes: [.left, .left], shortcut: shortcut, existing: []),
            .failure(.adjacentRepeat)
        )
        XCTAssertEqual(
            MouseGestureLibrary.make(button: .right, strokes: [.left], shortcut: shortcut, existing: [first]),
            .failure(.duplicate)
        )
        XCTAssertNotNil(try? MouseGestureLibrary.make(
            button: .left, strokes: [.left], shortcut: shortcut, existing: [first]
        ).get())
    }

    func testResizingDropsExtraStrokesAndAvoidsARepeat() {
        XCTAssertEqual(
            MouseGestureLibrary.resizing([.left, .up, .right], to: 2),
            [.left, .up]
        )
        XCTAssertEqual(
            MouseGestureLibrary.resizing([.left], to: 2),
            [.left, .right]
        )
        XCTAssertEqual(
            MouseGestureLibrary.resizing([.left, .up, .right, .down], to: 5).count,
            3
        )
        XCTAssertEqual(
            MouseGestureLibrary.make(button: .right, strokes: [.left, .up, .right, .down], shortcut: controlRight, existing: []),
            .failure(.tooMany)
        )
    }

    func testTextGestureShowsTipAndPastesOnRelease() {
        let definition = try! MouseGestureLibrary.make(
            button: .right,
            strokes: [.right],
            action: .text("你好，世界"),
            existing: []
        ).get()
        var gesture = MouseGestureRecognizer()
        gesture.press(.right, at: .zero, definitions: [definition])
        XCTAssertEqual(
            gesture.move(to: CGPoint(x: 100, y: 0)),
            [.beginTrail, .showTip("松开后 粘贴：你好，世界")]
        )
        XCTAssertEqual(
            gesture.release(),
            [.fadeTip, .clearTrail, .pasteText("你好，世界")]
        )
    }

    func testLibraryRejectsEmptyAndOversizedText() {
        XCTAssertEqual(
            MouseGestureLibrary.make(button: .right, strokes: [.left], action: .text("   "), existing: []),
            .failure(.emptyText)
        )
        let long = String(repeating: "a", count: MouseGestureAction.maxTextLength + 1)
        XCTAssertEqual(
            MouseGestureLibrary.make(button: .right, strokes: [.left], action: .text(long), existing: []),
            .failure(.textTooLong)
        )
    }

    func testLegacyShortcutJSONStillDecodes() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "button": "right",
          "strokes": ["left"],
          "shortcut": { "keyCode": 124, "modifiers": 4096 }
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MouseGestureDefinition.self, from: json)
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.action, .shortcut(controlRight))
    }

    func testUpdateVersionCompareHandlesTags() {
        XCTAssertEqual(UpdateChecker.compareVersions("1.0.0", "1.0.1"), .orderedAscending)
        XCTAssertEqual(UpdateChecker.compareVersions("1.0.1", "v1.0.1"), .orderedSame)
        XCTAssertEqual(UpdateChecker.compareVersions("1.1", "1.0.9"), .orderedDescending)
    }
}
