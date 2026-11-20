import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import KeylaneCore

private struct NoNativeReadbackStore: RaycastStoreProtectedReceiptStorage {
    func read() throws -> Data? { nil }
    func compareAndSwap(expected: Data?, replacement: Data) throws -> Bool { false }
}

final class RaycastStoreSelectedProfileReaderTests: XCTestCase {
    typealias Reader = RaycastStoreSelectedProfileReader
    private let owner = UUID(), profile = UUID(), registry = UUID(), proof = UUID()
    private let recipe = RaycastStoreArtifactSeal.Recipe(identifier: "test-readback",
        runtimeDigest: String(repeating: "0", count: 64), qualifiedAPIVersions: [])

    private func key() throws -> P256.Signing.PublicKey {
        try .init(compressedRepresentation: Data([0x03, 0x6b, 0x17, 0xd1, 0xf2, 0xe1, 0x2c, 0x42, 0x47, 0xf8, 0xbc, 0xe6, 0xe5,
            0x63, 0xa4, 0x40, 0xf2, 0x77, 0x03, 0x7d, 0x81, 0x2d, 0xeb, 0x33, 0xa0, 0xf4, 0xa1, 0x39, 0x45, 0xd8, 0x98, 0xc2, 0x96]))
    }

    private func lock(_ path: URL) throws -> Reader.Lock {
        var info = stat()
        guard lstat(path.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        return .init(device: info.st_dev, inode: info.st_ino)
    }

    private func json(_ values: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: values) }

    private func fixture(legacyUnbound: Bool = false) throws -> (URL, URL, [String: Data], Reader.Lock) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent(profile.uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let paths = [RaycastStoreProtectedReceiptState.OwnerBinding.lockName, "journal.pending.lock", "receipt-authority.lock"].map { folder.appendingPathComponent($0) }
        for path in paths {
            guard FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else { throw CocoaError(.fileWriteUnknown) }
        }
        let ids = try ([folder] + paths).map(lock)
        let ownerBinding = RaycastStoreProtectedReceiptState.OwnerBinding(profileID: profile, rootPath: folder.path,
            rootDevice: Int64(ids[0].device), rootInode: ids[0].inode, lockDevice: Int64(ids[1].device), lockInode: ids[1].inode)
        let anchor = try RaycastStoreProtectedReceiptState(storage: NoNativeReadbackStore(), registryID: registry,
            publicKey: key(), recipe: recipe, owner: legacyUnbound ? nil : ownerBinding)
        let binding = anchor.enrollmentScope.bindingDigest
        let pointer = try json(["version": 1, "owner": owner.uuidString, "profileID": profile.uuidString,
                                "registryID": registry.uuidString, "binding": binding, "proofID": proof.uuidString])
        let records = [
            "selected-profile:" + owner.uuidString: pointer,
            "selection-attempt:" + owner.uuidString: pointer,
            "binding:" + profile.uuidString: try json(["phase": "receipt-bound", "profile": profile.uuidString,
                "registry": registry.uuidString, "binding": binding,
                "lockIDs": ids.map { [UInt64(UInt32(bitPattern: $0.device)), $0.inode] }]),
            "journal:" + registry.uuidString: try json(["version": 1, "registryID": registry.uuidString,
                "binding": binding, "phase": "enrolled", "consumedProof": UUID().uuidString,
                "lockDevice": ids[3].device, "lockInode": ids[3].inode]),
            registry.uuidString: try json(["schema": 1, "registryID": registry.uuidString, "binding": binding, "sequence": 0])
        ]
        return (root, folder, records, ids[3])
    }

    private func reader(_ root: URL, records: [String: Data], team: String = "TESTTEAM",
                        runtimeDigest: String? = nil,
                        recipe override: RaycastStoreArtifactSeal.Recipe? = nil) throws -> Reader {
        let observedDigest = runtimeDigest ?? (override ?? recipe).runtimeDigest
        return try Reader(owner: owner, root: root, rootLock: lock(root), expectedTeam: "TESTTEAM",
                   verifiedRuntime: { (team, observedDigest) }, key: key(), recipe: override ?? recipe, read: { records[$0] })
    }

    func testExactSelectedProfileReadsAndNeverReturnsMissingOrSplitState() throws {
        let (root, _, records, receipt) = try fixture()
        let selected = try XCTUnwrap(reader(root, records: records).selected())
        XCTAssertEqual(selected.profileID, profile)
        XCTAssertEqual(selected.scope.registryID, registry)
        XCTAssertEqual(selected.receiptLock, receipt)
        let liveOwner = try StoreGuestCommonAuthority.ProfileOwner(root: URL(fileURLWithPath: selected.ownerBinding.rootPath),
            profileID: selected.profileID, expected: selected.ownerBinding)
        XCTAssertTrue(liveOwner.isCurrent())
        for account in records.keys {
            var missing = records
            missing[account] = nil
            XCTAssertNil(try reader(root, records: missing).selected(), account)
        }
        XCTAssertNil(try reader(root, records: records, team: "OTHERTEAM").selected())
        XCTAssertNil(try reader(root, records: records, runtimeDigest: String(repeating: "e", count: 64)).selected())
        let wrong = RaycastStoreArtifactSeal.Recipe(identifier: "other-recipe",
            runtimeDigest: String(repeating: "1", count: 64), qualifiedAPIVersions: [])
        XCTAssertNil(try reader(root, records: records, recipe: wrong).selected())
    }

    func testLegacyUnboundScopeAndOldFilenameAreNotAdmitted() throws {
        let (root, _, records, _) = try fixture(legacyUnbound: true)
        XCTAssertNil(try reader(root, records: records).selected())
        let (testRoot, folder, valid, _) = try fixture()
        let canonical = folder.appendingPathComponent(RaycastStoreProtectedReceiptState.OwnerBinding.lockName)
        try FileManager.default.moveItem(at: canonical, to: folder.appendingPathComponent("owner.pending.lock"))
        XCTAssertNil(try reader(testRoot, records: valid).selected())
    }

    func testStaleOwnerLockOrCorruptReceiptStaysBrowseOnly() throws {
        let (root, folder, records, _) = try fixture()
        var wrongReceipt = records
        wrongReceipt[registry.uuidString] = Data([0xff])
        XCTAssertNil(try reader(root, records: wrongReceipt).selected())
        let live = folder.appendingPathComponent(RaycastStoreProtectedReceiptState.OwnerBinding.lockName)
        try FileManager.default.moveItem(at: live, to: folder.appendingPathComponent("old"))
        XCTAssertTrue(FileManager.default.createFile(atPath: live.path, contents: nil, attributes: [.posixPermissions: 0o600]))
        XCTAssertNil(try reader(root, records: records).selected())
    }
}
