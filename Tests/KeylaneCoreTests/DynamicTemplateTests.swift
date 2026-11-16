import Foundation
import XCTest
@testable import KeylaneCore

final class DynamicTemplateTests: XCTestCase {
    func testSnippetPlaceholdersAndFormatting() throws {
        var context = DynamicTemplate.Context()
        context.now = Date(timeIntervalSince1970: 1_704_067_200)
        context.calendar = Calendar(identifier: .gregorian)
        context.calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        context.locale = Locale(identifier: "en-US")
        context.clipboard = { $0 == 1 ? " old " : nil }
        context.snippet = { $0 == "Greeting" ? "Hi {argument name=recipient}" : nil }
        let template = DynamicTemplate(#"😀{cursor}{date format="yyyy-MM-dd" offset="+1M -2d"} {day locale=en-US} {clipboard offset=1 | trim | uppercase} {calculator expression="2 + 3 * 4"} {snippet name="Greeting"}"#)
        let plan = try template.plan(context: context)
        XCTAssertEqual(plan.arguments.map(\.id), ["recipient"])
        let rendered = try plan.resolve(["recipient": "世界"])
        XCTAssertEqual(rendered.text, "😀2024-01-30 Monday OLD 14 Hi 世界")
        XCTAssertEqual(rendered.cursorOffset, 2)
        let uuid = try DynamicTemplate("{uuid}").plan().resolve().text
        XCTAssertNotNil(UUID(uuidString: uuid))
        XCTAssertFalse(try DynamicTemplate("{time} {datetime}").plan(context: context).resolve().text.contains("{"))
    }

    func testArgumentsHaveSharedValuesAndOptions() throws {
        let template = DynamicTemplate(#"{argument name=tone} {argument name=tone options="happy, sad" default=happy} {argument}"#)
        let plan = try template.plan()
        XCTAssertEqual(plan.arguments.count, 2)
        let input = try XCTUnwrap(plan.arguments.last?.id)
        XCTAssertEqual(try plan.resolve([input: "X"]).text, "happy happy X")
        XCTAssertThrowsError(try plan.resolve([input: "X", "tone": "unknown"]))
        XCTAssertThrowsError(try DynamicTemplate("{argument}{argument}{argument}{argument}").plan())
        XCTAssertThrowsError(try DynamicTemplate("{cursor}{cursor}").plan())
        XCTAssertEqual(try DynamicTemplate("{calculator}").plan().arguments.first?.title, "计算表达式")
    }

    func testAIContextAndQuicklinkEscaping() throws {
        var context = DynamicTemplate.Context()
        context.clipboard = { _ in "a/b" }
        context.selection = { "selected / text" }
        context.browserTab = { format, selector in
            XCTAssertEqual(format, .html)
            XCTAssertEqual(selector, "div[data-thing='a|b']")
            return "<div>Content</div>"
        }
        let ai = DynamicTemplate(#"{selection | uppercase} {browser-tab format=html selector="div[data-thing='a|b']" | raw} {clipboard | json-stringify | raw}"#, usage: .aiCommand)
        XCTAssertEqual(try ai.plan(context: context).resolve().text, #""""SELECTED / TEXT""" <div>Content</div> "a/b""#)

        let quicklink = try QuicklinkTemplate("https://example.com/?q={selection}&path={clipboard | raw}&value={clipboard | percent-encode}",
                                              context: context)
        XCTAssertEqual(try quicklink.url().absoluteString,
                       "https://example.com/?q=selected%20%2F%20text&path=a/b&value=a%2Fb")
        let legacy = try QuicklinkTemplate("https://example.com/{date}/{a}/{b}/{c}", legacy: true)
        XCTAssertEqual(legacy.parameters.map(\.id), ["date", "a", "b", "c"])
        XCTAssertThrowsError(try QuicklinkTemplate("https://example.com/?q={browser-tab}"))
        XCTAssertEqual(try QuicklinkTemplate("https://example.com/{browser-tab}", legacy: true).parameters.map(\.id),
                       ["browser-tab"])
    }

    func testInvalidTokensStayLiteralAndNestedReferencesFail() throws {
        let source = #"{unknown} {date format="yyyy" locale=en-US} {date offset="+ 2d"} {clipboard | not-a-modifier}"#
        XCTAssertEqual(try DynamicTemplate(source).plan().resolve().text, source)
        var context = DynamicTemplate.Context()
        context.snippet = { _ in "{snippet name=Recursive}" }
        XCTAssertThrowsError(try DynamicTemplate("{snippet name=Recursive}").plan(context: context))
        XCTAssertThrowsError(try DynamicTemplate("{browser-tab}", usage: .aiCommand).plan().resolve())
    }

    func testCompletionUsesUTF16AndReplacesExistingBraces() {
        let source = "😀today {date}"
        let range = DynamicTemplate.completion(in: source, caret: 11)
        XCTAssertEqual(range?.prefix, "da")
        if let range { XCTAssertEqual((source as NSString).substring(with: range.range), "{date}") }
        XCTAssertNotNil(DynamicTemplate.completion(in: "today {}", caret: 7))
        XCTAssertNil(DynamicTemplate.completion(in: "today {date}", caret: 12))
    }
}
