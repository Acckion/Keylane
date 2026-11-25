import XCTest
@testable import KeylaneCore

final class FileSearchMergeTests: XCTestCase {
    private func hit(_ id: Int, score: Int, body: Bool = false) -> RankedFile {
        .init(file: .init(url: URL(fileURLWithPath: "/fixture/\(id).txt"), name: "file-\(id)", modified: Date(timeIntervalSince1970: Double(id % 11)), matchesContent: body), score: score)
    }
    func testSortedMergeMatchesLegacyFilterDedupAndSort() throws {
        for seed in 0..<20 {
            let local = (0..<100).map { hit($0, score: ($0 * 37 + seed) % 100, body: true) }.sorted { $0.precedes($1) }
            let system = (50..<300).map { hit($0, score: ($0 * 17 + seed) % 150) }.sorted { $0.precedes($1) }
            func shared(_ h: RankedFile) -> Bool { !h.file.id.hasSuffix("7.txt") }
            func systemAllowed(_ h: RankedFile) -> Bool { shared(h) && !h.file.id.hasSuffix("3.txt") }
            var seen = Set<String>()
            let legacy = Array((local + system.filter(systemAllowed)).filter { shared($0) && seen.insert($0.file.id).inserted }.sorted { $0.precedes($1) }.prefix(30))
            let result = try XCTUnwrap(FileSearchMerge.top(local: local, system: system, limit: 30, acceptsLocal: shared, acceptsSystem: systemAllowed))
            XCTAssertEqual(result.map(\.file), legacy.map(\.file))
            XCTAssertEqual(result.map(\.score), legacy.map(\.score))
        }
    }
    func testValidatesOnlySystemRowsNeededForVisibleResultsAndCancels() throws {
        let local = (0..<200).map { hit($0, score: 1000 - $0) }
        let system = (200..<400).map { hit($0, score: 500 - $0) }
        var checks = 0
        let result = try XCTUnwrap(FileSearchMerge.top(local: local, system: system, acceptsLocal: { _ in true }, acceptsSystem: { _ in checks += 1; return true }))
        XCTAssertEqual(result.count, 200)
        XCTAssertEqual(checks, 0, "Low-ranked system rows need no filesystem inspection")
        XCTAssertNil(FileSearchMerge.top(local: local, system: system, acceptsLocal: { _ in true }, acceptsSystem: { _ in true }, isCancelled: { true }))
    }
    func testSpotlightRankingStopsObsoleteWorkDuringScoring() {
        let files = (0..<500).map { hit($0, score: 0).file }
        var checks = 0
        let result = RankedFile.top(files, query: "file", isCancelled: { checks += 1; return checks > 5 })
        XCTAssertTrue(result.isEmpty)
        XCTAssertLessThan(checks, 10)
    }

}
