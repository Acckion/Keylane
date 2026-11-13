import Darwin
import Foundation
import XCTest
@testable import KeylaneCore

final class RaycastExtensionManifestTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func manifest(_ root: URL, commands: [[String: Any]], extra: [String: Any] = [:]) throws {
        let object: [String: Any] = [
            "author": "local-author", "name": "local-extension", "title": "本地扩展",
            "commands": commands,
        ].merging(extra) { _, value in value }
        try JSONSerialization.data(withJSONObject: object).write(to: root.appendingPathComponent("package.json"))
    }

    private func command(_ name: String, mode: String = "no-view") -> [String: Any] {
        ["name": name, "title": "Command", "mode": mode]
    }

    func testEnumeratesModesAndDoesNotExecuteCode() throws {
        try fixture { root in
            let marker = root.appendingPathComponent("executed")
            let commandSource = """
                require("fs").writeFileSync(\(String(reflecting: marker.path)), "ran");
                """
            for file in ["run.ts", "detail.tsx", "menu.jsx"] {
                try Data(commandSource.utf8).write(to: root.appendingPathComponent("src/\(file)"))
            }
            var run = command("run")
            run["arguments"] = [["name": "count", "type": "text", "required": true]]
            run["preferences"] = [[
                "name": "mode", "type": "dropdown", "title": "Mode", "default": "copy",
                "data": [["title": "Copy", "value": "copy"], ["title": "Paste", "value": "paste"]],
            ]]
            run["disabledByDefault"] = true
            var menu = command("menu", mode: "menu-bar")
            menu["interval"] = "10m"
            try manifest(root, commands: [run, command("detail", mode: "view"), menu],
                         extra: ["scripts": ["postinstall": "touch \(marker.path)"],
                                 "platforms": ["macOS"],
                                 "preferences": [["name": "upperCase", "type": "checkbox", "default": false]]])
            let result = try RaycastExtensionManifest.read(directory: root)
            XCTAssertEqual(result.title, "本地扩展")
            XCTAssertEqual(result.commands.map(\.mode), [.noView, .view, .menuBar])
            XCTAssertEqual(result.platforms, ["macOS"])
            XCTAssertEqual(result.commands[2].backgroundIntervalSeconds, 600)
            XCTAssertEqual(result.commands[0].id, "extension:raycast:local-author/local-extension/run")
            XCTAssertEqual(result.commands[0].entry, "src/run.ts")
            XCTAssertEqual(result.commands[0].arguments.first?.name, "count")
            let mode = try XCTUnwrap(result.commands[0].preferences.first)
            XCTAssertEqual(mode.title, "Mode")
            XCTAssertEqual(mode.defaultValue, .string("copy"))
            XCTAssertTrue(mode.accepts(.string("paste")))
            XCTAssertFalse(mode.accepts(.string("invalid")))
            XCTAssertEqual(result.preferences.first?.defaultValue, .bool(false))
            XCTAssertTrue(result.commands[0].disabledByDefault)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testRejectsInvalidCommandEntries() throws {
        try fixture { root in
            try manifest(root, commands: [command("../outside")])
            XCTAssertThrowsError(try RaycastExtensionManifest.read(directory: root)) {
                guard case .invalidIdentifier = $0 as? RaycastExtensionManifest.InvalidSource else {
                    return XCTFail("Unexpected error: \($0)")
                }
            }
            try manifest(root, commands: [command("run", mode: "unknown")])
            XCTAssertThrowsError(try RaycastExtensionManifest.read(directory: root)) {
                guard case .unsupportedMode = $0 as? RaycastExtensionManifest.InvalidSource else {
                    return XCTFail("Unexpected error: \($0)")
                }
            }
            try manifest(root, commands: [command("run")])
            XCTAssertThrowsError(try RaycastExtensionManifest.read(directory: root)) {
                guard case .missingEntry = $0 as? RaycastExtensionManifest.InvalidSource else {
                    return XCTFail("Unexpected error: \($0)")
                }
            }
            try Data().write(to: root.appendingPathComponent("src/run.ts"))
            try Data().write(to: root.appendingPathComponent("src/run.js"))
            XCTAssertThrowsError(try RaycastExtensionManifest.read(directory: root)) {
                guard case .ambiguousEntry = $0 as? RaycastExtensionManifest.InvalidSource else {
                    return XCTFail("Unexpected error: \($0)")
                }
            }
        }
    }

    func testRejectsEscapingSymlinkAndFIFO() throws {
        try fixture { root in
            try manifest(root, commands: [command("run")])
            let link = root.appendingPathComponent("src/run.ts")
            let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            try Data().write(to: outside)
            defer { try? FileManager.default.removeItem(at: outside) }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            XCTAssertThrowsError(try RaycastExtensionManifest.read(directory: root)) {
                guard case .unsafePath = $0 as? RaycastExtensionManifest.InvalidSource else {
                    return XCTFail("Unexpected error: \($0)")
                }
            }

            let package = root.appendingPathComponent("package.json")
            try FileManager.default.removeItem(at: package)
            XCTAssertEqual(mkfifo(package.path, 0o600), 0)
            XCTAssertThrowsError(try RaycastExtensionManifest.read(directory: root)) {
                guard case .invalidManifestFile = $0 as? RaycastExtensionManifest.InvalidSource else {
                    return XCTFail("Unexpected error: \($0)")
                }
            }
        }
    }
}
