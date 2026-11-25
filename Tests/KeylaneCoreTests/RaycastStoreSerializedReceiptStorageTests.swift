import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import KeylaneCore

private final class InertReceiptSlot: RaycastStoreProtectedReceiptSlot, @unchecked Sendable {
    private let mutex = NSLock()
    private var value: Data?
    private var writes = 0
    private let afterReplace: (@Sendable () throws -> Void)?
    private let onRead: (@Sendable () throws -> Void)?

    init(_ value: Data?, afterReplace: (@Sendable () throws -> Void)? = nil, onRead: (@Sendable () throws -> Void)? = nil) {
        self.value = value
        self.afterReplace = afterReplace
        self.onRead = onRead
    }

    func readExisting() throws -> Data? {
        try onRead?()
        return mutex.withLock { value }
    }

    func replaceExisting(with bytes: Data) throws {
        mutex.withLock { value = bytes; writes += 1 }
        try afterReplace?()
    }

    var writeCount: Int { mutex.withLock { writes } }
}

final class RaycastStoreSerializedReceiptStorageTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        try putLock(in: root)
        return root
    }

    private func putLock(in directory: URL) throws {
        let path = directory.appendingPathComponent("receipt-authority.lock")
        guard FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func identity(in directory: URL) throws -> RaycastStoreSerializedReceiptStorage.LockIdentity {
        var info = stat()
        guard lstat(directory.appendingPathComponent("receipt-authority.lock").path, &info) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return .init(device: info.st_dev, inode: info.st_ino)
    }

    func testTwoIndependentWorkersHaveExactlyOneCASWinnerAndRestartSeesIt() async throws {
        let directory = try makeDirectory()
        let initial = Data([1]), first = Data([2]), second = Data([3])
        let slot = InertReceiptSlot(initial)
        let a = RaycastStoreSerializedReceiptStorage(directory: directory, lockIdentity: try identity(in: directory), slot: slot)
        let b = RaycastStoreSerializedReceiptStorage(directory: directory, lockIdentity: try identity(in: directory), slot: slot)
        async let left = a.compareAndSwap(expected: initial, replacement: first)
        async let right = b.compareAndSwap(expected: initial, replacement: second)
        let (l, r) = try await (left, right)
        XCTAssertNotEqual(l, r)
        XCTAssertEqual(slot.writeCount, 1)
        let restarted = RaycastStoreSerializedReceiptStorage(directory: directory, lockIdentity: try identity(in: directory), slot: slot)
        XCTAssertEqual(try restarted.read(), l ? first : second)
        XCTAssertFalse(try restarted.compareAndSwap(expected: initial, replacement: Data([4])))
        XCTAssertThrowsError(try restarted.compareAndSwap(expected: l ? first : second, replacement: Data(count: 1025)))
        XCTAssertEqual(slot.writeCount, 1)
    }

    func testSlotLossOrDualLossCannotInitializeAndRetainsTypedReview() throws {
        let directory = try makeDirectory()
        let slot = InertReceiptSlot(nil)
        let storage = RaycastStoreSerializedReceiptStorage(directory: directory, lockIdentity: try identity(in: directory), slot: slot)
        XCTAssertThrowsError(try storage.compareAndSwap(expected: nil, replacement: Data([1]))) {
            XCTAssertEqual($0 as? RaycastStoreSerializedReceiptStorage.Failure, .protectedStateMissing)
        }
        let anchor = try RaycastStoreProtectedReceiptState(storage: storage, registryID: UUID(),
            publicKey: P256.Signing.PrivateKey().publicKey,
            recipe: .init(identifier: "synthetic-recipe", runtimeDigest: String(repeating: "0", count: 64), qualifiedAPIVersions: []))
        XCTAssertEqual(anchor.recoveryStatus(observedRegistryDigest: nil), .protectedStateMissing)
        XCTAssertThrowsError(try anchor.initializeNewRegistry(observedRegistryDigest: nil))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("receipt-authority.lock"))
        XCTAssertThrowsError(try storage.read()) {
            XCTAssertEqual($0 as? RaycastStoreSerializedReceiptStorage.Failure, .unsafeLock)
        }
        XCTAssertEqual(anchor.recoveryStatus(observedRegistryDigest: nil), .unreadable)
        XCTAssertThrowsError(try anchor.initializeNewRegistry(observedRegistryDigest: nil))
        XCTAssertEqual(slot.writeCount, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testRestartWillNotAdoptAReplacementLockWithPrivatePermissions() throws {
        let directory = try makeDirectory()
        let lock = directory.appendingPathComponent("receipt-authority.lock")
        let enrolledIdentity = try identity(in: directory)
        try FileManager.default.moveItem(at: lock, to: directory.appendingPathComponent("old.lock"))
        try putLock(in: directory)
        let slot = InertReceiptSlot(Data([1]))
        let storage = RaycastStoreSerializedReceiptStorage(directory: directory, lockIdentity: enrolledIdentity, slot: slot)
        XCTAssertThrowsError(try storage.compareAndSwap(expected: Data([1]), replacement: Data([2]))) {
            XCTAssertEqual($0 as? RaycastStoreSerializedReceiptStorage.Failure, .unsafeLock)
        }
        XCTAssertEqual(slot.writeCount, 0)
    }

    func testLockReplacementDuringProtectedWriteReportsIndeterminate() throws {
        let directory = try makeDirectory()
        let lock = directory.appendingPathComponent("receipt-authority.lock")
        let slot = InertReceiptSlot(Data([1]), afterReplace: {
            try FileManager.default.moveItem(at: lock, to: directory.appendingPathComponent("old.lock"))
        })
        let storage = RaycastStoreSerializedReceiptStorage(directory: directory, lockIdentity: try identity(in: directory), slot: slot)
        XCTAssertThrowsError(try storage.compareAndSwap(expected: Data([1]), replacement: Data([2]))) {
            XCTAssertEqual($0 as? RaycastStoreProtectedReceiptState.Failure, .review(.protectedWriteIndeterminate))
        }
        XCTAssertEqual(try slot.readExisting(), Data([2]))
        XCTAssertThrowsError(try storage.compareAndSwap(expected: Data([1]), replacement: Data([3])))
        XCTAssertEqual(slot.writeCount, 1)
    }

    func testProtectedStoreErrorAfterCommitReportsIndeterminate() throws {
        let directory = try makeDirectory()
        let slot = InertReceiptSlot(Data([1]), afterReplace: { throw CocoaError(.fileWriteUnknown) })
        let storage = RaycastStoreSerializedReceiptStorage(directory: directory, lockIdentity: try identity(in: directory), slot: slot)
        XCTAssertThrowsError(try storage.compareAndSwap(expected: Data([1]), replacement: Data([2]))) {
            XCTAssertEqual($0 as? RaycastStoreProtectedReceiptState.Failure, .review(.protectedWriteIndeterminate))
        }
        XCTAssertEqual(try storage.read(), Data([2]))
        XCTAssertFalse(try storage.compareAndSwap(expected: Data([1]), replacement: Data([3])))
        XCTAssertEqual(slot.writeCount, 1)
    }

    func testReplacedOrSymlinkedLockCannotWrite() throws {
        let directory = try makeDirectory()
        let lock = directory.appendingPathComponent("receipt-authority.lock")
        let moved = directory.appendingPathComponent("moved.lock")
        let slot = InertReceiptSlot(Data([1]), onRead: {
            try FileManager.default.moveItem(at: lock, to: moved)
            try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: moved)
        })
        let storage = RaycastStoreSerializedReceiptStorage(directory: directory, lockIdentity: try identity(in: directory), slot: slot)
        XCTAssertThrowsError(try storage.compareAndSwap(expected: Data([1]), replacement: Data([2]))) {
            XCTAssertEqual($0 as? RaycastStoreSerializedReceiptStorage.Failure, .unsafeLock)
        }
        XCTAssertEqual(slot.writeCount, 0)
        XCTAssertThrowsError(try storage.read()) {
            XCTAssertEqual($0 as? RaycastStoreSerializedReceiptStorage.Failure, .unsafeLock)
        }
    }
}
