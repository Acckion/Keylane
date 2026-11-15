import Foundation
import XCTest
import CryptoKit
import zlib
@testable import KeylaneCore

final class ConfigurationArchiveTests: XCTestCase {
    func testDefaultExportExcludesPrivateContentAndPermissionSwitches() throws {
        let suite = "Keylane.ConfigurationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("dark", forKey: "appearance")
        defaults.set("synthetic-secret", forKey: "apiKey")
        defaults.set(["clipboard": "private-alias"], forKey: "aliases")
        defaults.set(true, forKey: "hyperkey")
        defaults.set("/private/path", forKey: "applicationRoots")
        let data = try ConfigurationArchive.capture(defaults).data()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("synthetic-secret")); XCTAssertFalse(text.contains("private-alias"))
        XCTAssertFalse(text.contains("hyperkey")); XCTAssertFalse(text.contains("/private/path"))
        XCTAssertEqual(try ConfigurationArchive.decode(data).preferences["appearance"], .string("dark"))
    }
    func testVersionValidationAndLegacy() throws {
        XCTAssertThrowsError(try ConfigurationArchive.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try ConfigurationArchive.decode(Data("{\"format\":\"keylane.configuration\",\"schemaVersion\":999,\"preferences\":{}}".utf8)))
        let legacy = try ConfigurationArchive.decode(Data("{\"schemaVersion\":1,\"preferences\":{\"appearance\":\"dark\",\"hyperkey\":true}}".utf8))
        let plan = try legacy.plan(current: [:], overwrite: true)
        XCTAssertEqual(plan.changes["appearance"] as? String, "dark"); XCTAssertNil(plan.changes["hyperkey"])
        var invalid = ConfigurationArchive(); invalid.preferences["appearance"] = .integer(1)
        XCTAssertThrowsError(try invalid.plan(current: [:], overwrite: true))
    }
    func testMergeConflictAndIdempotency() throws {
        var archive = ConfigurationArchive(); archive.preferences["appearance"] = .string("dark")
        let shortcut = Shortcut(key: 12, modifiers: 2048)
        archive.shortcuts = ["clipboard": shortcut]
        let stored = try JSONEncoder().encode(["launcher": shortcut])
        let current: [String: Any] = ["appearance": "light", "shortcuts": stored, "apiKey": "untouched"]
        let preserve = try archive.plan(current: current, overwrite: false)
        XCTAssertNil(preserve.changes["appearance"]); XCTAssertNil(preserve.changes["shortcuts"])
        XCTAssertEqual(preserve.omitted, 1)
        let replace = try archive.plan(current: current, overwrite: true)
        XCTAssertEqual(replace.changes["appearance"] as? String, "dark")
        var merged = current; replace.changes.forEach { merged[$0.key] = $0.value }
        XCTAssertTrue(try archive.plan(current: merged, overwrite: true).changes.isEmpty)
        XCTAssertEqual(merged["apiKey"] as? String, "untouched")
        archive.shortcuts = ["a": shortcut, "b": shortcut]
        XCTAssertThrowsError(try archive.plan(current: current, overwrite: true))
    }
    func testQuicklinkRoundtripAndDuplicateImport() throws {
        var archive = ConfigurationArchive(); archive.quicklinks = [Quicklink(id: "quicklink:fixture", title: "Synthetic", template: "https://example.com/?q={query}")]
        archive.aliases = ["quicklink:fixture": "fixture"]
        let first = try ConfigurationArchive.decode(archive.data()).plan(current: [:], overwrite: true)
        XCTAssertEqual(first.changes.count, 2)
        XCTAssertTrue(try archive.plan(current: first.changes, overwrite: true).changes.isEmpty)
        let duplicate = archive.quicklinks![0]
        archive.quicklinks?.append(duplicate)
        XCTAssertThrowsError(try archive.plan(current: [:], overwrite: true))
    }
    func testTransactionCancelApplyUndoAndFailedWrite() throws {
        let suite = "Keylane.ConfigurationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let before: [String: Any] = ["appearance": "light", "syntheticToken": "keep"]
        defaults.setPersistentDomain(before, forName: suite)
        try ConfigurationTransaction.stage(changes: ["appearance": "dark"], current: before, directory: directory)
        try ConfigurationTransaction.cancel(directory: directory)
        XCTAssertFalse(try ConfigurationTransaction.finish(defaults: defaults, domain: suite, directory: directory))
        try ConfigurationTransaction.stage(changes: ["appearance": "dark"], current: before, directory: directory)
        XCTAssertThrowsError(try ConfigurationTransaction.finish(defaults: defaults, domain: suite, directory: directory, persist: { value in
            defaults.setPersistentDomain(value, forName: suite); return false
        }))
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?["appearance"] as? String, "light")
        XCTAssertTrue(try ConfigurationTransaction.finish(defaults: defaults, domain: suite, directory: directory))
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?["syntheticToken"] as? String, "keep")
        try ConfigurationTransaction.stageUndo(current: defaults.persistentDomain(forName: suite)!, directory: directory)
        XCTAssertTrue(try ConfigurationTransaction.finish(defaults: defaults, domain: suite, directory: directory))
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?["appearance"] as? String, "light")
        let receipt = try Data(contentsOf: directory.appendingPathComponent("last-import.plist"))
        XCTAssertFalse(String(decoding: receipt, as: UTF8.self).contains("syntheticToken"))
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("last-import.plist").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testChangedConfigurationStopsPendingImport() throws {
        let suite = "Keylane.ConfigurationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try ConfigurationTransaction.stage(changes: ["appearance": "dark"], current: ["appearance": "light"], directory: directory)
        defaults.setPersistentDomain(["appearance": "system"], forName: suite)
        XCTAssertThrowsError(try ConfigurationTransaction.finish(defaults: defaults, domain: suite, directory: directory))
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?["appearance"] as? String, "system")
    }
    func testInterruptedCompletedImportAndAbsentKeyUndo() throws {
        let suite = "Keylane.ConfigurationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try ConfigurationTransaction.stage(changes: ["aliases": ["clipboard": "fixture"]], current: [:], directory: directory)
        // Simulate a crash after domain submission but before removing pending.plist.
        defaults.setPersistentDomain(["aliases": ["clipboard": "fixture"]], forName: suite)
        XCTAssertTrue(try ConfigurationTransaction.finish(defaults: defaults, domain: suite, directory: directory, persist: { _ in XCTFail("must not rewrite completed transaction"); return false }))
        try ConfigurationTransaction.stageUndo(current: defaults.persistentDomain(forName: suite)!, directory: directory)
        XCTAssertTrue(try ConfigurationTransaction.finish(defaults: defaults, domain: suite, directory: directory))
        XCTAssertNil(defaults.persistentDomain(forName: suite)?["aliases"])
    }
    func testDuplicateAliasesAreSkipped() throws {
        var archive = ConfigurationArchive(); archive.aliases = ["new": "FIXTURE"]
        let plan = try archive.plan(current: ["aliases": ["old": "fixture"]], overwrite: true)
        XCTAssertEqual(plan.omitted, 1); XCTAssertTrue(plan.changes.isEmpty)
    }
    func testRaycastCommandStatePatchPreservesOtherDisabledCommands() throws {
        var archive = ConfigurationArchive(); archive.commandEnabled = ["clipboard": false]
        let plan = try archive.plan(current: ["disabledLauncherCommands": ["unrelated"]], overwrite: true)
        XCTAssertEqual(plan.changes["disabledLauncherCommands"] as? [String], ["clipboard", "unrelated"])
        archive.commandEnabled = ["clipboard": true]
        let reenable = try archive.plan(current: ["disabledLauncherCommands": ["clipboard", "unrelated"]], overwrite: true)
        XCTAssertEqual(reenable.changes["disabledLauncherCommands"] as? [String], ["unrelated"])
    }
    func testScryptAgainstRFC7914AndIndependentPythonVector() throws {
        let rfc = try RaycastScrypt.derive(password: Data(), salt: Data(), n: 16, r: 1, p: 1, length: 64)
        XCTAssertEqual(hex(rfc), "77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906")
        let key = try RaycastScrypt.derive(password: Data("synthetic-password".utf8), salt: Data(0..<16))
        XCTAssertEqual(hex(key), "2a3751c04883dc6f802f4c3245f9098336974987547724ad0034d15e453e5231")
    }
    func testModernAuthenticatedContainerAndWrongPassword() throws {
        let payload: [String: Any] = ["settings": ["schemaVersion": 1, "commands": [["id": "builtin_command_clipboardHistory", "alias": "fixture"]]],
                                    "quicklinks": ["schemaVersion": 1, "quicklinks": [["name": "Synthetic", "url": "https://example.com", "id": "fixture"]]],
                                    "nodeExtensions": ["schemaVersion": 1, "extensions": [], "storedValues": ["token": "synthetic-do-not-import"]]]
        let fixture = try container(payload)
        let preview = try RaycastConfiguration.decode(fixture, password: "synthetic-password")
        XCTAssertEqual(preview.archive.quicklinks?.count, 1); XCTAssertEqual(preview.archive.aliases?["clipboard"], "fixture")
        XCTAssertFalse(String(decoding: try preview.archive.data(), as: UTF8.self).contains("synthetic-do-not-import"))
        XCTAssertThrowsError(try RaycastConfiguration.decode(fixture, password: "wrong"))
        var tampered = fixture; tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try RaycastConfiguration.decode(tampered, password: "synthetic-password"))
        XCTAssertThrowsError(try RaycastConfiguration.decode(fixture.prefix(20), password: "synthetic-password"))
        let plan = try preview.archive.plan(current: [:], overwrite: true)
        XCTAssertTrue(try preview.archive.plan(current: plan.changes, overwrite: true).changes.isEmpty)
    }
    func testCompressionBoundsAndQuicklinkJSON() throws {
        XCTAssertThrowsError(try RaycastConfiguration.gunzip(gzip(Data(repeating: 65, count: 10000)), maximumBytes: 100))
        XCTAssertThrowsError(try RaycastConfiguration.decode(Data()))
        let json = Data("[{\"name\":\"Fixture\",\"link\":\"https://example.com\"}]".utf8)
        XCTAssertEqual(try RaycastConfiguration.decode(json).archive.quicklinks?.count, 1)
    }
    func testModernLocalHotkeysNeverBecomeGlobal() throws {
        let commands: [[String: Any]] = [
            ["id": "builtin_command_clipboardHistory", "macosHotkey": ["locality": "local", "kind": ["shortcut": ["modifiers": ["option"], "key": 12]]]],
            ["id": "builtin_command_searchEmoji", "macosHotkey": ["locality": "global", "kind": ["shortcut": ["modifiers": ["option"], "key": 13]]]]
        ]
        let data = try JSONSerialization.data(withJSONObject: ["settings": ["schemaVersion": 1, "commands": commands]])
        let preview = try RaycastConfiguration.decode(data)
        XCTAssertNil(preview.archive.shortcuts?["clipboard"])
        XCTAssertEqual(preview.archive.shortcuts?["emoji-symbols"], Shortcut(key: 13, modifiers: 2048))
    }
    func testLegacyCBCGoldenAndUnknownContainers() throws {
        // Generated by /usr/bin/openssl with a synthetic payload, no production data.
        let encrypted = Data(base64Encoded: "kmYHn9EsVHiPZ5NoKKqsY4SqLd1ZzHRb/9ELtyfvxXc4VCH3KFNfbfwNG8dPhcxxn8kZarVwZhtyXw8wWeFgol5J7bTsHOPC15B3SdiaUoGwMXdnoST1i/YACus9iqU4GlwbILcIX/OAazzZQn4vm+LXuCAcgWhNxcJXvi7EY7B1MRtDoCXImwLoUTRTS7PFJi0wQehcNl2MbgWWIFpR8BNu2ZSqUzPUxXMqSLdvxYetWxLm3fu0fr/e/R4raGh1")!
        let preview = try RaycastConfiguration.decode(encrypted, password: "synthetic-password")
        XCTAssertEqual(preview.archive.shortcuts?["launcher"], .launcher)
        XCTAssertEqual(preview.archive.quicklinks?.count, 1)
        XCTAssertThrowsError(try RaycastConfiguration.decode(Data("RAYCFG4\ninvalid".utf8), password: "synthetic-password"))
        var excessiveHeader = Data("RAYCFG3\n".utf8)
        excessiveHeader.append(contentsOf: [255, 255, 255, 127]); excessiveHeader.append(Data(repeating: 0, count: 32))
        XCTAssertThrowsError(try RaycastConfiguration.decode(excessiveHeader, password: "synthetic-password"))
    }
    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    private func container(_ payload: [String: Any]) throws -> Data {
        let iv = Data(16..<32), salt = Data(0..<16)
        let header = try gzip(JSONSerialization.data(withJSONObject: ["schemaVersion": 3, "iv": hex(iv), "salt": hex(salt)]))
        // Golden key generated independently by Python hashlib.scrypt, not our KDF.
        let keyBytes: [UInt8] = [0x2a,0x37,0x51,0xc0,0x48,0x83,0xdc,0x6f,0x80,0x2f,0x4c,0x32,0x45,0xf9,0x09,0x83,0x36,0x97,0x49,0x87,0x54,0x77,0x24,0xad,0x00,0x34,0xd1,0x5e,0x45,0x3e,0x52,0x31]
        let box = try AES.GCM.seal(gzip(JSONSerialization.data(withJSONObject: payload)), using: SymmetricKey(data: Data(keyBytes)), nonce: AES.GCM.Nonce(data: iv))
        var result = Data("RAYCFG3\n".utf8), length = UInt32(header.count).littleEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(header); result.append(box.ciphertext); result.append(box.tag)
        return result
    }
    private func gzip(_ input: Data) throws -> Data {
        var stream = z_stream()
        XCTAssertEqual(deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)), Z_OK)
        defer { deflateEnd(&stream) }
        var out = Data(count: input.count + 1024)
        let capacity = out.count
        let written = input.withUnsafeBytes { src in out.withUnsafeMutableBytes { dst -> Int in
            stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress); stream.avail_in = uInt(input.count)
            stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = uInt(capacity)
            XCTAssertEqual(deflate(&stream, Z_FINISH), Z_STREAM_END)
            return capacity - Int(stream.avail_out)
        } }
        out.count = written; return out
    }
}
