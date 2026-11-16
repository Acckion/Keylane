import XCTest
@testable import KeylaneCore
final class ApplicationIdentityTests: XCTestCase {
    func testSystemSettingsInMultipleLanguagesAndEnglishAlias() throws {
        let url = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("System Settings fixture not installed") }
        for (language, expected, query) in [("zh-Hans-CN", "系统设置", "系统设置"), ("fr", "Réglages\u{00A0}Système", "Reglages Systeme"), ("de", "System\u{00AD}einstellungen", "Systemeinstellungen")] {
            let identity = ApplicationIdentity(url: url, preferredLanguages: [language])
            // Apple's localized labels vary in spacing/hyphenation between OS releases.
            // Assert the translated words; the app should preserve the system's original label.
            func labelWords(_ value: String) -> String {
                value.replacingOccurrences(of: "\u{00AD}", with: "")
                    .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            }
            XCTAssertEqual(labelWords(identity.displayName), labelWords(expected), language)
            XCTAssertNotNil(identity.score(query: query), language)
            XCTAssertNotNil(identity.score(query: "System Settings"), language)
        }
        XCTAssertNotNil(ApplicationIdentity(url: url, preferredLanguages: ["zh-Hans"]).score(query: "xitongshezhi"))
    }
    func testMissingLocalizationFallsBackWithoutInventedTranslation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Example.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String:Any] = ["CFBundleIdentifier":"org.keylane.identity-test", "CFBundleName":"Example", "CFBundleDisplayName":"Example", "CFBundlePackageType":"APPL", "CFBundleAlternateNames":["HistoricalName"], "MDItemKeywords":["BundleKeyword"]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let identity = ApplicationIdentity(url: contents.deletingLastPathComponent(), preferredLanguages: ["zh-Hans"])
        XCTAssertEqual(identity.displayName,"Example")
        XCTAssertNotNil(identity.score(query: "Example"))
        XCTAssertNotNil(identity.score(query: "HistoricalName"))
        XCTAssertNotNil(identity.score(query: "BundleKeyword"))
    }

    func testScanResolvesFinderAliasDeduplicatesAndHonorsCustomDepth() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let targets = root.appendingPathComponent("Targets")
        let scope = root.appendingPathComponent("Scope")
        let app = targets.appendingPathComponent("Fixture.app")
        let deep = scope.appendingPathComponent("One/Two/Three/Deep.app")
        for bundle in [app, deep] {
            let contents = bundle.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": "org.keylane.discovery." + bundle.deletingPathExtension().lastPathComponent,
                        "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
        }
        let alias = scope.appendingPathComponent("Finder Alias")
        let bookmark = try app.bookmarkData(options: .suitableForBookmarkFile)
        try URL.writeBookmarkData(bookmark, to: alias)
        try FileManager.default.createSymbolicLink(at: scope.appendingPathComponent("Symbolic Link.app"), withDestinationURL: app)
        let canonical = app.resolvingSymlinksInPath().path
        XCTAssertEqual(ApplicationCatalog.scan(roots: [scope.path], excluded: [], customDepth: 3).map(\.id), [canonical])
        XCTAssertEqual(Set(ApplicationCatalog.scan(roots: [scope.path], excluded: []).map(\.id)),
                       [canonical, deep.resolvingSymlinksInPath().path])
        try FileManager.default.removeItem(at: scope.appendingPathComponent("Symbolic Link.app"))
        XCTAssertEqual(ApplicationCatalog.scan(roots: [scope.path], excluded: [], customDepth: 3).map(\.id), [canonical])
        XCTAssertTrue(ApplicationCatalog.scan(roots: [scope.path], excluded: [canonical], customDepth: 3).isEmpty)
    }
}
