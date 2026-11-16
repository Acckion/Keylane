import Foundation
import KeylaneCore
import XCTest

final class UninstallItemSizeTests: XCTestCase {
    func testMeasuresNestedFilesWithoutFollowingLinks() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let folder = root.appendingPathComponent("measure")
        let nested = folder.appendingPathComponent("nested")
        try files.createDirectory(at: nested, withIntermediateDirectories: true)
        let inside = nested.appendingPathComponent("inside")
        let outside = root.appendingPathComponent("outside")
        try Data(repeating: 42, count: 131_072).write(to: inside)
        try Data(repeating: 21, count: 262_144).write(to: outside)
        let link = folder.appendingPathComponent("linked")
        try files.createSymbolicLink(at: link, withDestinationURL: outside)

        let file = try XCTUnwrap(UninstallItemSize.measure(inside, cancelled: { false }))
        XCTAssertGreaterThan(file.bytes, 0)
        XCTAssertTrue(file.complete)
        XCTAssertEqual(UninstallItemSize.measure(folder, cancelled: { false }), file)
        XCTAssertEqual(UninstallItemSize.measure(link, cancelled: { false })?.complete, false)
        XCTAssertEqual(UninstallItemSize.measure(root.appendingPathComponent("missing"), cancelled: { false })?.complete, false)
        XCTAssertNil(UninstallItemSize.measure(folder, cancelled: { true }))
    }
}
