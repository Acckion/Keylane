import XCTest
@testable import KeylaneCore

final class TransientFileSeenTests: XCTestCase {
    func testFullScanMarksAreTransactionalAndDoNotPersistAcrossScans() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try FileSearchIndex(url: dir.appendingPathComponent("index.sqlite"))
        let root = "/fixture"
        func row(_ name: String) -> FileIndexRecord {
            .init(path: root + "/" + name, name: name, volume: "/", modified: 1, directory: false, symlink: false)
        }
        let keep = row("keep.txt"), stale = row("stale.txt"), denied = row("locked/private.txt")
        for item in [keep, stale, denied] { try db.put(item, root: root, epoch: "n:old") }
        let durableWrites = db.writeDiagnostics.seenWrites
        let epoch = "n:full"
        try db.prepareTransientSeen(epoch: epoch)
        try db.stageMetadata(keep, root: root, epoch: epoch, contentSearch: false)
        // A live patch may prepare this same session after the baseline begins.
        try db.prepareTransientSeen(epoch: epoch)
        XCTAssertThrowsError(try db.transaction {
            try db.stageMetadata(stale, root: root, epoch: epoch, contentSearch: false)
            throw CancellationError()
        })
        try db.removeUnseen(root: root, epoch: epoch, preserving: [root + "/locked"])
        XCTAssertEqual(try db.stats().entries, 2)
        XCTAssertTrue(try db.search("stale", options: .init(roots: [root])).isEmpty)
        XCTAssertEqual(db.writeDiagnostics.seenWrites, durableWrites)
        try db.discardTransientSeen(epoch: epoch)

        try db.prepareTransientSeen(epoch: "n:next")
        try db.stageMetadata(denied, root: root, epoch: "n:next", contentSearch: false)
        try db.removeUnseen(root: root, epoch: "n:next")
        XCTAssertEqual(try db.stats().entries, 1)
        XCTAssertTrue(try db.search("keep", options: .init(roots: [root])).isEmpty)
        try db.discardTransientSeen(epoch: "n:next")
        try db.stageMetadata(denied, root: root, epoch: "n:incremental", contentSearch: false)
        XCTAssertEqual(db.writeDiagnostics.seenWrites, durableWrites + 1)
    }
}
