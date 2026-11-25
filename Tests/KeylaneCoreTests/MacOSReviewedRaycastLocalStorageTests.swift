import Foundation
import XCTest
@testable import KeylaneCore

final class MacOSReviewedRaycastLocalStorageTests: XCTestCase {
    func testLocalStoragePersistsAcrossGenerationsAndIsIsolatedFromOtherStores() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storage = MacOSReviewedRaycastLocalStorage(root: directory)
        let installation = UUID()
        let initial = ticket(installation, generation: 1)
        XCTAssertEqual(try storage.read(for: initial), "[]")
        let snapshot = Data(#"[["006b","n8000000000000000"],["d800","sd801"]]"#.utf8)
        try storage.write(snapshot, for: initial)

        let reopened = MacOSReviewedRaycastLocalStorage(root: directory)
        let nextGeneration = ticket(installation, generation: 2)
        XCTAssertEqual(Data(try reopened.read(for: nextGeneration).utf8), snapshot)
        XCTAssertEqual(try reopened.read(for: ticket(UUID(), generation: 1)), "[]")
        XCTAssertEqual(try MacOSReviewedRaycastCache(root: directory).read(for: nextGeneration), "[]")
        XCTAssertThrowsError(try reopened.write(Data(#"[["006b","b1"],["006b","b0"]]"#.utf8), for: nextGeneration))
        XCTAssertEqual(Data(try reopened.read(for: nextGeneration).utf8), snapshot)
        reopened.remove(installationID: installation)
        XCTAssertEqual(try reopened.read(for: nextGeneration), "[]")
    }

    func testAtomicDualWritePreservesLegacyDataAndRejectsPartialCommit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let id = UUID()
        let initial = ticket(id, generation: 1)
        let legacy = Data(#"[["006b","b1"]]"#.utf8)
        try MacOSReviewedRaycastLocalStorage(root: directory).write(legacy, for: initial)
        let store = MacOSReviewedRaycastStorage(root: directory)
        let first = try store.read(for: initial, cache: true, localStorage: true)
        XCTAssertEqual(first.cache, "[]")
        XCTAssertEqual(first.localStorage, String(decoding: legacy, as: UTF8.self))

        let cache = try JSONEncoder().encode([[#"["","key"]"#, "value"]])
        let local = Data(#"[["006b","b0"]]"#.utf8)
        try store.write(cache: cache, localStorage: local, for: initial)
        let reopened = MacOSReviewedRaycastStorage(root: directory)
        let next = ticket(id, generation: 2)
        XCTAssertThrowsError(try reopened.write(cache: Data("[]".utf8), localStorage: Data("null".utf8), for: next))
        let observed = try reopened.read(for: next, cache: true, localStorage: true)
        XCTAssertEqual(observed.cache, String(decoding: cache, as: UTF8.self))
        XCTAssertEqual(observed.localStorage, String(decoding: local, as: UTF8.self))
        XCTAssertNil(try reopened.read(for: next, cache: true, localStorage: false).localStorage)
        let unrelated = try reopened.read(for: ticket(UUID(), generation: 1), cache: true, localStorage: true)
        XCTAssertEqual(unrelated.cache, "[]")
        XCTAssertEqual(unrelated.localStorage, "[]")
        reopened.remove(installationID: id)
        XCTAssertEqual(try reopened.read(for: next, cache: true, localStorage: true).localStorage, "[]")
    }

    func testSupportFilesAreScopedAndShareTheStorageTransaction() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let original = ticket(id, generation: 1)
        let store = MacOSReviewedRaycastStorage(root: directory)
        let initial = ["/support/data.txt": Data("initial".utf8)]
        let local = Data(#"[["006b","b0"]]"#.utf8)
        try store.write(cache: nil, localStorage: local, supportFiles: JSONEncoder().encode(initial), for: original)

        let reopened = ticket(id, generation: 2)
        for path in ["/assets/wrong", "/support/../wrong", "/support//wrong", "/outside"] {
            let invalid = try JSONEncoder().encode([path: Data("wrong".utf8)])
            XCTAssertThrowsError(try store.write(cache: nil, localStorage: Data("[]".utf8), supportFiles: invalid, for: reopened))
        }
        let scoped = try store.read(for: reopened, cache: false, localStorage: true, support: true)
        XCTAssertEqual(scoped.localStorage, String(decoding: local, as: UTF8.self))
        XCTAssertEqual(scoped.supportFiles, initial)
        XCTAssertNil(try store.read(for: reopened, cache: false, localStorage: false).supportFiles)
        XCTAssertEqual(try store.read(for: ticket(UUID(), generation: 1), cache: false, localStorage: false, support: true).supportFiles, [:])
        store.remove(installationID: id)
        XCTAssertEqual(try store.read(for: reopened, cache: false, localStorage: false, support: true).supportFiles, [:])
    }

    private func ticket(_ id: UUID, generation: UInt64) -> StoreGuestRunTicket {
        let installation = StoreRuntimeBridge.Installation(id: id.uuidString, generation: generation)
        let receipt = StoreRuntimeBridge.Receipt(
            provenance: .init(installation: installation, entry: "src/main.js", projectDigest: "", runtimeDigest: ""),
            artifactDigest: ""
        )
        return StoreGuestRunTicket(id: UUID(), profileID: UUID(), installation: installation, receipt: receipt,
                                   commandID: "local-storage-test",
                                   capabilities: [MacOSReviewedRaycastLocalStorage.capability],
                                   launchContext: .init(), liveLease: { true })
    }
}
