import Foundation
import XCTest
import KeylaneCore

final class QuicklinkTests: XCTestCase {
    func testAcceptsClipboardEmailAsQuicklink() throws {
        let address = try XCTUnwrap(ClipboardCategory.emailURL(in: "  design?test+work@example.com  "))
        XCTAssertEqual(try QuicklinkTemplate(address.absoluteString).url(), address)
        XCTAssertNil(URLComponents(url: address, resolvingAgainstBaseURL: false)?.query)
        XCTAssertThrowsError(try QuicklinkTemplate("mailto:design@example.com?body=Test"))
        XCTAssertThrowsError(try QuicklinkTemplate("mailto:invalid"))
    }

    func testEncodesParametersAndAppliesDefaults() throws {
        let template = try QuicklinkTemplate("https://example.com/{名称}?q={搜索=默认}&again={名称}")
        XCTAssertEqual(template.parameters.map(\.id), ["名称", "搜索"])
        let url = try template.url(values: ["名称": "中文 /?&=#%+"])
        XCTAssertEqual(url.absoluteString,
                       "https://example.com/%E4%B8%AD%E6%96%87%20%2F%3F%26%3D%23%25%2B?q=%E9%BB%98%E8%AE%A4&again=%E4%B8%AD%E6%96%87%20%2F%3F%26%3D%23%25%2B")
        XCTAssertThrowsError(try template.url()) {
            XCTAssertEqual($0 as? QuicklinkTemplate.ValidationError, .missingValue("名称"))
        }
    }

    func testRejectsUnsafeOrMalformedTemplates() {
        for value in ["file:///tmp", "https://{host}/", "https://user:secret@example.com",
                      "https://example.com/{}", "https://example.com/{a", "https://example.com/{a={b}}",
                      "https://example.com/{q=one}/{q=two}"] {
            XCTAssertThrowsError(try QuicklinkTemplate(value), value)
        }
    }

    func testLegacyFourParameterQuicklinkCanBeRenamedSavedAndResolved() throws {
        let suite = "Keylane.QuicklinksTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stored = Data(#"{"links":[{"id":"quicklink:legacy","title":"旧链接","template":"https://example.com/{a}/{b}/{c}/{d}"}]}"#.utf8)
        defaults.set(stored, forKey: QuicklinkLibrary.storageKey)
        let original = try XCTUnwrap(QuicklinkLibrary.load(from: defaults).links.first)

        var draft = original.preparedForEditing()
        draft.title = "新标题"
        XCTAssertNoThrow(try draft.parsedTemplate())
        try QuicklinkLibrary(links: [draft]).save(to: defaults)

        let saved = try XCTUnwrap(QuicklinkLibrary.load(from: defaults).links.first)
        XCTAssertEqual(saved.title, "新标题")
        XCTAssertEqual(saved.id, original.id)
        XCTAssertEqual(saved.template, original.template)
        XCTAssertNil(saved.usesDynamicPlaceholders)
        let template = try saved.parsedTemplate()
        XCTAssertEqual(template.parameters.map(\.id), ["a", "b", "c", "d"])
        let url = try template.url(values: ["a": "one", "b": "two", "c": "three", "d": "four/five"])
        XCTAssertEqual(url.absoluteString, "https://example.com/one/two/three/four%2Ffive")
    }

    func testLegacyDraftMigratesWithinDynamicArgumentLimit() throws {
        let stored = Data(#"{"id":"quicklink:legacy","title":"旧链接","template":"https://example.com/{date}/{q=旧值}"}"#.utf8)
        let draft = try JSONDecoder().decode(Quicklink.self, from: stored).preparedForEditing()
        XCTAssertEqual(draft.usesDynamicPlaceholders, true)
        XCTAssertEqual(draft.template, #"https://example.com/{argument name="date"}/{argument name="q" default="旧值"}"#)
        let template = try draft.parsedTemplate()
        XCTAssertEqual(template.parameters.map(\.id), ["date", "q"])
        XCTAssertEqual(try template.url(values: ["date": "explicit"]).absoluteString,
                       "https://example.com/explicit/%E6%97%A7%E5%80%BC")

        let newLink = Quicklink(title: "新链接", template: "https://example.com/{argument}/{argument}/{argument}/{argument}")
        XCTAssertThrowsError(try newLink.preparedForEditing().parsedTemplate()) {
            XCTAssertEqual($0 as? DynamicTemplate.Failure, .tooManyArguments)
        }
    }

    func testMigrationPreservesOriginalAndDoesNotRecreateDeletedLink() throws {
        let suite = "Keylane.QuicklinksTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = "https://example.com/?q={old}"
        defaults.set(original, forKey: QuicklinkLibrary.legacyKey)
        let migrated = try QuicklinkLibrary.load(from: defaults)
        XCTAssertEqual(migrated.links.map(\.id), [QuicklinkLibrary.legacyID])
        XCTAssertEqual(migrated.links.first?.template, "https://example.com/?q=%7Bold%7D")
        XCTAssertEqual(defaults.string(forKey: QuicklinkLibrary.legacyKey), original)
        XCTAssertEqual(try QuicklinkLibrary.load(from: defaults), migrated)

        let empty = QuicklinkLibrary(links: [])
        try empty.save(to: defaults)
        XCTAssertEqual(try QuicklinkLibrary.load(from: defaults), empty)
        defaults.set(Data([0]), forKey: QuicklinkLibrary.storageKey)
        XCTAssertThrowsError(try QuicklinkLibrary.load(from: defaults))
        XCTAssertEqual(defaults.data(forKey: QuicklinkLibrary.storageKey), Data([0]))
    }
}
