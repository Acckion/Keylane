import XCTest
@testable import KeylaneCore

final class AICapabilitySelectionTests: XCTestCase {
    func testExplicitSelectionDoesNotAutoEnableNewOrUnownedTools() {
        let a = ModuleID(rawValue: "a"), b = ModuleID(rawValue: "b"), c = ModuleID(rawValue: "c")
        let all = AICapabilitySelection()
        XCTAssertTrue(all.permits(nil))
        let narrowed = all.setting(b, enabled: false, available: [a, b])
        XCTAssertTrue(narrowed.permits(a))
        XCTAssertFalse(narrowed.permits(b))
        XCTAssertFalse(narrowed.permits(c))
        XCTAssertFalse(narrowed.permits(nil))
        XCTAssertFalse(narrowed.setting(a, enabled: false, available: [a, b]).permits(a))
        XCTAssertTrue(narrowed.setting(b, enabled: true, available: [a, b]).permits(b))
    }
}
