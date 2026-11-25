import Foundation
import XCTest
@testable import KeylaneCore

final class RaycastStoreSnapshotTests: XCTestCase {
    private let revision = String(repeating: "a", count: 40)
    private let tree = String(repeating: "b", count: 40)
    private let helloBlob = "ce013625030ba8dba906f756967f9e9ca394464a"

    private func entry(_ path: String, mode: String = "100644", type: String = "blob",
                       sha: String? = nil, size: Int? = 6) -> [String: Any] {
        var result: [String: Any] = ["path": path, "mode": mode, "type": type, "sha": sha ?? helloBlob]
        if let size { result["size"] = size }
        return result
    }

    private func snapshot(_ entries: [[String: Any]], truncated: Bool = false,
                          reportedSHA: String? = nil) throws -> RaycastStoreSnapshot {
        let index = RaycastPublicCatalog.Index(revision: revision, slugs: ["new-extension"])
        let data = try JSONSerialization.data(withJSONObject: [
            "sha": reportedSHA ?? tree, "truncated": truncated, "tree": entries
        ])
        return try RaycastStoreSnapshot(source: .init(slug: "new-extension", catalog: index),
                                        treeSHA: tree, recursiveTreeJSON: data)
    }

    func testManifestAndContentIntegrity() throws {
        let result = try snapshot([entry("src/main.ts"), entry("src", mode: "040000", type: "tree", size: nil),
                                   entry("package.json")])
        XCTAssertEqual(result.source.revision, revision)
        XCTAssertEqual(result.files.map(\.path), ["package.json", "src/main.ts"])
        XCTAssertEqual(result.totalBytes, 12)
        let file = try XCTUnwrap(result.files.first)
        XCTAssertTrue(file.verifies(Data("hello\n".utf8)))
        XCTAssertFalse(file.verifies(Data("HELLO\n".utf8)))
        XCTAssertFalse(file.verifies(Data("hello".utf8)))
    }

    func testFailClosedForIncompleteOrMismatchedTree() {
        XCTAssertThrowsError(try snapshot([entry("package.json")], truncated: true)) {
            XCTAssertEqual($0 as? RaycastStoreSnapshot.Failure, .incompleteTree)
        }
        XCTAssertThrowsError(try snapshot([entry("package.json")], reportedSHA: revision)) {
            XCTAssertEqual($0 as? RaycastStoreSnapshot.Failure, .wrongTree)
        }
        XCTAssertThrowsError(try snapshot([])) {
            XCTAssertEqual($0 as? RaycastStoreSnapshot.Failure, .missingManifest)
        }
    }

    func testRejectsNonregularFilesAndUnsafeNames() {
        for candidate in [entry("link", mode: "120000"), entry("submodule", mode: "160000", type: "commit"),
                          entry("../escape"), entry("/absolute"), entry("folder//file"), entry(".GiT/config"),
                          entry("drive:file"), entry("folder\\file"), entry("control\nname")] {
            XCTAssertThrowsError(try snapshot([entry("package.json"), candidate]))
        }
    }

    func testRejectsFilesystemCollisionsAndNonDirectoryParents() {
        for entries in [
            [entry("PACKAGE.json")],
            [entry("café"), entry("cafe\u{0301}")],
            [entry("ancestor"), entry("ancestor/file")],
            [entry("parent", mode: "040000", type: "tree", size: nil), entry("PARENT/file")],
            [entry("missing/file")]
        ] {
            XCTAssertThrowsError(try snapshot([entry("package.json")] + entries)) {
                XCTAssertEqual($0 as? RaycastStoreSnapshot.Failure, .pathCollision(entries.last?["path"] as? String ?? ""))
            }
        }
    }

    func testRejectsPerFileAndAggregateLimitsAndMalformedObjects() {
        XCTAssertThrowsError(try snapshot([entry("package.json", size: 1_048_577)]))
        XCTAssertThrowsError(try snapshot([entry("package.json"), entry("bad", size: -1)]))
        XCTAssertThrowsError(try snapshot([entry("package.json"), entry("bad", sha: "invalid")]))
        XCTAssertThrowsError(try snapshot([entry("package.json")] + (0..<4).map { entry("asset-\($0)", size: 8 * 1024 * 1024) })) {
            XCTAssertEqual($0 as? RaycastStoreSnapshot.Failure, .oversizedSnapshot)
        }
        XCTAssertThrowsError(try snapshot([entry("package.json")] + (0..<2048).map { entry("f\($0)", size: 0) })) {
            XCTAssertEqual($0 as? RaycastStoreSnapshot.Failure, .oversizedInventory)
        }
    }
}
