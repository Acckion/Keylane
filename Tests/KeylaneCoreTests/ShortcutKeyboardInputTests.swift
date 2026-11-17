import XCTest
@testable import KeylaneCore

final class ShortcutKeyboardInputTests: XCTestCase {
    func testCapturedChordStaysSelectedUntilNextModifierOnlyGesture() {
        let command: UInt32 = 256
        let shift: UInt32 = 512
        let option: UInt32 = 2048
        let first = Shortcut(key: 40, modifiers: command | shift)
        let next = Shortcut(key: 18, modifiers: option)
        var input = ShortcutKeyboardInput()

        input.modifiersChanged(command)
        XCTAssertEqual(input.previewModifiers, command)
        input.modifiersChanged(command | shift)
        XCTAssertEqual(input.previewModifiers, first.modifiers)
        input.modifiersChanged(shift)
        XCTAssertEqual(input.previewModifiers, shift)
        XCTAssertNil(input.selected)
        input.modifiersChanged(first.modifiers)
        input.select(first)

        input.modifiersChanged(command)
        XCTAssertNil(input.previewModifiers)
        input.modifiersChanged(0)
        XCTAssertEqual(input.selected, first)

        input.modifiersChanged(option)
        XCTAssertEqual(input.previewModifiers, option)
        input.modifiersChanged(0)
        XCTAssertNil(input.previewModifiers)
        XCTAssertNil(input.selected)

        input.modifiersChanged(option)
        input.select(next)
        input.resetPreview()
        XCTAssertNil(input.previewModifiers)
        XCTAssertEqual(input.selected, next)
    }

    func testCancelConsumesOnlyTheSelectedChord() {
        var input = ShortcutKeyboardInput()
        XCTAssertFalse(input.cancelSelection())
        input.select(.launcher)
        XCTAssertTrue(input.cancelSelection())
        XCTAssertNil(input.selected)
        XCTAssertFalse(input.cancelSelection())
    }
}
