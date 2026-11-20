import Foundation
import KeylaneCore
import XCTest

final class AISSEEventDecoderTests: XCTestCase {
    func testMultilineEventsAndAllLineEndingsPreserveUTF8() throws {
        for newline in ["\n", "\r", "\r\n"] {
            var parser = AISSEEventDecoder()
            let input = ": keepalive" + newline + "event: message" + newline + "data: {" + newline +
                "data: \"text\":\"合成😀\"}" + newline + newline + "data: [DONE]" + newline + newline
            let events = try Data(input.utf8).compactMap { try parser.consume($0) }
            XCTAssertEqual(events.count, 2)
            let object = try JSONSerialization.jsonObject(with: events[0]) as? [String: String]
            XCTAssertEqual(object?["text"], "合成😀")
            XCTAssertEqual(events[1], Data("[DONE]".utf8))
            XCTAssertFalse(parser.hasPendingData)
        }
    }
    func testPartialEventCannotBeDecodedEarly() throws {
        var parser = AISSEEventDecoder()
        for byte in Data("data: {\"text\":\"partial\"}\n".utf8) { XCTAssertNil(try parser.consume(byte)) }
        XCTAssertTrue(parser.hasPendingData)
        XCTAssertNotNil(try parser.consume(10))
        XCTAssertFalse(parser.hasPendingData)
    }
    func testEventBudgetIncludesAllDataLines() throws {
        var parser = AISSEEventDecoder()
        let line = Data(("data: " + String(repeating: "x", count: 65_536) + "\n").utf8)
        for _ in 0..<3 { for byte in line { _ = try parser.consume(byte) } }
        XCTAssertThrowsError(try line.forEach { _ = try parser.consume($0) })
    }
}
