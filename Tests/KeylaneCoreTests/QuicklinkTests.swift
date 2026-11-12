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
