import XCTest
import CryptoKit
@testable import KeylaneCore

final class RaycastStoreDependencyPlanTests: XCTestCase {
    // Selected public metadata from uuid-generator at
    // raycast/extensions 886cbd73fe377ad1d8f0c17083e6cd4c96748a33.
    // Root deps restricted to these selected nodes; package versions/URLs/hashes
    // and package dependency edges unchanged. Not extension executable code.
    private var genuineSubset: Data { Data(#"""
{
  "lockfileVersion": 3,
  "packages": {
    "": {
      "dependencies": {
        "uuid": "^11.0.5",
        "typeid-js": "^1.2.0",
        "ulidx": "^2.4.1"
      },
      "devDependencies": {
        "@types/uuid": "^10.0.0"
      }
    },
    "node_modules/uuid": {
      "version": "11.1.1",
      "resolved": "https://registry.npmjs.org/uuid/-/uuid-11.1.1.tgz",
      "integrity": "sha512-vIYxrBCC/N/K+Js3qSN88go7kIfNPssr/hHCesKCQNAjmgvYS2oqr69kIufEG+O4+PfezOH4EbIeHCfFov8ZgQ=="
    },
    "node_modules/typeid-js": {
      "version": "1.2.0",
      "resolved": "https://registry.npmjs.org/typeid-js/-/typeid-js-1.2.0.tgz",
      "integrity": "sha512-t76ZucAnvGC60ea/HjVsB0TSoB0cw9yjnfurUgtInXQWUI/VcrlZGpO23KN3iSe8yOGUgb1zr7W7uEzJ3hSljA==",
      "dependencies": {
        "uuid": "^10.0.0"
      }
    },
    "node_modules/typeid-js/node_modules/uuid": {
      "version": "10.0.0",
      "resolved": "https://registry.npmjs.org/uuid/-/uuid-10.0.0.tgz",
      "integrity": "sha512-8XkAphELsDnEGrDxUOHB3RGvXz6TeuYSGEZBOjtTtPm2lwhGBjLgOzLHB63IUWfBpNucQjND6d3AOudO+H3RWQ=="
    },
    "node_modules/ulidx": {
      "version": "2.4.1",
      "resolved": "https://registry.npmjs.org/ulidx/-/ulidx-2.4.1.tgz",
      "integrity": "sha512-xY7c8LPyzvhvew0Fn+Ek3wBC9STZAuDI/Y5andCKi9AX6/jvfaX45PhsDX8oxgPL0YFp0Jhr8qWMbS/p9375Xg==",
      "dependencies": {
        "layerr": "^3.0.0"
      }
    },
    "node_modules/layerr": {
      "version": "3.0.0",
      "resolved": "https://registry.npmjs.org/layerr/-/layerr-3.0.0.tgz",
      "integrity": "sha512-tv754Ki2dXpPVApOrjTyRo4/QegVb9eVFq4mjqp4+NM5NaX7syQvN5BBNfV/ZpAHCEHV24XdUVrBAoka4jt3pA=="
    },
    "node_modules/@types/uuid": {
      "version": "10.0.0",
      "resolved": "https://registry.npmjs.org/@types/uuid/-/uuid-10.0.0.tgz",
      "integrity": "sha512-7gqG38EyHgyP1S+7+xomFtL+ZNHcKv6DwNaCZmJmo1vgMugyF3TCnXVg4t1uk89mLNwnLtnY3TpOpCOyp1/xHQ==",
      "dev": true
    }
  }
}
"""#.utf8) }
    func testGenuineNestedUUIDAndHoistedLayerrArePreserved() throws {
        let plan = try RaycastStoreDependencyPlan(lockJSON: genuineSubset)
        let nodes = Dictionary(uniqueKeysWithValues: plan.nodes.map { ($0.path, $0) })
        XCTAssertEqual(nodes["node_modules/uuid"]?.version, "11.1.1")
        XCTAssertEqual(nodes["node_modules/typeid-js/node_modules/uuid"]?.version, "10.0.0")
        XCTAssertEqual(nodes["node_modules/typeid-js"]?.edges.first?.targetPath, "node_modules/typeid-js/node_modules/uuid")
        XCTAssertEqual(nodes["node_modules/ulidx"]?.edges.first?.targetPath, "node_modules/layerr")
        XCTAssertEqual(nodes["node_modules/@types/uuid"]?.dev, true)
        XCTAssertEqual(plan.rootEdges.filter { $0.kind == .development }.count, 1)
        XCTAssertTrue(plan.requiresIsolatedValidation)
        XCTAssertFalse(plan.productionReachablePaths.contains("node_modules/@types/uuid"))
        XCTAssertTrue(plan.productionReachablePaths.contains("node_modules/typeid-js/node_modules/uuid"))
        XCTAssertTrue(plan.productionReachablePaths.contains("node_modules/layerr"))
    }
    private func lock(path: String = "node_modules/example", version: String = "1.2.3", overrides: [String: Any] = [:]) throws -> Data {
        var node: [String: Any] = ["version": version, "resolved": "https://registry.npmjs.org/example/-/example-1.2.3.tgz",
            "integrity": "sha512-" + Data(SHA512.hash(data: Data("fixture".utf8))).base64EncodedString()]
        node.merge(overrides) { _, new in new }
        return try JSONSerialization.data(withJSONObject: ["lockfileVersion": 3, "packages": ["": [:], path: node]])
    }
    func testBoundedSHA512VerificationRejectsTampering() throws {
        let node = try XCTUnwrap(RaycastStoreDependencyPlan(lockJSON: lock()).nodes.first)
        XCTAssertTrue(node.verifiesTarball(Data("fixture".utf8)))
        XCTAssertFalse(node.verifiesTarball(Data("changed".utf8)))
        XCTAssertFalse(node.verifiesTarball(Data()))
        XCTAssertFalse(node.verifiesTarball(Data(repeating: 0, count: 16 * 1024 * 1024 + 1)))
    }
    func testScriptsNativeAndNonRegistrySourcesAreBlocked() throws {
        for source in ["file:../x", "git+https://github.com/a/b", "https://registry.npmjs.org.evil/example.tgz", "https://registry.npmjs.org/example/-/example-1.2.3.tgz?token=abc"] {
            let node = try XCTUnwrap(RaycastStoreDependencyPlan(lockJSON: lock(overrides: ["resolved": source, "hasInstallScript": true, "os": ["darwin"]])).nodes.first)
            XCTAssertNil(node.registryTarball)
            XCTAssertEqual(Set(node.blockers), Set([.unsupportedSource, .installScript, .nativeOrPlatformSpecific]))
            XCTAssertFalse(node.verifiesTarball(Data("fixture".utf8)))
        }
    }
    func testMalformedPathsVersionsAndHashesFailClosed() throws {
        for path in ["../evil", "node_modules/a/../../b", "node_modules/a//node_modules/b", "node_modules/@scope", "node_modules/a/bin"] {
            XCTAssertThrowsError(try RaycastStoreDependencyPlan(lockJSON: lock(path: path)))
        }
        for version in ["^1.2.3", "01.2.3", "1.2", "1.2.3-beta", "file:evil"] {
            XCTAssertThrowsError(try RaycastStoreDependencyPlan(lockJSON: lock(version: version)))
        }
        for integrity in ["sha1-abc", "sha512-AAAA", "sha512-", "sha512-abc sha512-def"] {
            XCTAssertThrowsError(try RaycastStoreDependencyPlan(lockJSON: lock(overrides: ["integrity": integrity])))
        }
        XCTAssertThrowsError(try RaycastStoreDependencyPlan(lockJSON: Data(repeating: 0, count: 2 * 1024 * 1024 + 1)))
        XCTAssertThrowsError(try RaycastStoreDependencyPlan(lockJSON: Data(#"{"lockfileVersion":true,"packages":{"":{}}}"#.utf8)))
    }
    func testUnresolvedRequiredEdgeIsReportedAndOptionalRetained() throws {
        let node = try XCTUnwrap(RaycastStoreDependencyPlan(lockJSON: lock(overrides: ["dependencies": ["missing": "^2.0.0"], "optionalDependencies": ["optional": "1.0.0"]])).nodes.first)
        XCTAssertEqual(node.blockers, [.missingDependency])
        XCTAssertEqual(node.edges.count, 2)
        XCTAssertTrue(node.edges.allSatisfy { $0.targetPath == nil })
    }
    func testScopedPeerResolutionAndMissingParent() throws {
        let packages: [String: Any] = [
            "": [:],
            "node_modules/@scope/host": ["version": "1.0.0"],
            "node_modules/@scope/host/node_modules/plugin": ["version": "1.0.0", "peerDependencies": ["@scope/peer": "^1.0.0"]],
            "node_modules/@scope/host/node_modules/@scope/peer": ["version": "1.0.0"],
            "node_modules/@scope/peer": ["version": "2.0.0"]]
        let data = try JSONSerialization.data(withJSONObject: ["lockfileVersion": 3, "packages": packages])
        let plan = try RaycastStoreDependencyPlan(lockJSON: data)
        let plugin = try XCTUnwrap(plan.nodes.first { $0.name == "plugin" })
        XCTAssertEqual(plugin.edges.first?.targetPath, "node_modules/@scope/host/node_modules/@scope/peer")
        XCTAssertThrowsError(try RaycastStoreDependencyPlan(lockJSON: lock(path: "node_modules/absent/node_modules/example")))
    }
    func testCaseCollisionAndNodeLimitReject() throws {
        // npm names are lowercase; unsafe case variants never become two installs.
        XCTAssertThrowsError(try RaycastStoreDependencyPlan(lockJSON: lock(path: "node_modules/Example")))
        var packages: [String: Any] = ["": [:]]
        for i in 0...4096 { packages["node_modules/p\(i)"] = ["version": "1.0.0"] }
        let data = try JSONSerialization.data(withJSONObject: ["lockfileVersion": 3, "packages": packages])
        XCTAssertThrowsError(try RaycastStoreDependencyPlan(lockJSON: data))
    }

}
