import XCTest
@testable import KeylaneCore

@MainActor private final class ConsentFixture {
    let requested: RaycastStoreSource
    var source: RaycastStoreSource?
    var metadata: RaycastStoreSource?
    var pending = false
    var dispatched = 0
    var prompts = 0

    init(_ requested: RaycastStoreSource) {
        self.requested = requested
        source = requested
        metadata = requested
    }

    func run(prompt: () async -> Bool) async -> RaycastStoreInstallConsent.Outcome {
        await RaycastStoreInstallConsent.run(requested, reserve: {
            guard !self.pending else { return false }
            self.pending = true
            return true
        }, release: {
            self.pending = false
        }, snapshot: {
            .init(source: self.source, metadataSource: self.metadata, metadataCompatible: self.metadata != nil, available: true)
        }, prompt: {
            self.prompts += 1
            return await prompt()
        }, dispatch: {
            XCTAssertTrue(self.pending)
            self.dispatched += 1
        })
    }
}

final class RaycastStoreInstallConsentTests: XCTestCase {
    private func source(_ revision: Character) throws -> RaycastStoreSource {
        let slug = "fixture-example"
        return try .init(slug: slug, catalog: .init(revision: String(repeating: revision, count: 40), slugs: [slug]))
    }

    @MainActor func testReentryIsNotACancellationAndLeaseCoversDispatch() async throws {
        let fixture = ConsentFixture(try source("a"))
        let outer = await fixture.run {
            let nested = await fixture.run { XCTFail("duplicate modal"); return true }
            XCTAssertEqual(nested, .alreadyPending)
            XCTAssertTrue(fixture.pending)
            return true
        }
        XCTAssertEqual(outer, .dispatched)
        XCTAssertTrue(!fixture.pending)
        XCTAssertEqual(fixture.prompts, 1)
        XCTAssertEqual(fixture.dispatched, 1)
        let cancelled = await fixture.run { false }
        XCTAssertEqual(cancelled, .cancelled)
        XCTAssertFalse(fixture.pending)
        XCTAssertEqual(fixture.dispatched, 1)
    }

    @MainActor func testMetadataDisappearanceAndChangedRevisionNeverDispatch() async throws {
        let old = try source("a"), updated = try source("b")
        let fixture = ConsentFixture(old)
        let missing = await fixture.run {
            fixture.metadata = nil
            return true
        }
        XCTAssertEqual(missing, .selectionChanged)
        XCTAssertFalse(fixture.pending)
        fixture.metadata = old
        let changed = await fixture.run {
            fixture.source = updated
            fixture.metadata = updated
            return true
        }
        XCTAssertEqual(changed, .selectionChanged)
        XCTAssertFalse(fixture.pending)
        XCTAssertEqual(fixture.dispatched, 0)
    }
}
