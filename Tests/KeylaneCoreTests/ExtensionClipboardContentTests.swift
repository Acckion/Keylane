import AppKit
import KeylaneCore
import XCTest

final class ExtensionClipboardContentTests: XCTestCase {
    func testRichCopyPublishesHTMLPlainTextAndConcealedMarker() throws {
        let board = NSPasteboard(name: .init("org.keylane.tests.clipboard.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let content = try JSONDecoder().decode(ExtensionClipboardContent.self, from: Data("""
            {"html":"<b>中文</b>","text":"中文"}
            """.utf8))
        XCTAssertTrue(content.write(to: board, concealed: true))
        XCTAssertEqual(board.string(forType: .html), "<b>中文</b>")
        XCTAssertEqual(board.string(forType: .string), "中文")
        XCTAssertTrue(board.types?.contains(.init("org.nspasteboard.ConcealedType")) == true)
        XCTAssertTrue(ClipboardPolicy.shouldSkip(types: board.types?.map(\.rawValue) ?? [],
                                                 source: nil, frontmost: nil, excluded: []))
    }

    func testFileReferenceAndRejectedContentKeepThePasteboardConsistent() throws {
        let board = NSPasteboard(name: .init("org.keylane.tests.clipboard.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let decoder = JSONDecoder()
        let fileContent = try decoder.decode(ExtensionClipboardContent.self, from: JSONEncoder().encode(["file": file.path]))
        XCTAssertTrue(fileContent.write(to: board))
        XCTAssertEqual(board.string(forType: .fileURL), file.standardizedFileURL.absoluteString)
        XCTAssertNil(board.string(forType: .string))

        let invalid = try decoder.decode(ExtensionClipboardContent.self, from: Data(#"{"file":"/tmp/../invalid","text":"mixed"}"#.utf8))
        XCTAssertFalse(invalid.write(to: board))
        XCTAssertFalse(ExtensionClipboardContent(text: String(repeating: "x", count: 4_097)).write(to: board))
        XCTAssertEqual(board.string(forType: .fileURL), file.standardizedFileURL.absoluteString)
    }
}
