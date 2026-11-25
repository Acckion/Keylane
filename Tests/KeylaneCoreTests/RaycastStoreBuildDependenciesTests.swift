import CryptoKit
import XCTest
@testable import KeylaneCore

final class RaycastStoreBuildDependenciesTests: XCTestCase {
    private let api = "@raycast/api", uuid = "uuid"

    private func node(_ name: String, _ version: String, attributes: [String: Any] = [:]) -> [String: Any] {
        let basename = name.split(separator: "/").last!
        return [
            "version": version, "resolved": "https://registry.npmjs.org/\(name)/-/\(basename)-\(version).tgz",
            "integrity": "sha512-" + Data(SHA512.hash(data: Data(name.utf8))).base64EncodedString()
        ].merging(attributes) { _, new in new }
    }

    private func plan(
        dependencies: [String: String], optional: [String: String] = [:],
        peers: [String: String] = [:], optionalPeers: [String] = [],
        extras: [String: Any] = [:]
    ) throws -> RaycastStoreDependencyPlan {
        let all: [String: Any] = [
            "": ["dependencies": dependencies, "optionalDependencies": optional,
                 "peerDependencies": peers, "peerDependenciesMeta": Dictionary(uniqueKeysWithValues: optionalPeers.map { ($0, ["optional": true]) })],
            "node_modules/@raycast/api": node(api, "1.95.0", attributes: ["dependencies": ["esbuild": "0.25.0"]]),
            "node_modules/esbuild": node("esbuild", "0.25.0", attributes: ["hasInstallScript": true]),
            "node_modules/uuid": node(uuid, "11.1.1"),
            "node_modules/typeid-js": node("typeid-js", "1.2.0", attributes: ["dependencies": [uuid: "^10.0.0"]]),
            "node_modules/typeid-js/node_modules/uuid": node(uuid, "10.0.0"),
            "node_modules/mac-only": node("mac-only", "1.0.0", attributes: ["os": ["darwin"]]),
        ]
        let json = try JSONSerialization.data(withJSONObject: ["lockfileVersion": 3, "packages": all.merging(extras) { _, new in new }])
        return try .init(lockJSON: json)
    }

    func testRuntimeProvidedAPIOmitsItsOwnBuildDependencyButKeepsNestedUUID() throws {
        let specs = [api: "^1.90.0", uuid: "^11.0.0", "typeid-js": "1.2.0"]
        let result = try RaycastStoreBuildDependencies(plan: plan(dependencies: specs), dependencies: specs, supportedRuntimeAPIVersions: ["1.95.0"])
        XCTAssertEqual(result.runtimeAPIVersion, "1.95.0")
        XCTAssertEqual(result.packages.map(\.path), ["node_modules/typeid-js", "node_modules/typeid-js/node_modules/uuid", "node_modules/uuid"])
        let explicit = specs.merging(["esbuild": "0.25.0"]) { _, new in new }
        XCTAssertThrowsError(try RaycastStoreBuildDependencies(plan: plan(dependencies: explicit), dependencies: explicit, supportedRuntimeAPIVersions: ["1.95.0"])) {
            XCTAssertEqual($0 as? RaycastStoreBuildDependencies.Failure, .unsupportedPackage("esbuild"))
        }
    }

    func testRequiresIdenticalRootLockAndKnownMatchedAPIVersion() throws {
        let specs = [api: "^1.90.0"]
        let graph = try plan(dependencies: specs)
        XCTAssertThrowsError(try RaycastStoreBuildDependencies(plan: graph, dependencies: [:], supportedRuntimeAPIVersions: ["1.95.0"])) {
            XCTAssertEqual($0 as? RaycastStoreBuildDependencies.Failure, .rootLockMismatch)
        }
        XCTAssertThrowsError(try RaycastStoreBuildDependencies(plan: graph, dependencies: specs, supportedRuntimeAPIVersions: ["1.95.1"])) {
            XCTAssertEqual($0 as? RaycastStoreBuildDependencies.Failure, .unsupportedRuntimeAPI("1.95.0"))
        }
        let fromFile = [api: "file:../api"]
        XCTAssertThrowsError(try RaycastStoreBuildDependencies(plan: plan(dependencies: fromFile), dependencies: fromFile, supportedRuntimeAPIVersions: ["1.95.0"]))
    }

    func testOptionalPlatformExclusionAndPeerPresence() throws {
        let specs = ["mac-only": "1.0.0", "never-present": "2.0.0"]
        let peers = ["optional-peer": "1.0.0", uuid: ">=11.0.0 <12.0.0 || ^10.0.0"]
        let graph = try plan(dependencies: [:], optional: specs, peers: peers, optionalPeers: ["optional-peer"])
        let result = try RaycastStoreBuildDependencies(plan: graph, dependencies: [:], optionalDependencies: specs,
                                                        peerDependencies: peers, optionalPeers: ["optional-peer"], supportedRuntimeAPIVersions: [])
        XCTAssertEqual(result.packages.map(\.name), [uuid])
        XCTAssertThrowsError(try RaycastStoreBuildDependencies(plan: plan(dependencies: [:], peers: peers), dependencies: [:], peerDependencies: peers,
                                                                 supportedRuntimeAPIVersions: [])) {
            XCTAssertEqual($0 as? RaycastStoreBuildDependencies.Failure, .missing("optional-peer"))
        }
        let needed = ["mac-only": "1.0.0"]
        XCTAssertThrowsError(try RaycastStoreBuildDependencies(plan: plan(dependencies: needed), dependencies: needed, supportedRuntimeAPIVersions: [])) {
            XCTAssertEqual($0 as? RaycastStoreBuildDependencies.Failure, .unsupportedPackage("mac-only"))
        }
    }

    func testStableRangeMatchingNeverCoercesUnsupportedOrMismatchedVersions() throws {
        for spec in ["^12.0.0", "11.1.0", "~11.0.0", "latest", "git+https://example.org/uuid.git"] {
            let specs = [uuid: spec]
            XCTAssertThrowsError(try RaycastStoreBuildDependencies(plan: plan(dependencies: specs), dependencies: specs, supportedRuntimeAPIVersions: [])) {
                XCTAssertEqual($0 as? RaycastStoreBuildDependencies.Failure, .unsatisfiedVersion(uuid))
            }
        }
        for spec in ["11.1.1", "^11.0.0", "~11.1.0", ">=11.0.0 <11.2.0", "*"] {
            let specs = [uuid: spec]
            XCTAssertNoThrow(try RaycastStoreBuildDependencies(plan: plan(dependencies: specs), dependencies: specs, supportedRuntimeAPIVersions: []))
        }
    }
    func testDarwinTargetSelectsMacPurePackagesWithoutChangingLegacyProjection() throws {
        let needed = ["mac-only": "1.0.0"]
        let graph = try plan(dependencies: needed)
        let result = try RaycastStoreBuildDependencies(plan: graph, dependencies: needed, supportedRuntimeAPIVersions: [], target: .macOSArm64)
        XCTAssertEqual(result.packages.map(\.name), ["mac-only"])
        XCTAssertThrowsError(try RaycastStoreBuildDependencies(plan: graph, dependencies: needed, supportedRuntimeAPIVersions: [], target: .linuxArm64))
    }

}
