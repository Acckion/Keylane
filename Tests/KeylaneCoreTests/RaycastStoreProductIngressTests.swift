import CryptoKit
import Foundation
import XCTest
@testable import KeylaneCore

final class RaycastStoreProductIngressTests: XCTestCase {
    @MainActor func testUnqualifiedOrMissingSignedSelectionCannotOpenStorageOrSign() async throws {
        let key = try P256.Signing.PublicKey(compressedRepresentation: Data([0x03, 0x6b, 0x17, 0xd1, 0xf2, 0xe1, 0x2c, 0x42, 0x47, 0xf8, 0xbc, 0xe6, 0xe5,
            0x63, 0xa4, 0x40, 0xf2, 0x77, 0x03, 0x7d, 0x81, 0x2d, 0xeb, 0x33, 0xa0, 0xf4, 0xa1, 0x39, 0x45, 0xd8, 0x98, 0xc2, 0x96]))
        enum Unexpected: Error { case called }
        let testDigest = String(repeating: "a", count: 64)
        for versions: Set<String> in [[], ["1.0.0"]] {
            let recipe = RaycastStoreArtifactSeal.Recipe(identifier: "test-ingress", runtimeDigest: testDigest, qualifiedAPIVersions: versions)
            let reader = RaycastStoreSelectedProfileReader(owner: UUID(), root: FileManager.default.temporaryDirectory,
                rootLock: .init(device: 0, inode: 1), expectedTeam: "TEST",
                verifiedRuntime: { ("TEST", testDigest) }, key: key, recipe: recipe, read: { _ in nil })
            let ingress = RaycastStoreProductIngress(application: .main, team: "TEST", recipe: recipe, key: key, grants: [],
                reader: reader, openStorage: { _ in XCTFail("storage must not open"); throw Unexpected.called },
                sign: { _ in XCTFail("signer must not run"); throw Unexpected.called },
                sink: { _, _, _ in XCTFail("sink must not run"); throw Unexpected.called })
            switch await ingress.open() {
            case .blocked(let reason): XCTAssertEqual(reason, versions.isEmpty ? .runtimeUnavailable : .noVerifiedProfile)
            case .ready: XCTFail("missing proof must not authorize install")
            }
        }
    }
}
