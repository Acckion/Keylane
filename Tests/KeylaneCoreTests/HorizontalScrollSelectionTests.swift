import XCTest
@testable import KeylaneCore

final class HorizontalScrollSelectionTests: XCTestCase {
    func testTracksDistanceAndCommitsAfterRelease() {
        var gesture = HorizontalScrollSelection()
        XCTAssertEqual(gesture.drag(horizontal: -12, vertical: 4), -12)
        XCTAssertEqual(gesture.drag(horizontal: -24, vertical: 3), -36)
        XCTAssertEqual(gesture.finish(threshold: 32), 1)
        XCTAssertNil(gesture.finish(threshold: 32))
    }

    func testVerticalAndShortGesturesDoNotSwitchPages() {
        var gesture = HorizontalScrollSelection()
        XCTAssertNil(gesture.drag(horizontal: 1, vertical: 3))
        XCTAssertEqual(gesture.drag(horizontal: 6, vertical: 1), 6)
        XCTAssertNil(gesture.finish(threshold: 32))
    }

    func testReversalTracksTheFingerAndWheelCanStep() {
        var gesture = HorizontalScrollSelection()
        XCTAssertEqual(gesture.drag(horizontal: 15, vertical: 0), 15)
        XCTAssertEqual(gesture.drag(horizontal: -12, vertical: 0), 3)
        gesture.reset()
        XCTAssertEqual(gesture.drag(horizontal: 1, vertical: 0), 1)
        XCTAssertEqual(gesture.finish(threshold: 1), -1)
    }
}
