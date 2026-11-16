import Foundation
import XCTest
@testable import KeylaneCore

final class GitHubUpdateReleaseTests: XCTestCase {
    private func release(_ tag: String, prerelease: Bool = false, draft: Bool = false,
                         complete: Bool = true) throws -> GitHubUpdateRelease {
        let version = String(tag.dropFirst().prefix { $0 != "-" })
        let image = "Keylane-\(version)-macos-arm64.dmg"
        let names = complete ? [image, image + ".sha256"] : [image]
        let json: [String: Any] = [
            "tag_name": tag, "draft": draft, "prerelease": prerelease,
            "assets": names.map { ["name": $0, "state": "uploaded"] },
        ]
        return try JSONDecoder().decode(GitHubUpdateRelease.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testChannelAndNumericOrdering() throws {
        let releases = try [
            release("v1.0.1"), release("v1.0.2-alpha.9", prerelease: true),
            release("v1.0.2-alpha.10", prerelease: true),
            release("v1.0.2-beta.1", prerelease: true),
        ]
        XCTAssertEqual(GitHubUpdateRelease.latest(in: releases, includePrereleases: false)?.tag, "v1.0.1")
        XCTAssertEqual(GitHubUpdateRelease.latest(in: releases, includePrereleases: true)?.tag, "v1.0.2-beta.1")
        XCTAssertEqual(GitHubUpdateRelease.latest(in: Array(releases.dropLast()), includePrereleases: true)?.tag, "v1.0.2-alpha.10")
        let stable = try release("v1.0.2")
        XCTAssertEqual(GitHubUpdateRelease.latest(in: releases + [stable], includePrereleases: true)?.tag, stable.tag)
    }

    func testRejectsDraftsMalformedTagsAndIncompleteInstallers() throws {
        let releases = try [
            release("v1.0.2-alpha", prerelease: true),
            release("v1.1.0", complete: false),
            release("v1.2.0", draft: true),
            release("v1.3.0-alpha"),
            release("v1.4.0-rc.1", prerelease: true),
        ]
        XCTAssertEqual(GitHubUpdateRelease.latest(in: releases, includePrereleases: true)?.tag, "v1.0.2-alpha")
        XCTAssertNil(GitHubUpdateRelease.latest(in: releases, includePrereleases: false))
    }

    func testRejectsDowngradeAndExistingBuild() throws {
        let release = try release("v1.0.2-alpha.2", prerelease: true)
        XCTAssertTrue(release.isNewer(build: 27, than: "1.0.2", build: 26))
        XCTAssertFalse(release.isNewer(build: 26, than: "1.0.2", build: 26))
        XCTAssertFalse(release.isNewer(build: 27, than: "1.0.3", build: 26))
        XCTAssertFalse(release.isNewer(build: 25, than: "1.0.1", build: 26))
    }

    func testHistoryIncludesPublishedNotesWithoutInstallerAssets() throws {
        let data = Data("""
        [
          {"tag_name":"v1.0.0-alpha","draft":false,"prerelease":true,"assets":[]},
          {"tag_name":"v1.0.2-beta.1","draft":false,"prerelease":true,"assets":[],
           "name":"Beta 1","body":"- New search","published_at":"2026-11-13T14:30:57Z"},
          {"tag_name":"v1.0.3","draft":true,"prerelease":false,"assets":[]}
        ]
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let releases = try decoder.decode([GitHubUpdateRelease].self, from: data)
        let history = GitHubUpdateRelease.history(in: releases)
        XCTAssertEqual(history.map(\.tag), ["v1.0.2-beta.1", "v1.0.0-alpha"])
        XCTAssertEqual(history.first?.title, "Beta 1")
        XCTAssertEqual(history.first?.notes, "- New search")
        XCTAssertNotNil(history.first?.publishedAt)
        XCTAssertNil(GitHubUpdateRelease.latest(in: releases, includePrereleases: true))
    }
}
