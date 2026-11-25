import Foundation
import XCTest
@testable import KeylaneCore

final class MacOSReviewedRaycastCacheTests: XCTestCase {
    func testCachePersistsAcrossGenerationsForOneInstallation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MacOSReviewedRaycastCache(root: directory)
        let installation = UUID().uuidString
        let first = ticket(installation, generation: 1)
        XCTAssertEqual(try store.read(for: first), "[]")
        let snapshot = try JSONEncoder().encode([["[\"namespace\",\"key\"]", "值"]])
        try store.write(snapshot, for: first)
        let reopened = MacOSReviewedRaycastCache(root: directory)
        XCTAssertEqual(Data(try reopened.read(for: first).utf8), snapshot)
        XCTAssertEqual(Data(try reopened.read(for: ticket(installation, generation: 2)).utf8), snapshot)
        XCTAssertEqual(try reopened.read(for: ticket(UUID().uuidString, generation: 1)), "[]")
        reopened.remove(installationID: try XCTUnwrap(UUID(uuidString: installation)))
        XCTAssertEqual(try reopened.read(for: first), "[]")
    }

    func testRejectsMalformedDuplicateAndOversizedSnapshots() throws {
        for entries in [
            [["not a tuple", "value"]],
            [["[\"\",\"key\"]", "one"], ["[\"\",\"key\"]", "two"]],
            [["[\"\",\"key\"]", String(repeating: "a", count: 16 * 1024 + 1)]],
        ] {
            let encoded = try JSONEncoder().encode(entries)
            XCTAssertThrowsError(try MacOSReviewedRaycastCache.validate(encoded))
        }
    }

    private func ticket(_ id: String, generation: UInt64) -> StoreGuestRunTicket {
        let installation = StoreRuntimeBridge.Installation(id: id, generation: generation)
        let receipt = StoreRuntimeBridge.Receipt(
            provenance: .init(installation: installation, entry: "src/main.js", projectDigest: "", runtimeDigest: ""),
            artifactDigest: ""
        )
        return StoreGuestRunTicket(id: UUID(), profileID: UUID(), installation: installation, receipt: receipt,
                                   commandID: "cache-test", capabilities: [MacOSReviewedRaycastCache.capability],
                                   launchContext: .init(), liveLease: { true })
    }
}
