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
            ["[\"\",\"\(index)\"]", String(repeating: "a", count: ReviewedRaycastCache.maximumBytes / 4)]
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
    func testMergesConcurrentSnapshotChangesWithoutRestoringStaleValues() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReviewedRaycastCache(installationImage: root.appendingPathComponent("view.cpio"))
        let menu = ReviewedRaycastCache(installationImage: root.appendingPathComponent("menu-bar.cpio"))
        let a = #"["shared","a"]"#
        let b = #"["shared","b"]"#
        let c = #"["menu","c"]"#
        let d = #"["view","d"]"#
        let original = [[a, "old"], [b, "remove"]]
        try cache.save(original)
        // One guest updates a and adds c before another guest completes its read and write.
        try menu.merge([[b, "remove"], [a, "new"], [c, "added"]], from: original)
        try cache.merge([[a, "old"], [d, "added"]], from: original)
        XCTAssertEqual(menu.load(), [[a, "new"], [c, "added"], [d, "added"]])

        let beforeTouch = cache.load()
        try menu.merge([[c, "added"], [d, "added"], [a, "newer"]], from: beforeTouch)
        try cache.merge([[a, "new"], [d, "added"], [c, "added"]], from: beforeTouch)
        XCTAssertEqual(menu.load(), [[d, "added"], [a, "newer"], [c, "added"]])

        let composed = [[a, "é"]]
        let decomposed = "e\u{0301}"
        try cache.save(composed)
        try menu.merge([[a, decomposed]], from: composed)
        XCTAssertEqual(Array(cache.load()[0][1].utf8), Array(decomposed.utf8))
    }

}
