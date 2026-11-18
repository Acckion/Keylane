import XCTest
@testable import KeylaneCore

final class DropShelfTests: XCTestCase {
    func testReorderingBeforeItselfPreservesOrderWithoutPersistingAChange() throws {
        try fixture { _, store in
            let id = try store.create()
            for value in ["first", "second", "third"] { try store.addText(value, to: id) }
            let items = store.shelf(id)!.items
            var changes = 0
            store.didChange = { changes += 1 }
            try store.reorder(id, item: items[0].id, before: items[0].id)
            XCTAssertEqual(store.shelf(id)!.items, items)
            XCTAssertEqual(changes, 0)
            XCTAssertEqual(try DropShelfStore(directory: store.directory).shelf(id)!.items, items)
            try store.reorder(id, item: items[2].id, before: items[0].id)
            XCTAssertEqual(store.shelf(id)!.items.map(\.id), [items[2].id, items[0].id, items[1].id])
        }
    }
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
    func testClosingEmptyShelfDoesNotEvictRecentHistory() throws {
        try fixture { _, store in
            var saved: [UUID] = []
            for n in 0..<10 {
                let id = try store.create()
                try store.addText("saved \(n)", to: id)
                try store.remember(id)
                saved.append(id)
            }
            let empty = try store.create()
            try store.remember(empty)
            XCTAssertNil(store.shelf(empty))
            XCTAssertEqual(Set(store.shelves.map(\.id)), Set(saved))
            XCTAssertEqual(try DropShelfStore(directory: store.directory).shelves.count, 10)
        }
    }

    func testCrossShelfBookmarksRetainOwnedAssetsAfterSourceDeletionAndRestart() throws {
        try fixture { _, store in
            let original = try store.create()
            let destination = try store.create()
            try store.pin(destination, value: true)
            try store.addAsset(Data([1, 2, 3]), name: "image.png", kind: .image, to: original)
            let image = try XCTUnwrap(store.resolve(try XCTUnwrap(store.shelf(original)?.items.first)))
            let batch = store.directory.appendingPathComponent("Incoming/test")
            try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
            let folder = batch.appendingPathComponent("promised", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("promised".utf8).write(to: folder.appendingPathComponent("child.txt"))
            try store.adoptPromise(folder, from: batch, to: original)
            let promised = try XCTUnwrap(store.resolve(try XCTUnwrap(store.shelf(original)?.items.last)))
            // Text/link exports have no explicit asset field in the source shelf.
            let text = store.assetsDirectory.appendingPathComponent("export.txt")
            let link = store.assetsDirectory.appendingPathComponent("export.webloc")
            try Data("text".utf8).write(to: text)
            try Data("link".utf8).write(to: link)
            let urls = [image, promised.appendingPathComponent("child.txt"), text, link]
            for url in urls { try store.addFile(url, to: destination) }
            XCTAssertTrue(store.shelf(destination)!.items.allSatisfy { $0.asset == nil })
            try store.deleteShelf(original)
            let unused = store.assetsDirectory.appendingPathComponent("unused.txt")
            try Data("unused".utf8).write(to: unused)
            let restored = try DropShelfStore(directory: store.directory)
            try restored.collectUnusedAssets()
            for (item, url) in zip(restored.shelf(destination)!.items, urls) {
                XCTAssertEqual(try Data(contentsOf: XCTUnwrap(restored.resolve(item))), try Data(contentsOf: url))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: unused.path))
            try restored.deleteShelf(destination)
            try restored.collectUnusedAssets()
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: restored.assetsDirectory.path).isEmpty)
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
    func testPromisedFilesKeepBasenamesWithoutCollisions() throws {
        try fixture { _, store in
            let id = try store.create()
            let batch = store.directory.appendingPathComponent("Incoming/names")
            try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
            let source = batch.appendingPathComponent("invoice.pdf")
            for content in ["first", "second"] {
                try Data(content.utf8).write(to: source)
                try store.adoptPromise(source, from: batch, to: id)
            }
            let folder = batch.appendingPathComponent("Package", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("child".utf8).write(to: folder.appendingPathComponent("child.txt"))
            try store.adoptPromise(folder, from: batch, to: id)
            let restored = try DropShelfStore(directory: store.directory)
            try restored.collectUnusedAssets()
            let items = try XCTUnwrap(restored.shelf(id)?.items)
            let urls = try items.map { try XCTUnwrap(restored.resolve($0)) }
            XCTAssertEqual(urls.map(\.lastPathComponent), ["invoice.pdf", "invoice.pdf", "Package"])
            XCTAssertNotEqual(urls[0].deletingLastPathComponent(), urls[1].deletingLastPathComponent())
            XCTAssertEqual(try String(contentsOf: urls[0], encoding: .utf8), "first")
            XCTAssertEqual(try String(contentsOf: urls[1], encoding: .utf8), "second")
            XCTAssertEqual(try String(contentsOf: urls[2].appendingPathComponent("child.txt"), encoding: .utf8), "child")
            try restored.deleteShelf(id)
            try restored.collectUnusedAssets()
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: restored.assetsDirectory.path).isEmpty)
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
