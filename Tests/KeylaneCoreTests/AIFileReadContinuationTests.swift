import XCTest
import Darwin
import CoreGraphics
import CoreText
import PDFKit
@testable import KeylaneCore

final class AIFileReadContinuationTests: XCTestCase {
    private var root: URL!
    private var service: AIFileToolService!
    private var lease: AIFileAccessLease!
    private var session: AIFileToolService.ReadSession!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: AIFileToolService.systemPath(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("KeylaneReadPages-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        service = AIFileToolService(); lease = AIFileAccessLease(); session = .init()
    }
    override func tearDownWithError() throws { session = nil; service = nil; try FileManager.default.removeItem(at: root) }
    private func file(_ name: String, _ text: String) throws { try Data(text.utf8).write(to: root.appendingPathComponent(name)) }
    private func call(_ name: String, _ args: [String: AIToolValue], context: AIFileToolService.ReadSession? = nil) async throws -> [String: AIToolValue] {
        let context = context ?? session!
        let plan = try await service.prepare("keylane_" + name, arguments: args, scopes: [.init(path: root.path)], lease: lease, session: context)
        let result = try await service.execute(plan, lease: lease, cancellation: .init(), session: context)
        return try JSONDecoder().decode([String: AIToolValue].self, from: Data(result.text.utf8))
    }
    private func string(_ value: AIToolValue?) -> String { if case .string(let value) = value { return value }; return "" }
    private func rows(_ value: AIToolValue?) -> [[String: AIToolValue]] {
        guard case .array(let rows) = value else { return [] }
        return rows.compactMap { if case .object(let row) = $0 { return row }; return nil }
    }
    private func rejects(_ expected: AIFileToolError? = nil, _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected refused continuation", file: file, line: line) }
        catch { if let expected { XCTAssertEqual(error as? AIFileToolError, expected, file: file, line: line) } }
    }
    func testDatalessPolicyDoesNotRequestAnActualCloudDownload() {
        var info = stat()
        XCTAssertTrue(AIFileToolService.isLocallyMaterialized(info))
        info.st_flags = UInt32(SF_DATALESS)
        XCTAssertFalse(AIFileToolService.isLocallyMaterialized(info))
    }
    func testUTF8ContinuationMakesProgressAndCannotReplay() async throws {
        let text = String(repeating: "中文👋 hello\n", count: 30)
        try file("note", text)
        var page = try await call("read_file", ["path": .string("note"), "limit": .number(64)])
        let old = string(page["cursor"])
        var result = string(page["text"]), iterations = 0
        while case .string(let cursor) = page["cursor"] {
            page = try await call("read_result", ["cursor": .string(cursor), "limit": .number(64)])
            XCTAssertFalse(string(page["text"]).isEmpty)
            result += string(page["text"]); iterations += 1
            XCTAssertLessThan(iterations, 100)
        }
        XCTAssertEqual(result, text)
        await rejects(.stale) { _ = try await self.call("read_result", ["cursor": .string(old)]) }
    }
    func testContinuationCannotCrossSessionLeaseOrScope() async throws {
        try file("note", String(repeating: "private fixture ", count: 100))
        let first = try await call("read_file", ["path": .string("note"), "limit": .number(64)])
        let cursor = string(first["cursor"])
        await rejects(.stale) { _ = try await self.call("read_result", ["cursor": .string(cursor)], context: .init()) }
        await rejects(.stale) {
            _ = try await self.service.prepare("keylane_read_result", arguments: ["cursor": .string(cursor)], scopes: [], lease: self.lease, session: self.session)
        }
        let request = UUID(); try session.bind(to: request); try session.bind(to: request)
        XCTAssertThrowsError(try session.bind(to: UUID()))
        lease.revoke()
        await rejects { _ = try await self.call("read_result", ["cursor": .string(cursor)]) }
    }
    func testTextReplacementOrModificationInvalidatesContinuation() async throws {
        try file("note", String(repeating: "original ", count: 100))
        let first = try await call("read_file", ["path": .string("note"), "limit": .number(32)])
        try file("note", "replacement")
        await rejects(.stale) { _ = try await self.call("read_result", ["cursor": first["cursor"]!]) }
    }
    func testDirectorySnapshotDoesNotInsertNewFilesBetweenPages() async throws {
        for i in 0..<125 { try file(String(format: "%03d.txt", i), "fixture") }
        var page = try await call("read_file", ["path": .string("."), "limit": .number(50)])
        XCTAssertEqual(page["type"], .string("directory"))
        var paths = rows(page["entries"]).map { string($0["path"]) }
        try file("000-new.txt", "created after snapshot")
        while case .string(let cursor) = page["cursor"] {
            page = try await call("read_result", ["cursor": .string(cursor), "limit": .number(50)])
            paths += rows(page["entries"]).map { string($0["path"]) }
        }
        XCTAssertEqual(paths, (0..<125).map { String(format: "%03d.txt", $0) })
        XCTAssertFalse(String(describing: page).contains(root.path))
        XCTAssertEqual(page["truncated"], .bool(false))
    }
    func testChangedCachedEntryIsNotRedisclosed() async throws {
        try file("a", "first"); try file("b", "second")
        let first = try await call("read_file", ["path": .string("."), "limit": .number(1)])
        try file("b", "changed")
        await rejects(.stale) { _ = try await self.call("read_result", ["cursor": first["cursor"]!]) }
    }
    func testGlobAndGrepSnapshotsContinueBeyondFirstLimit() async throws {
        for i in 0..<9 { try file("file\(i).txt", "needle \(i)") }
        for operation in ["glob", "grep"] {
            var args: [String: AIToolValue] = ["path": .string("."), "pattern": .string("**/*.txt"), "limit": .number(2)]
            if operation == "grep" { args["query"] = .string("needle") }
            var page = try await call(operation, args)
            var paths = rows(page["matches"]).map { string($0["path"]) }
            while case .string(let cursor) = page["cursor"] {
                page = try await call("read_result", ["cursor": .string(cursor), "limit": .number(2)])
                paths += rows(page["matches"]).map { string($0["path"]) }
            }
            XCTAssertEqual(Set(paths).count, 9); XCTAssertEqual(paths.count, 9)
        }
    }
    func testLongCombiningGraphemeCannotStallAResultPage() async throws {
        try file("combining.txt", "needle a" + String(repeating: "\u{0301}", count: 30_000))
        let page = try await call("grep", ["path": .string("."), "pattern": .string("**/*"), "query": .string("needle"), "limit": .number(1)])
        XCTAssertEqual(rows(page["matches"]).count, 1)
        let match = try XCTUnwrap(rows(page["matches"]).first)
        XCTAssertLessThan(string(match["text"]).utf8.count, 2000)
        XCTAssertNil(page["cursor"])
    }
    func testOutstandingCursorsHaveABoundedBudget() async throws {
        try file("note", String(repeating: "fixture", count: 20))
        for _ in 0..<32 { _ = try await call("read_file", ["path": .string("note"), "limit": .number(4)]) }
        await rejects(.tooLarge) { _ = try await self.call("read_file", ["path": .string("note"), "limit": .number(4)]) }
    }
    func testPinnedParentChainsHaveASeparateDescriptorBudget() async throws {
        let relative = (0..<9).map { "d" + String($0) }.joined(separator: "/")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(relative), withIntermediateDirectories: true)
        try file(relative + "/note", String(repeating: "a", count: 100))
        var accepted = 0
        for _ in 0..<32 {
            do { _ = try await call("read_file", ["path": .string(relative + "/note"), "limit": .number(4)]); accepted += 1 }
            catch let error as AIFileToolError { XCTAssertEqual(error, .tooLarge); break }
        }
        XCTAssertGreaterThan(accepted, 0); XCTAssertLessThan(accepted, 32)
    }
    func testIndexedCandidatesAreRecheckedAndCannotEscapeRoot() async throws {
        try file("match.txt", "fixture"); try file(".env", "protected")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("match.txt"))
        let plan = try await service.prepare("keylane_search_indexed_files", arguments: ["path": .string("."), "query": .string("match")], scopes: [.init(path: root.path)], lease: lease, session: session)
        let result = try await service.execute(plan, lease: lease, cancellation: .init(), session: session,
            indexedPaths: [root.path + "/match.txt", URL(fileURLWithPath: root.path + "/match.txt").standardizedFileURL.path, root.path + "/.env", root.path + "/link", root.path + "/missing", "/outside/synthetic"])
        let object = try JSONDecoder().decode([String: AIToolValue].self, from: Data(result.text.utf8))
        XCTAssertEqual(rows(object["matches"]).map { string($0["path"]) }, ["match.txt"])
        XCTAssertFalse(result.text.contains(root.path))
    }
    func testPDFIsReadFromPinnedVersionAndCanStartAtPage() async throws {
        let pdf = Self.pdf([String(repeating: "First page text. ", count: 15), String(repeating: "Second page text. ", count: 15)])
        try pdf.write(to: root.appendingPathComponent("document.pdf"))
        var page = try await call("read_file", ["path": .string("document.pdf"), "page": .number(2), "limit": .number(80)])
        XCTAssertEqual(page["format"], .string("pdf")); XCTAssertEqual(page["page_count"], .number(2))
        var text = string(page["text"])
        while case .string(let cursor) = page["cursor"] {
            page = try await call("read_result", ["cursor": .string(cursor), "limit": .number(80)])
            text += string(page["text"])
        }
        XCTAssertTrue(text.contains("Second page")); XCTAssertFalse(text.contains("First page"))
        let first = try await call("read_file", ["path": .string("document.pdf"), "limit": .number(80)])
        try Self.pdf(["changed document"]).write(to: root.appendingPathComponent("document.pdf"))
        await rejects(.stale) { _ = try await self.call("read_result", ["cursor": first["cursor"]!]) }
    }
    func testSharedPDFParserRejectsLockedEmptyOversizedAndCancelledDocuments() throws {
        let data = Self.pdf(["First synthetic page", "Second synthetic page"])
        XCTAssertEqual(try AIFileDocumentText.pdfPages(data).count, 2)
        XCTAssertThrowsError(try AIFileDocumentText.pdfPages(data, maximumPages: 1))
        XCTAssertThrowsError(try AIFileDocumentText.pdfPages(data, maximumTextBytes: 4))
        XCTAssertThrowsError(try AIFileDocumentText.pdfPages(Self.pdf([""])))
        XCTAssertThrowsError(try AIFileDocumentText.pdfPages(Data("not a pdf".utf8)))
        let document = PDFDocument(data: data)!
        let locked = document.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "synthetic", PDFDocumentWriteOption.ownerPasswordOption: "synthetic"])!
        XCTAssertThrowsError(try AIFileDocumentText.pdfPages(locked))
        var checks = 0
        XCTAssertThrowsError(try AIFileDocumentText.pdfPages(data, check: { checks += 1; if checks >= 3 { throw CancellationError() } }))
    }
    private static func pdf(_ pages: [String]) -> Data {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        var rect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: consumer, mediaBox: &rect, nil)!
        for page in pages {
            context.beginPDFPage(nil)
            let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
            let string = NSAttributedString(string: page, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            context.textPosition = CGPoint(x: 36, y: 720)
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
            context.endPDFPage()
        }
        context.closePDF(); return data as Data
    }
}
