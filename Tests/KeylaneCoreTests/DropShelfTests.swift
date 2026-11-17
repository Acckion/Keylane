import XCTest
@testable import KeylaneCore

final class DropShelfTests: XCTestCase {
    private func fixture(_ run: (URL, DropShelfStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeylaneShelfTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DropShelfStore(directory: root.appendingPathComponent("Storage"))
        try run(root, store)
    }
    func testReferencesSurviveRestartWithoutCopyingOrRemovingSources() throws {
        try fixture { root, store in
            let source = root.appendingPathComponent("source.txt")
            try Data("first".utf8).write(to: source)
            let id = try store.create()
            XCTAssertTrue(try store.addFile(source, to: id))
            XCTAssertFalse(try store.addFile(source, to: id))
            let other = root.appendingPathComponent("other", isDirectory: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            let sameName = other.appendingPathComponent("source.txt")
            try Data("second".utf8).write(to: sameName)
            XCTAssertTrue(try store.addFile(sameName, to: id))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.assetsDirectory.path).isEmpty)
            let restored = try DropShelfStore(directory: store.directory)
            XCTAssertEqual(restored.shelf(id)?.items.count, 2)
            try Data("changed".utf8).write(to: source)
            let resolved = try XCTUnwrap(restored.resolve(try XCTUnwrap(restored.shelf(id)?.items.first)))
            XCTAssertEqual(try String(contentsOf: resolved, encoding: .utf8), "changed")
            try restored.remove(id)
            try restored.collectUnusedAssets()
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: sameName.path))
        }
    }
    func testHistoryPinsAndOwnedAssetCleanup() throws {
        try fixture { _, store in
            let pinned = try store.create()
            try store.addAsset(Data([1,2,3]), name: "fixture.png", kind: .image, to: pinned)
            XCTAssertFalse(try store.addAsset(Data([1,2,3]), name: "duplicate.png", kind: .image, to: pinned))
            try store.pin(pinned, value: true)
            for n in 0..<15 {
                let id = try store.create(); try store.addText("text \(n)", to: id); try store.remember(id)
            }
            XCTAssertEqual(store.shelves.count, 11)
            XCTAssertEqual(store.shelf(pinned)?.pinned, true)
            let asset = try XCTUnwrap(store.resolve(try XCTUnwrap(store.shelf(pinned)?.items.first)))
            try store.collectUnusedAssets(); XCTAssertTrue(FileManager.default.fileExists(atPath: asset.path))
            try store.remove(pinned); try store.collectUnusedAssets()
            XCTAssertFalse(FileManager.default.fileExists(atPath: asset.path))
        }
    }
    func testPromiseCannotAdoptExternalFileAndGeneratedContentRoundTrips() throws {
        try fixture { root, store in
            let id = try store.create()
            let outside = root.appendingPathComponent("outside.txt")
            try Data("untouched".utf8).write(to: outside)
            let batch = store.directory.appendingPathComponent("Incoming/test")
            try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
            XCTAssertThrowsError(try store.adoptPromise(outside, from: batch, to: id))
            XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "untouched")
            let promised = batch.appendingPathComponent("promise.txt")
            try Data("promised".utf8).write(to: promised)
            XCTAssertTrue(try store.adoptPromise(promised, from: batch, to: id))
            XCTAssertTrue(try store.addText("hello", to: id))
            XCTAssertFalse(try store.addText("hello", to: id))
            XCTAssertTrue(try store.addText("https://example.invalid", link: true, to: id))
            let restored = try DropShelfStore(directory: store.directory)
            XCTAssertEqual(restored.shelf(id)?.items.count, 3)
            XCTAssertFalse(FileManager.default.fileExists(atPath: promised.path))
            let first = try XCTUnwrap(restored.shelf(id)?.items.first)
            XCTAssertEqual(try String(contentsOf: XCTUnwrap(restored.resolve(first)), encoding: .utf8), "promised")
        }
    }
    func testCorruptArchiveIsPreservedAndMutationFailureRollsBack() throws {
        try fixture { _, store in
            let id = try store.create()
            let archive = store.directory.appendingPathComponent("shelves.json")
            try FileManager.default.removeItem(at: archive)
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: false)
            XCTAssertThrowsError(try store.addText("cannot save", to: id))
            XCTAssertEqual(store.shelf(id)?.items.count, 0)
            try FileManager.default.removeItem(at: archive)
            let bad = Data("not json".utf8); try bad.write(to: archive)
            XCTAssertThrowsError(try DropShelfStore(directory: store.directory))
            XCTAssertEqual(try Data(contentsOf: archive), bad)
        }
    }
    func testBookmarkTracksMoveAndDeletionDoesNotTouchReplacement() throws {
        try fixture { root, store in
            let original = root.appendingPathComponent("original.txt")
            let renamed = root.appendingPathComponent("renamed.txt")
            try Data("first".utf8).write(to: original)
            let id = try store.create(); try store.addFile(original, to: id)
            let item = try XCTUnwrap(store.shelf(id)?.items.first)
            try FileManager.default.moveItem(at: original, to: renamed)
            let resolved = try XCTUnwrap(store.resolve(item))
            XCTAssertEqual(resolved.standardizedFileURL, renamed.standardizedFileURL)
            try store.refreshReference(item, in: id, resolved: resolved)
            XCTAssertEqual(store.shelf(id)?.items.first?.title, "renamed.txt")
            try Data("replacement".utf8).write(to: original)
            try store.remove(id)
            XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "replacement")
            XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "first")
        }
    }
    func testOwnedAssetMoveIsFollowedButCleanupNeverDeletesDestination() throws {
        try fixture { root, store in
            let id = try store.create()
            try store.addAsset(Data([1, 2, 3]), name: "image.png", kind: .image, to: id)
            let item = try XCTUnwrap(store.shelf(id)?.items.first)
            let asset = try XCTUnwrap(store.resolve(item))
            let destination = root.appendingPathComponent("exported.png")
            try FileManager.default.moveItem(at: asset, to: destination)
            XCTAssertEqual(try store.resolve(item)?.standardizedFileURL, destination.standardizedFileURL)
            try store.remove(id); try store.collectUnusedAssets()
            XCTAssertEqual(try Data(contentsOf: destination), Data([1, 2, 3]))
        }
    }

    func testShelfDeletionNotifiesOnceAndPreservesExternalFiles() throws {
        try fixture { root, store in
            var notifications = 0
            store.didChange = { notifications += 1 }
            let source = root.appendingPathComponent("manager-source.txt")
            try Data("source".utf8).write(to: source)
            let id = try store.create()
            try store.addFile(source, to: id)
            try store.pin(id, value: true)
            let before = notifications
            try store.deleteShelf(id)
            XCTAssertEqual(notifications, before + 1)
            XCTAssertNil(store.shelf(id))
            XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "source")
            XCTAssertNil(try DropShelfStore(directory: store.directory).shelf(id))
        }
    }

}
