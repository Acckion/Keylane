import Foundation
import XCTest
import KeylaneCore

final class ApplicationLeftoversTests: XCTestCase {
    func testOnlyDirectBundleIdentifierMatchesAreOffered() throws {
        try withLibrary { library in
            let cache = try fixture("Caches/org.example.editor", in: library)
            let preferences = try fixture("Preferences/org.example.editor.plist", in: library)
            try fixture("Caches/org.example.editor-helper", in: library)
            try fixture("Application Support/Editor", in: library)
            try fixture("Preferences/ByHost/org.example.editor.plist", in: library)
            try fixture("Group Containers/group.org.example.editor", in: library)
            try fixture("LaunchAgents/org.example.editor.plist", in: library)

            let results = ApplicationLeftovers.find(bundleIdentifier: "org.example.editor", in: library)
            XCTAssertEqual(results.map { $0.url.path }, [cache.path, preferences.path])
            for id in ["", "..", "org.example/../editor", "org.example..editor"] {
                XCTAssertTrue(ApplicationLeftovers.find(bundleIdentifier: id, in: library).isEmpty)
            }
        }
    }

    func testRedirectedPathsAndReplacementsCannotBeCleared() throws {
        try withLibrary { library in
            let files = FileManager.default
            let seed = try fixture("Preferences/org.example.editor.plist", in: library)
            let target = try fixture("Outside/org.example.editor", in: library.deletingLastPathComponent())
            let caches = library.appendingPathComponent("Caches")
            try files.createSymbolicLink(at: caches, withDestinationURL: target.deletingLastPathComponent())
            let leafAlias = library.appendingPathComponent("Preferences/org.example.alias.plist")
            try files.createSymbolicLink(at: leafAlias, withDestinationURL: seed)

            XCTAssertTrue(ApplicationLeftovers.find(bundleIdentifier: "org.example.alias", in: library).isEmpty)
            let items = ApplicationLeftovers.find(bundleIdentifier: "org.example.editor", in: library)
            XCTAssertEqual(items.map { $0.url.path }, [seed.path])
            let selected = try XCTUnwrap(items.first)

            try files.moveItem(at: seed, to: seed.appendingPathExtension("old"))
            try Data("replacement".utf8).write(to: seed)
            XCTAssertThrowsError(try ApplicationLeftovers.trash(selected))
            XCTAssertEqual(try String(contentsOf: seed, encoding: .utf8), "replacement")
            XCTAssertTrue(files.fileExists(atPath: target.path))

            let alias = library.deletingLastPathComponent().appendingPathComponent("RedirectedLibrary")
            try files.createSymbolicLink(at: alias, withDestinationURL: library)
            XCTAssertTrue(ApplicationLeftovers.find(bundleIdentifier: "org.example.editor", in: alias).isEmpty)
        }
    }

    private func withLibrary(_ verify: (URL) throws -> Void) throws {
        let files = FileManager.default
        let temp = try XCTUnwrap(FileSearchLocation.canonicalPath(files.temporaryDirectory.path))
        let home = URL(fileURLWithPath: temp).appendingPathComponent(UUID().uuidString)
        let library = home.appendingPathComponent("Library", isDirectory: true)
        try files.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: home) }
        try verify(library)
    }

    @discardableResult
    private func fixture(_ path: String, in library: URL) throws -> URL {
        let url = library.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        return url
    }
}
