import CryptoKit
import Foundation
import XCTest
@testable import KeylaneCore

private final class InertEnrollmentAuthority: RaycastStoreFreshProfileEnrollmentAuthority,
    RaycastStoreProtectedReceiptStorage, @unchecked Sendable {
    typealias Enrollment = RaycastStoreReceiptEnrollment
    enum Scenario { case fresh, existing, ambiguous, existingAtCommit, commitThenThrow }
    private let mutex = NSLock()
    private let scenario: Scenario
    private var proof: (Enrollment.Scope, Data)?
    private var record: Data?
    private var attempts = 0

    init(_ scenario: Scenario = .fresh) { self.scenario = scenario }

    func authorize(_ scope: Enrollment.Scope, proof bytes: Data) {
        mutex.withLock { proof = (scope, bytes) }
    }

    func probe(scope: Enrollment.Scope) throws -> Enrollment.Observation {
        mutex.withLock {
            if record != nil || scenario == .existing { return .existingInstallation }
            return scenario == .ambiguous ? .ambiguous : .independentlyVerifiedFresh
        }
    }

    func commitFreshEnrollment(scope: Enrollment.Scope, approval: Data, initialRecord: Data) throws -> Enrollment.CommitResult {
        try mutex.withLock {
            attempts += 1
            if record != nil || scenario == .existing || scenario == .existingAtCommit { return .existingInstallation }
            guard scenario != .ambiguous else { return .ambiguous }
            guard let proof, proof.0 == scope, proof.1 == approval else { return .approvalRejected }
            self.proof = nil
            record = initialRecord
            if scenario == .commitThenThrow { throw CocoaError(.fileWriteUnknown) }
            return .enrolled
        }
    }

    func read() throws -> Data? { mutex.withLock { record } }
    func compareAndSwap(expected: Data?, replacement: Data) throws -> Bool { false }
    var commitAttempts: Int { mutex.withLock { attempts } }
}

final class RaycastStoreReceiptEnrollmentTests: XCTestCase {
    private let approval = Data([1, 6, 0])

    private func state(_ authority: InertEnrollmentAuthority, id: UUID = UUID()) throws -> RaycastStoreProtectedReceiptState {
        // Fixed public test point only; no key generation or credential APIs.
        let coordinates: [UInt8] = [
            0x04, 0x6b, 0x17, 0xd1, 0xf2, 0xe1, 0x2c, 0x42, 0x47, 0xf8, 0xbc, 0xe6, 0xe5, 0x63, 0xa4, 0x40,
            0xf2, 0x77, 0x03, 0x7d, 0x81, 0x2d, 0xeb, 0x33, 0xa0, 0xf4, 0xa1, 0x39, 0x45, 0xd8, 0x98, 0xc2, 0x96,
            0x4f, 0xe3, 0x42, 0xe2, 0xfe, 0x1a, 0x7f, 0x9b, 0x8e, 0xe7, 0xeb, 0x4a, 0x7c, 0x0f, 0x9e, 0x16,
            0x2b, 0xce, 0x33, 0x57, 0x6b, 0x31, 0x5e, 0xce, 0xcb, 0xb6, 0x40, 0x68, 0x37, 0xbf, 0x51, 0xf5
        ]
        return try .init(storage: authority, registryID: id,
            publicKey: P256.Signing.PublicKey(x963Representation: Data(coordinates)),
            recipe: .init(identifier: "synthetic-enrollment", runtimeDigest: String(repeating: "0", count: 64), qualifiedAPIVersions: []))
    }

    func testProbeCannotEnrollAndApprovalOnlyWorksOnceForBoundScope() throws {
        let authority = InertEnrollmentAuthority()
        let anchor = try state(authority)
        let enrollment = try anchor.enrollment(authority: authority)
        XCTAssertEqual(enrollment.probe(), .independentlyVerifiedFresh)
        XCTAssertEqual(authority.commitAttempts, 0)
        XCTAssertNil(try authority.read())

        authority.authorize(enrollment.scope, proof: approval)
        let wrongScope = try state(authority).enrollment(authority: authority)
        XCTAssertThrowsError(try wrongScope.enrollNewProfile(approval: approval)) {
            XCTAssertEqual($0 as? RaycastStoreReceiptEnrollment.Failure, .approvalRejected)
        }
        XCTAssertNil(try authority.read())
        try enrollment.enrollNewProfile(approval: approval)
        try anchor.verify(expectedDigest: nil)
        XCTAssertEqual(enrollment.probe(), .existingInstallation)
        XCTAssertThrowsError(try enrollment.enrollNewProfile(approval: approval)) {
            XCTAssertEqual($0 as? RaycastStoreReceiptEnrollment.Failure, .existingInstallation)
        }
        XCTAssertEqual(authority.commitAttempts, 2)
    }

    func testExistingAmbiguousAndRaceDoNotBootstrap() throws {
        for (scenario, expected, attempts): (InertEnrollmentAuthority.Scenario, RaycastStoreReceiptEnrollment.Failure, Int) in [
            (.existing, .existingInstallation, 0), (.ambiguous, .ambiguous, 0), (.existingAtCommit, .existingInstallation, 1)
        ] {
            let authority = InertEnrollmentAuthority(scenario)
            let enrollment = try state(authority).enrollment(authority: authority)
            authority.authorize(enrollment.scope, proof: approval)
            XCTAssertThrowsError(try enrollment.enrollNewProfile(approval: approval)) {
                XCTAssertEqual($0 as? RaycastStoreReceiptEnrollment.Failure, expected)
            }
            XCTAssertEqual(authority.commitAttempts, attempts)
            XCTAssertNil(try authority.read())
        }
    }

    func testFailedCompletionIsIndeterminateAndDoesNotRetry() throws {
        let authority = InertEnrollmentAuthority(.commitThenThrow)
        let enrollment = try state(authority).enrollment(authority: authority)
        authority.authorize(enrollment.scope, proof: approval)
        XCTAssertThrowsError(try enrollment.enrollNewProfile(approval: approval)) {
            XCTAssertEqual($0 as? RaycastStoreReceiptEnrollment.Failure, .indeterminate)
        }
        XCTAssertNotNil(try authority.read())
        XCTAssertEqual(authority.commitAttempts, 1)
        XCTAssertThrowsError(try enrollment.enrollNewProfile(approval: approval))
        XCTAssertEqual(authority.commitAttempts, 1)
    }
}
