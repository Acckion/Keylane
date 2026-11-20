import XCTest
@testable import KeylaneCore

final class ShortcutMapTests: XCTestCase {
    let chord = Shortcut(key: 37, modifiers: 256)

    func testMenuFlagsHaveDifferentEncodingFromCarbon() {
        XCTAssertEqual(ShortcutMapConversion.menu(virtualKey: 37, modifiers: 7), Shortcut(key: 37, modifiers: 256 | 512 | 2048 | 4096))
        XCTAssertEqual(ShortcutMapConversion.menu(virtualKey: 37, modifiers: 8), Shortcut(key: 37, modifiers: 0))
        XCTAssertEqual(ShortcutMapConversion.menu(virtualKey: 37, modifiers: nil), chord)
        XCTAssertNil(ShortcutMapConversion.menu(virtualKey: nil, modifiers: 0))
        XCTAssertNil(ShortcutMapConversion.menu(virtualKey: -1, modifiers: 0))
        XCTAssertNil(ShortcutMapConversion.menu(virtualKey: 128, modifiers: 0))
        XCTAssertNil(ShortcutMapConversion.menu(virtualKey: 37, modifiers: 16))
    }

    func testApplicationOverlapIsContextualAndDisabledItemsDoNotConflict() {
        var entry = ShortcutMapEntry(id: "menu", shortcut: chord, title: "Location", source: .application, applicationID: "safari")
        XCTAssertEqual(entry.conflict(with: chord, applicationID: "safari"), .applicationOverlap)
        XCTAssertNil(entry.conflict(with: chord, applicationID: "xcode"))
        entry.enabled = false
        XCTAssertNil(entry.conflict(with: chord, applicationID: "safari"))
        entry.enabled = true
        XCTAssertNil(entry.conflict(with: .init(key: 0, modifiers: 256), applicationID: "safari"))
    }

    func testGlobalSourcesRemainGlobal() {
        let system = ShortcutMapEntry(id: "system", shortcut: chord, title: "System", source: .system)
        let local = ShortcutMapEntry(id: "binding", shortcut: chord, title: "Command", source: .keylane)
        XCTAssertEqual(system.conflict(with: chord, applicationID: "anything"), .systemReserved)
        XCTAssertEqual(local.conflict(with: chord, applicationID: nil), .keylaneBinding)
    }

    func testRegistrationFailureDoesNotInventAnOwnerOrConflict() {
        XCTAssertTrue(ShortcutMapConversion.registrationError(-9878).contains("未提供所属应用"))
        XCTAssertFalse(ShortcutMapConversion.registrationError(-50).contains("已被"))
        XCTAssertTrue(ShortcutMapConversion.registrationError(-9868).contains("无法据此判断"))
        XCTAssertTrue(ShortcutMapConversion.registrationError(0).contains("无法据此判断"))
    }
}
