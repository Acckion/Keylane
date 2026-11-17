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

    func testFractionalTilesMeetAtOddBoundariesWithIndependentGaps() throws {
        let screen = CGRect(x: -1201, y: 30, width: 1201, height: 801)
        let window = CGRect(x: -1100, y: 40, width: 200, height: 160)
        let first = WindowPlacement.region(CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1))
        let later = WindowPlacement.region(CGRect(x: 1.0 / 3, y: 0, width: 2.0 / 3, height: 1))
        let left = try XCTUnwrap(first.frame(for: window, displays: [screen], windowGap: 12, screenGap: 8))
        let right = try XCTUnwrap(later.frame(for: window, displays: [screen], windowGap: 12, screenGap: 8))
        XCTAssertEqual(left.minX, screen.minX + 8)
        XCTAssertEqual(right.maxX, screen.maxX - 8)
        XCTAssertEqual(right.minX - left.maxX, 12)
        XCTAssertEqual(left.minY, screen.minY + 8)
        XCTAssertEqual(right.maxY, screen.maxY - 8)
    }

    func testMoveEdgeCanKeepOrCenterOtherCoordinate() {
        let screen = CGRect(x: -1200, y: 0, width: 1200, height: 800)
        let window = CGRect(x: -700, y: 50, width: 400, height: 250)
        XCTAssertEqual(WindowPlacement.moveEdge(.right, centered: false).frame(for: window, displays: [screen], screenGap: 10),
                       CGRect(x: -410, y: 50, width: 400, height: 250))
        XCTAssertEqual(WindowPlacement.moveEdge(.right, centered: true).frame(for: window, displays: [screen], screenGap: 10),
                       CGRect(x: -410, y: 275, width: 400, height: 250))
    }

    func testSignedOffsetsAndMixedUnitsAreRelativeToPinnedPosition() throws {
        var custom = WindowGeometry()
        custom.anchor = .bottomRight
        custom.width = .init(50)
        custom.height = .init(200, percentage: false)
        custom.x = .init(-10)
        custom.y = .init(-20, percentage: false)
        let screen = CGRect(x: -1000, y: 40, width: 1000, height: 600)
        XCTAssertEqual(custom.frame(in: screen), CGRect(x: -600, y: 420, width: 500, height: 200))
        custom.x = .init(-110)
        XCTAssertNil(custom.frame(in: screen))
    }

    func testDisplayTransferWrapAndAspectRatioAreIndependent() throws {
        let primary = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let secondary = CGRect(x: 1000, y: 0, width: 1200, height: 600)
        let window = CGRect(x: 200, y: 100, width: 400, height: 400)
        let screens = [primary, secondary]
        let proportional = WindowPlacement.displayStep(1, wrap: false, keepAspectRatio: true)
        XCTAssertEqual(proportional.frame(for: window, displays: screens)?.size, CGSize(width: 300, height: 300))
        let stretched = WindowPlacement.displayStep(1, wrap: false, keepAspectRatio: false)
        XCTAssertEqual(stretched.frame(for: window, displays: screens)?.size, CGSize(width: 480, height: 300))
        XCTAssertNil(proportional.frame(for: secondary, displays: screens))
        XCTAssertNotNil(WindowPlacement.displayStep(1, wrap: true, keepAspectRatio: true).frame(for: secondary, displays: screens))
    }

    func testLayoutPreferredGapsAndFocusSelectionSurviveArchive() throws {
        let screen = CGRect(x: 0, y: 25, width: 1200, height: 800)
        let left = WindowLayoutEntry(bundleID: "org.keylane.left-fixture")
        var right = WindowLayoutEntry(bundleID: "org.keylane.right-fixture")
        right.geometry.anchor = .topRight
        var layout = CustomWindowAction(windows: [left, right])
        layout.name = "Two windows"
        layout.icon = "square.grid.2x2"
        layout.frontWindowID = right.id
        let data = try JSONEncoder().encode(WindowActionsArchive(actions: [layout]))
        let archive = try JSONDecoder().decode(WindowActionsArchive.self, from: data)
        XCTAssertEqual(archive.actions, [layout])
        XCTAssertTrue(archive.isValid)
        let frames = [left, right].compactMap { layout.displayFrame(for: $0, in: screen, windowGap: 12, screenGap: 10) }
        XCTAssertEqual(frames, [CGRect(x: 10, y: 35, width: 584, height: 780),
                                CGRect(x: 606, y: 35, width: 584, height: 780)])

        layout.usesPreferredGaps = nil
        layout.icon = nil
        layout.frontWindowID = nil
        let oldData = try JSONEncoder().encode(WindowActionsArchive(actions: [layout]))
        let oldLayout = try XCTUnwrap(JSONDecoder().decode(WindowActionsArchive.self, from: oldData).actions.first)
        XCTAssertEqual(oldLayout.displayFrame(for: right, in: screen, windowGap: 12, screenGap: 10),
                       CGRect(x: 600, y: 25, width: 600, height: 800))
        layout.frontWindowID = UUID()
        XCTAssertFalse(layout.isValid)
    }

    func testLayoutArchiveRoundTripAndPerDisplayLimit() throws {
        var layout = CustomWindowAction(windows: [.init(bundleID: "org.keylane.fixture")])
        layout.name = "Test layout"
        layout.windows?[0].argument = .quicklink("quicklink:fixture")
        layout.otherWindows = .minimize
        let archive = WindowActionsArchive(actions: [layout])
        XCTAssertTrue(archive.isValid)
        let data = try JSONEncoder().encode(archive)
        XCTAssertEqual(try JSONDecoder().decode(WindowActionsArchive.self, from: data).actions, [layout])
        layout.windows = (0..<9).map { _ in WindowLayoutEntry(bundleID: "org.keylane.fixture") }
        XCTAssertFalse(layout.isValid)
        layout.windows?[8].display = 1
        XCTAssertTrue(layout.isValid)
    }

    func testDraggingLayoutWindowPreservesSizeUnitsAndKeepsScreenGaps() throws {
        let screen = CGRect(x: -1200, y: 25, width: 1200, height: 800)
        var entry = WindowLayoutEntry(bundleID: "org.keylane.fixture")
        entry.geometry.anchor = .topRight
        entry.geometry.height = .init(200, percentage: false)
        entry.geometry.x = .init(-10)
        let layout = CustomWindowAction(windows: [entry])
        let moved = try XCTUnwrap(layout.draggedGeometry(for: entry, in: screen, windowGap: 12, screenGap: 10,
                                                       translation: CGSize(width: 1000, height: 400), minimumSize: 80))
        XCTAssertEqual(moved.anchor, entry.geometry.anchor)
        XCTAssertEqual(moved.width, entry.geometry.width)
        XCTAssertEqual(moved.height, entry.geometry.height)
        XCTAssertEqual(moved.x, .init(0))
        entry.geometry = moved
        XCTAssertEqual(layout.displayFrame(for: entry, in: screen, windowGap: 12, screenGap: 10),
                       CGRect(x: -594, y: 441, width: 584, height: 188))
    }

    func testResizingLayoutWindowKeepsOppositeCornerAndMinimumSize() throws {
        let screen = CGRect(x: -250, y: 20, width: 1000, height: 600)
        var entry = WindowLayoutEntry(bundleID: "org.keylane.fixture")
        entry.geometry.anchor = .bottomRight
        entry.geometry.height = .init(200, percentage: false)
        entry.geometry.x = .init(-10)
        entry.geometry.y = .init(-60, percentage: false)
        var layout = CustomWindowAction(windows: [entry])
        layout.usesPreferredGaps = false
        let resized = try XCTUnwrap(layout.draggedGeometry(for: entry, in: screen, windowGap: 12, screenGap: 10,
                                                          translation: CGSize(width: 800, height: 800),
                                                          resizingFrom: .topLeft, minimumSize: 80))
        XCTAssertEqual(resized.width, .init(8))
        XCTAssertEqual(resized.height, .init(80, percentage: false))
        XCTAssertEqual(resized.x, entry.geometry.x)
        XCTAssertEqual(resized.y, entry.geometry.y)
        XCTAssertEqual(resized.frame(in: screen), CGRect(x: 570, y: 480, width: 80, height: 80))
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
