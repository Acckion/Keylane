import XCTest
@testable import KeylaneCore

final class ThemeTests: XCTestCase {
    func testHexCanonicalizationAndAlpha() throws {
        XCTAssertEqual(try ThemeRGBA(" #AbC ").hex, "#AABBCC")
        XCTAssertEqual(try ThemeRGBA("abcd").hex, "#AABBCCDD")
        XCTAssertEqual(try ThemeRGBA("#aabbccff").hex, "#AABBCC")
        XCTAssertEqual(try ThemeRGBA("00000000").alpha, 0)
        for value in ["", "#12", "#12345", "##123456", "red", "１２３４５６", "#12GG34"] {
            XCTAssertThrowsError(try ThemeRGBA(value), value)
        }
    }
    func testPaletteValidationRejectsIncompleteAndUnsafeValues() throws {
        for theme in ThemeDefinition.builtins { XCTAssertNoThrow(try theme.validated()) }
        var theme = ThemeDefinition.builtins[2].duplicate()
        theme.name = "  自定义主题  "
        XCTAssertEqual(try theme.validated().name, "自定义主题")
        theme.background.angle = .nan
        XCTAssertThrowsError(try theme.validated())
        theme.background.angle = 361
        XCTAssertThrowsError(try theme.validated())
        theme.background.angle = 90
        theme.colors["unexpected"] = "#000"
        XCTAssertThrowsError(try theme.validated())
        theme.colors["unexpected"] = nil
        theme.colors["text"] = nil
        XCTAssertThrowsError(try theme.validated())
        // In-progress editor text still renders safely until validation on Save.
        XCTAssertEqual(theme.color(.text).hex, "#F4F4F5")
        theme.colors["text"] = "#FFF"
        theme.name = "\n"
        XCTAssertThrowsError(try theme.validated())
        theme.name = String(repeating: "a", count: 81)
        XCTAssertThrowsError(try theme.validated())
    }
    func testIndependentAssignmentsRenameModeChangeAndDelete() throws {
        var library = ThemeLibrary()
        var dark = ThemeDefinition.builtins[2].duplicate()
        let light = ThemeDefinition.builtins[4].duplicate()
        try library.save(dark); try library.save(light)
        try library.assign(dark.id); try library.assign(light.id)
        XCTAssertEqual(library.theme(for: .dark).id, dark.id)
        XCTAssertEqual(library.theme(for: .light).id, light.id)
        dark.name = "改名"; try library.save(dark)
        XCTAssertEqual(library.theme(for: .dark).name, "改名")
        dark.appearance = .light; try library.save(dark)
        XCTAssertEqual(library.darkID, ThemeDefinition.darkID)
        XCTAssertEqual(library.lightID, light.id)
        try library.remove(light.id)
        XCTAssertEqual(library.lightID, ThemeDefinition.lightID)
        XCTAssertThrowsError(try library.save(ThemeDefinition.builtins[0]))
        XCTAssertThrowsError(try library.remove(ThemeDefinition.darkID))
        XCTAssertThrowsError(try library.assign(UUID()))
    }
    func testLibraryRejectsDuplicateAndReservedIDsAndRepairsMissingAssignments() throws {
        var library = ThemeLibrary()
        let custom = ThemeDefinition.builtins[2].duplicate()
        library.custom = [custom, custom]
        XCTAssertThrowsError(try library.validated())
        library.custom = [ThemeDefinition.builtins[2]]
        XCTAssertThrowsError(try library.validated())
        library.custom = [custom]; library.lightID = custom.id; library.darkID = UUID()
        let repaired = try library.validated()
        XCTAssertEqual(repaired.lightID, ThemeDefinition.lightID)
        XCTAssertEqual(repaired.darkID, ThemeDefinition.darkID)
        library.custom = (0..<100).map { _ in custom.duplicate() }
        XCTAssertThrowsError(try library.save(custom.duplicate()))
    }
    func testArchiveRoundTripNeverOverwritesExistingTheme() throws {
        let original = ThemeDefinition.builtins[2]
        let bytes = try ThemeArchive.data(original)
        let imported = try ThemeArchive.decode(bytes)
        XCTAssertNotEqual(imported.id, original.id)
        XCTAssertFalse(imported.isBuiltin)
        XCTAssertEqual(imported.background, original.background)
        XCTAssertEqual(imported.colors, original.colors)
        XCTAssertEqual(imported.name, original.name)
        let link = try ThemeArchive.url(imported)
        let linked = try ThemeArchive.decode(link.absoluteString)
        XCTAssertNotEqual(linked.id, imported.id)
        XCTAssertEqual(linked.colors, imported.colors)
        XCTAssertEqual(try ThemeArchive.decode(String(decoding: bytes, as: UTF8.self)).name, original.name)
    }
    func testUntrustedArchivesAreBoundedAndLinksAreStrict() throws {
        let bytes = try ThemeArchive.data(ThemeDefinition.builtins[0])
        let base64 = bytes.base64EncodedString()
        for text in ["keylane://other?data=\(base64)", "keylane://theme/extra?data=\(base64)",
                     "keylane://theme?data=\(base64)&extra=1", "keylane://theme?data=\(base64)#fragment",
                     "https://example.test/theme.json", "keylane://theme?data=bad", String(repeating: "a", count: 128_001)] {
            XCTAssertThrowsError(try ThemeArchive.decode(text))
        }
        XCTAssertThrowsError(try ThemeArchive.decode(Data(repeating: 0, count: ThemeArchive.maximumBytes + 1)))
        let newer = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")
        XCTAssertThrowsError(try ThemeArchive.decode(newer))
    }
}
