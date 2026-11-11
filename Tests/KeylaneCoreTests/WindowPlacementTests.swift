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

    func testRestorePreservesFrameAcrossConnectedDisplays() {
        let primary = CGRect(x: 0, y: 25, width: 1200, height: 750)
        let secondary = CGRect(x: 1200, y: 50, width: 1200, height: 700)
        let saved = CGRect(x: 900, y: 100, width: 600, height: 450)
        XCTAssertEqual(WindowPlacement.restore.frame(for: primary, displays: [primary, secondary], previous: saved), saved)
        XCTAssertEqual(WindowPlacement.restore.frame(for: primary, displays: [primary], previous: saved),
                       CGRect(x: 600, y: 100, width: 600, height: 450))
    }

    func testRestoreDoesNotTreatGapBetweenDisplaysAsUsable() {
        let primary = CGRect(x: 0, y: 25, width: 1200, height: 750)
        let secondary = CGRect(x: 1250, y: 25, width: 1200, height: 750)
        let saved = CGRect(x: 900, y: 100, width: 600, height: 450)
        XCTAssertEqual(WindowPlacement.restore.frame(for: primary, displays: [primary, secondary], previous: saved),
                       CGRect(x: 600, y: 100, width: 600, height: 450))
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
