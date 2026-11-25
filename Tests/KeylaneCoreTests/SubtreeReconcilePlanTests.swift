import XCTest
import SQLite3
@testable import KeylaneCore
final class SubtreeReconcilePlanTests: XCTestCase {
    func testMissingOrTinySubtreeCostDoesNotGrowWithUnrelatedRootRows() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("index.sqlite")
        let db = try FileSearchIndex(url: url)
        func populate(_ start: Int, _ end: Int) throws {
            try db.transaction {
                for i in start..<end {
                    try db.put(.init(path: "/fixture/unrelated-\(i).txt", name: "unrelated-\(i).txt", volume: "/", modified: 1, directory: false, symlink: false), root: "/fixture", epoch: "old")
                }
            }
        }
        func steps(_ subtree: String) throws -> UInt64 {
            let previous = db.writeDiagnostics.subtreeReconcileSteps
            try db.removeUnseen(root: "/fixture", subtree: subtree, epoch: "new")
            return db.writeDiagnostics.subtreeReconcileSteps - previous
        }
        func reconcileTinySubtree(expectedRemaining: Int) throws -> UInt64 {
            try db.put(.init(path: "/fixture/tiny/a", name: "a", volume: "/", modified: 1, directory: false, symlink: false), root: "/fixture", epoch: "old")
            let cost = try steps("/fixture/tiny")
            XCTAssertEqual(try db.stats().entries, expectedRemaining, "Only the stale subtree entry should be deleted")
            return cost
        }
        try populate(0,100)
        let small = try steps("/fixture/absent")
        let smallTiny = try reconcileTinySubtree(expectedRemaining: 100)
        try populate(100,10_000)
        let large = try steps("/fixture/absent")
        let largeTiny = try reconcileTinySubtree(expectedRemaining: 10_000)
        // Different bundled SQLite versions emit different fixed opcode counts.
        // Neither shape should gain work in proportion to the number of siblings.
        XCTAssertLessThanOrEqual(large, small + 20, "Missing subtree must not traverse the unrelated root")
        XCTAssertLessThanOrEqual(largeTiny, smallTiny + 20, "Tiny subtree must not traverse the unrelated root")
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path,&raw),SQLITE_OK)
        defer { sqlite3_close(raw) }
        var q: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(raw,"EXPLAIN QUERY PLAN " + FileSearchIndex.subtreeReconcileSQL,-1,&q,nil),SQLITE_OK)
        defer { sqlite3_finalize(q) }
        var details: [String] = []
        while sqlite3_step(q) == SQLITE_ROW { details.append(String(cString:sqlite3_column_text(q,3))) }
        XCTAssertGreaterThanOrEqual(details.filter { $0.contains("INTEGER PRIMARY KEY") }.count,2)
        XCTAssertFalse(details.contains { $0.contains("files_name_search") || $0.contains("files_root") })
    }
}
