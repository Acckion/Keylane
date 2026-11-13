import Foundation
import XCTest
@testable import KeylaneCore

final class ReviewedRaycastCacheTests: XCTestCase {
    func testPersistsAcrossInstancesAndIsolatesInstallationDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first/view.cpio")
        let second = root.appendingPathComponent("second/view.cpio")
        for image in [first, second] {
            try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        let cache = ReviewedRaycastCache(installationImage: first)
        let entries = [["[\"scope\",\"z\"]", "缓存"], ["[\"scope\",\"a\"]", "first"]]
        XCTAssertEqual(cache.load(), [])
        try cache.save(entries)
        XCTAssertEqual(ReviewedRaycastCache(installationImage: first).load(), entries)
        XCTAssertEqual(ReviewedRaycastCache(installationImage: second).load(), [])

        let tooLarge = (0..<4).map { index in
            ["[\"\",\"\(index)\"]", String(repeating: "a", count: 1_024)]
        }
        XCTAssertThrowsError(try cache.save(tooLarge))
        XCTAssertEqual(cache.load(), entries)
        XCTAssertThrowsError(try cache.save([["not a tuple", "invalid"]]))
        XCTAssertThrowsError(try cache.save([entries[0], entries[0]]))
        let legacy = try JSONEncoder().encode([entries[0][0]: entries[0][1]])
        try legacy.write(to: first.deletingLastPathComponent().appendingPathComponent("cache.json"))
        XCTAssertEqual(cache.load(), [entries[0]])
        try cache.remove()
        try cache.remove()
        XCTAssertEqual(cache.load(), [])
    }
}
