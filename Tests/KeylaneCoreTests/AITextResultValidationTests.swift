import XCTest
@testable import KeylaneCore

final class AITextResultValidationTests: XCTestCase {
    func testPreservesAllSupportedPlaceholderKindsAndCounts() throws {
        let source = "Hello {clipboard}, {cursor}, {datetime format=\"yyyy\"}, {argument name=\"语气\"}, {clipboard}"
        XCTAssertEqual(try AITextResultValidation.preservingPlaceholders(source: source, result: source.replacingOccurrences(of: "Hello", with: "你好")), source.replacingOccurrences(of: "Hello", with: "你好"))
        XCTAssertThrowsError(try AITextResultValidation.preservingPlaceholders(source: source, result: source.replacingOccurrences(of: "{clipboard}", with: "secret")))
        XCTAssertThrowsError(try AITextResultValidation.preservingPlaceholders(source: "{date format=\"yyyy\"}", result: "{date format=\"MM\"}"))
        XCTAssertThrowsError(try AITextResultValidation.preservingPlaceholders(source: "{uuid}", result: "{uuid} {uuid}"))
        XCTAssertThrowsError(try AITextResultValidation.preservingPlaceholders(source: "literal", result: "{clipboard}"))
    }
    func testPlaceholderValidationUsesTheTemplateLexerForQuotedBraces() throws {
        let source = #"Code: {argument name="code" default="{value}"}"#
        XCTAssertEqual(try AITextResultValidation.preservingPlaceholders(source: source, result: source), source)
        XCTAssertThrowsError(try AITextResultValidation.preservingPlaceholders(source: source, result: #"Code: {argument name="code" default="changed"}"#))
    }
    func testPlaceholderAttributesPreserveExactUnicodeBytes() {
        let source = "{argument name=\"é\"}"
        let changed = "{argument name=\"e\u{301}\"}"
        XCTAssertThrowsError(try AITextResultValidation.preservingPlaceholders(source: source, result: changed))
    }
    func testEmojiOnlyReturnsInstalledCatalogGlyphs() throws {
        XCTAssertEqual(try EmojiAIResult.glyphs("[\"😄\",\"not-installed\",\"😄\",\"β\"]", allowed: ["😄", "β"]), ["😄", "β"])
        XCTAssertThrowsError(try EmojiAIResult.glyphs("```json\n[\"😄\"]\n```", allowed: ["😄"]))
        XCTAssertThrowsError(try EmojiAIResult.glyphs("[\"unknown\"]", allowed: ["😄"]))
        XCTAssertThrowsError(try EmojiAIResult.glyphs("{\"emoji\":\"😄\"}", allowed: ["😄"]))
        XCTAssertThrowsError(try EmojiAIResult.glyphs(String(repeating: " ", count: 8_193), allowed: []))
    }
    func testEmojiBoundsAndNormalizedRoundTrip() throws {
        let values = (0..<25).map(String.init)
        let encoded = String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
        XCTAssertThrowsError(try EmojiAIResult.glyphs(encoded, allowed: Set(values)))
        let limited = String(decoding: try JSONEncoder().encode(Array(values.prefix(20))), as: UTF8.self)
        XCTAssertEqual(try EmojiAIResult.glyphs(limited, allowed: Set(values)).count, 12)
        XCTAssertEqual(try EmojiAIResult.glyphs(EmojiAIResult.normalized("[\"😄\",\"😄\"]", allowed: ["😄"]), allowed: ["😄"]), ["😄"])
    }
}
