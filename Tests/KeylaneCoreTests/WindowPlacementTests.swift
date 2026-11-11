import XCTest
import KeylaneCore

final class WindowPlacementTests: XCTestCase {
    func testHalvesUseVisibleFrameAndMeetAtSameEdge() {
        let screen = CGRect(x: -1101, y: -740, width: 1101, height: 719)
        let window = CGRect(x: -800, y: -500, width: 240, height: 160)
        XCTAssertEqual(WindowPlacement.left.frame(for: window, displays: [screen]),
                       CGRect(x: -1101, y: -740, width: 550, height: 719))
        XCTAssertEqual(WindowPlacement.right.frame(for: window, displays: [screen]),
                       CGRect(x: -551, y: -740, width: 551, height: 719))
        XCTAssertEqual(WindowPlacement.bottom.frame(for: window, displays: [screen]),
                       CGRect(x: -1101, y: -381, width: 1101, height: 360))
    }

    func testCrossDisplayMoveAndRestoreAfterDisplayDisconnects() throws {
        let primary = CGRect(x: 0, y: 25, width: 1200, height: 750)
        let secondary = CGRect(x: -900, y: -400, width: 900, height: 500)
        let window = CGRect(x: 100, y: 120, width: 1000, height: 600)
        let moved = try XCTUnwrap(WindowPlacement.nextDisplay.frame(for: window, displays: [primary, secondary]))
        XCTAssertEqual(moved, secondary)
        XCTAssertEqual(WindowPlacement.restore.frame(for: moved, displays: [primary, secondary], previous: window), window)
        XCTAssertEqual(WindowPlacement.restore.frame(for: window, displays: [primary], previous: secondary),
                       CGRect(x: 0, y: 25, width: 900, height: 500))
        XCTAssertNil(WindowPlacement.nextDisplay.frame(for: window, displays: [primary]))
        XCTAssertNil(WindowPlacement.restore.frame(for: window, displays: [primary]))
    }
}
