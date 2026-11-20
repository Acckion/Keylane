import XCTest
@testable import KeylaneCore

final class RaycastStorePresentationStateTests: XCTestCase {
    func testMutatingOneInstallationPreservesOtherCommandReadiness() {
        let first = UUID(), second = UUID()
        var state = RaycastStorePresentationState()
        state.launchReady = [first.uuidString + "/run", first.uuidString + "/other", second.uuidString + "/run"]
        state.readinessMessages = ["first": "stale", "second": "keep"]
        state.invalidateReadiness(installationID: first, slug: "first")
        XCTAssertEqual(state.launchReady, [second.uuidString + "/run"])
        XCTAssertEqual(state.readinessMessages, ["second": "keep"])
        state.invalidateReadiness(installationID: nil, slug: "new-extension")
        XCTAssertEqual(state.launchReady, [second.uuidString + "/run"])
    }

    func testSuccessfulAuthoritativeRestoreClearsStaleFailureAndReconciliationState() {
        var state = RaycastStorePresentationState()
        state.needsReconciliation = ["restored", "now-uninstalled"]
        state.installationMessages = ["restored": "unknown result", "now-uninstalled": "old failure"]
        state.readinessMessages = ["restored": "stale gate result"]
        state.launchReady = [UUID().uuidString + "/old"]
        state.inventoryRestored()
        XCTAssertTrue(state.needsReconciliation.isEmpty)
        XCTAssertTrue(state.installationMessages.isEmpty)
        XCTAssertTrue(state.readinessMessages.isEmpty)
        XCTAssertTrue(state.launchReady.isEmpty)
    }

    func testInstalledSourceWinsOverNewCatalogAndPreviouslySelectedDetail() throws {
        let old = RaycastPublicCatalog.Index(revision: String(repeating: "a", count: 40), slugs: ["example"])
        let new = RaycastPublicCatalog.Index(revision: String(repeating: "b", count: 40), slugs: ["example"])
        let installed = try RaycastStoreSource(slug: "example", catalog: old)
        let detail = try RaycastStoreSource(slug: "example", catalog: new)
        let source = RaycastStorePresentationState.source(slug: "example", installed: installed, detail: detail, catalog: new)
        XCTAssertEqual(source, installed)
        XCTAssertTrue(source!.manifestURL.absoluteString.contains(old.revision))
        XCTAssertEqual(RaycastStorePresentationState.source(slug: "example", installed: nil, detail: nil, catalog: new), detail)
        XCTAssertEqual(RaycastStorePresentationState.source(slug: "example", installed: installed, detail: nil, catalog: nil), installed)
    }
}
