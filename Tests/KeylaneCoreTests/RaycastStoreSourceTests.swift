import XCTest
@testable import KeylaneCore

final class RaycastStoreSourceTests: XCTestCase {
    private let revision = String(repeating: "a", count: 40)

    func testEveryOfficialCatalogEntryCanBeSelectedWithoutAnExtensionAllowlist() throws {
        let slugs = (0..<15000).map { "extension-\($0)" }
        let catalog = RaycastPublicCatalog.Index(revision: revision, slugs: slugs)
        for slug in slugs {
            let source = try RaycastStoreSource(slug: slug, catalog: catalog)
            XCTAssertEqual(source.slug, slug)
            XCTAssertEqual(source.revision, revision)
        }
    }

    func testSelectionPinsRevisionAndOfficialSource() throws {
        let source = try RaycastStoreSource(slug: "unseen-community-extension", catalog: .init(
            revision: revision, slugs: ["unseen-community-extension"]))
        XCTAssertEqual(source.manifestURL.absoluteString,
                       "https://raw.githubusercontent.com/raycast/extensions/\(revision)/extensions/unseen-community-extension/package.json")
    }

    func testCurrentBuildDoesNotClaimProductionInstallerReadiness() {
        guard case .unavailable(let reason) = RaycastStoreBackendAvailability.current else {
            return XCTFail("Production installer must not be claimed before integration")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    func testRejectsUnlistedSourceAndMutableRef() {
        XCTAssertThrowsError(try RaycastStoreSource(slug: "arbitrary", catalog: .init(revision: revision, slugs: [])))
        for ref in ["main", "../main", String(repeating: "g", count: 40), String(repeating: "a", count: 41)] {
            XCTAssertThrowsError(try RaycastStoreSource(slug: "example", catalog: .init(revision: ref, slugs: ["example"])))
        }
    }

    func testRejectsTraversalAndURLInjectionEvenIfListed() {
        for slug in ["", ".", "..", "../other", "https://evil.test", "x?ref=main", "a%2Fb", "x\\y", String(repeating: "x", count: 129)] {
            XCTAssertThrowsError(try RaycastStoreSource(slug: slug, catalog: .init(revision: revision, slugs: [slug])))
        }
    }
}
