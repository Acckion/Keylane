import Foundation
import XCTest
@testable import KeylaneCore

final class ScriptCommandTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("Keylane scripts \(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func write(_ name: String, _ body: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func annotated(_ title: String, _ body: String) -> String {
        "# @raycast.schemaVersion 1\n# @raycast.title \(title)\n# @raycast.mode silent\n" + body
    }

    func testDiscoveryDoesNotExecuteAndSkipsSymlinks() throws {
        let original = try write("测试.sh", annotated("测试", #"touch "${0%/*}/ran""#))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("copy.sh"), withDestinationURL: original)
        _ = try write(".hidden.sh", annotated("Hidden", "exit 0"))
        _ = try write("readme.txt", annotated("Readme", "exit 0"))
        let catalog = ScriptCommand.discover(in: [folder.path, folder.path])
        XCTAssertEqual(catalog.commands.map(\.url), [original])
        XCTAssertTrue(catalog.unavailable.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("ran").path))
    }

    func testDiscoveryRequiresValidMetadataAndSkipsDependencies() throws {
        let packages = folder.appendingPathComponent("venv/lib/site-packages", isDirectory: true)
        let node = folder.appendingPathComponent("node_modules", isDirectory: true)
        for directory in [packages, node] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try annotated("Dependency", "exit()").write(to: packages.appendingPathComponent("__about__.py"), atomically: true, encoding: .utf8)
        try annotated("Dependency", "console.log('a')").write(to: node.appendingPathComponent("abc.js"), atomically: true, encoding: .utf8)
        _ = try write("_abc.py", "pass")
        _ = try write("actual.py", "print('hello')")
        _ = try write("_command.py", "# @raycast.title My Command\n# @raycast.schemaVersion 1\n# @raycast.mode silent\n")
        _ = try write("plain.sh", "exit 0")
        _ = try write("missing-mode.sh", "# @raycast.schemaVersion 1\n# @raycast.title Incomplete")
        _ = try write("unknown-mode.sh", annotated("Bad mode", "").replacingOccurrences(of: "silent", with: "unknown"))
        _ = try write("future.sh", annotated("Future", "").replacingOccurrences(of: "schemaVersion 1", with: "schemaVersion 2"))
        _ = try write("example.template.sh", annotated("Template", "exit 0"))
        let commands = ScriptCommand.discover(in: [folder.path]).commands
        XCTAssertEqual(commands.map(\.title), ["My Command"])
    }

    func testRootFileResultsDeferToScriptDiscoveryWithinConfiguredFolders() throws {
        let compiled = try write("未命名.scpt", "compiled AppleScript fixture")
        let plain = try write("helper.sh", "exit 0")
        let declared = try write("command.sh", annotated("Command", "exit 0"))
        let document = try write("readme.txt", "hello")
        let neighboringScript = URL(fileURLWithPath: folder.path + "-other/helper.sh")
        let roots = [folder.path]

        for file in [compiled, plain, declared] {
            XCTAssertTrue(ScriptCommand.reservesLauncherResult(file, in: roots))
        }
        for file in [document, neighboringScript] {
            XCTAssertFalse(ScriptCommand.reservesLauncherResult(file, in: roots))
        }
        XCTAssertEqual(ScriptCommand.discover(in: roots).commands.map(\.url), [declared])
    }

    func testOverlappingRootsPreserveExplicitHiddenDirectoryAndCanCancel() throws {
        let nested = folder.appendingPathComponent("nested", isDirectory: true)
        let hidden = nested.appendingPathComponent(".hidden", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try annotated("visible", "exit 0").write(to: nested.appendingPathComponent("visible.sh"), atomically: true, encoding: .utf8)
        try annotated("explicit", "exit 0").write(to: hidden.appendingPathComponent("explicit.sh"), atomically: true, encoding: .utf8)

        let roots = [hidden.path, nested.path, folder.path]
        XCTAssertEqual(ScriptCommand.discover(in: roots).commands.map(\.title), ["explicit", "visible"])

        func traversalChecks(_ paths: [String]) -> Int {
            var count = 0
            let catalog = ScriptCommand.discover(in: paths) { count += 1; return false }
            XCTAssertEqual(catalog.commands.map(\.title), ["visible"])
            return count
        }
        XCTAssertEqual(traversalChecks([folder.path, nested.path]), traversalChecks([folder.path]))

        var checks = 0
        let cancelled = ScriptCommand.discover(in: roots) {
            checks += 1
            return checks >= 2
        }
        XCTAssertEqual(checks, 2)
        XCTAssertTrue(cancelled.commands.isEmpty)
    }

    func testCreateTemplateDoesNotOverwriteFiles() throws {
        let scriptURL = folder.appendingPathComponent("新建脚本.sh")
        try ScriptCommand.createTemplate(at: scriptURL)
        let original = try Data(contentsOf: scriptURL)
        XCTAssertThrowsError(try ScriptCommand.createTemplate(at: scriptURL))
        XCTAssertEqual(try Data(contentsOf: scriptURL), original)
        let unsupported = folder.appendingPathComponent("unsupported.txt")
        XCTAssertThrowsError(try ScriptCommand.createTemplate(at: unsupported))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unsupported.path))

        let script = try XCTUnwrap(ScriptCommand.discover(in: [folder.path]).commands.first)
        let result = try ScriptRunner.run(script, arguments: [], directory: folder, timeout: 5, isCancelled: { false })
        XCTAssertEqual(result.status, .exited(0))
        XCTAssertEqual(result.output, "Hello from Keylane\n")
    }

    func testRaycastMetadataRoundTripAndTypedArguments() throws {
        let metadata = try XCTUnwrap(ScriptMetadata.parse("""
            # @raycast.schemaVersion 1
            # @raycast.title 搜索资料
            # @raycast.mode fullOutput
            # @raycast.packageName 工具
            # @raycast.needsConfirmation true
            # @raycast.currentDirectoryPath work
            # @raycast.argument1 {"placeholder":"关键词","percentEncoded":true}
            # @raycast.argument2 {"type":"password","placeholder":"密码","optional":true}
            # @raycast.argument3 {"type":"dropdown","placeholder":"范围","data":[{"title":"全部","value":"all"}]}
            """))
        XCTAssertEqual(metadata.arguments.map(\.kind), [.text, .password, .dropdown])
        XCTAssertEqual(try metadata.arguments[0].value("a +"), "a%20%2B")
        XCTAssertThrowsError(try metadata.arguments[0].value(""))
        XCTAssertEqual(try metadata.arguments[1].value(""), "")
        XCTAssertThrowsError(try metadata.arguments[2].value("invalid"))
        XCTAssertEqual(try metadata.arguments[2].value("all"), "all")

        let url = folder.appendingPathComponent("generated.bash")
        try ScriptTemplate.bash.create(at: url, metadata: metadata)
        XCTAssertThrowsError(try ScriptTemplate.bash.create(at: url, metadata: metadata))
        let command = try XCTUnwrap(ScriptCommand.discover(in: [folder.path]).commands.first)
        XCTAssertEqual(command.metadata, metadata)
        XCTAssertEqual(command.workingDirectory.lastPathComponent, "work")
        let result = try ScriptRunner.run(command, arguments: [], directory: folder, timeout: 5, isCancelled: { false })
        XCTAssertEqual(result.status, .exited(0))
        XCTAssertEqual(result.standardOutput, "Hello from Keylane\n")
    }

    func testKeylaneMetadataTakesPrecedenceOverRaycastMetadata() throws {
        let metadata = try XCTUnwrap(ScriptMetadata.parse("""
            # @raycast.schemaVersion 1
            # @keylane.title Native title
            # @raycast.title Compatibility title
            # @raycast.mode silent
            # @keylane.mode compact
            # @raycast.argument1 {"placeholder":"Input"}
            """))
        XCTAssertEqual(metadata.title, "Native title")
        XCTAssertEqual(metadata.mode, .compact)
        XCTAssertEqual(metadata.arguments.first?.placeholder, "Input")

        let header = try metadata.header(comment: "#")
        XCTAssertTrue(header.contains("# @keylane.schemaVersion 1"))
        XCTAssertTrue(header.contains("# @keylane.argument1 "))
        XCTAssertFalse(header.contains("@raycast."))
        XCTAssertEqual(try ScriptMetadata.parse(header), metadata)
    }

    func testAllFormTemplatesAreDiscoverable() throws {
        for template in ScriptTemplate.allCases {
            let url = folder.appendingPathComponent(template.rawValue).appendingPathExtension(template.fileExtension)
            var metadata = ScriptMetadata()
            metadata.title = template.title
            try template.create(at: url, metadata: metadata)
        }
        let commands = ScriptCommand.discover(in: [folder.path]).commands
        XCTAssertEqual(Set(commands.map(\.title)), Set(ScriptTemplate.allCases.map(\.title)))

        let appleScript = try XCTUnwrap(commands.first { $0.title == ScriptTemplate.appleScript.title })
        let result = try ScriptRunner.run(appleScript, arguments: [], directory: folder, timeout: 10, isCancelled: { false })
        XCTAssertEqual(result.status, .exited(0))
        XCTAssertEqual(result.standardOutput, "Hello from Keylane\n")
    }

    func testInlineIntervalsAndUnsupportedPlatform() throws {
        var metadata = ScriptMetadata()
        metadata.mode = .inline
        XCTAssertEqual(metadata.effectiveMode, .compact)
        metadata.refreshTime = "1s"
        XCTAssertEqual(metadata.refreshInterval, 10)
        XCTAssertEqual(metadata.effectiveMode, .inline)
        metadata.refreshTime = "2h"
        XCTAssertEqual(metadata.refreshInterval, 7200)
        _ = try write("windows.sh", """
            # @raycast.schemaVersion 1
            # @raycast.title Windows only
            # @raycast.mode silent
            # @raycast.platform windows
            """)
        XCTAssertTrue(ScriptCommand.discover(in: [folder.path]).commands.isEmpty)
    }

    func testArgumentsWorkingDirectoryAndFailureOutput() throws {
        _ = try write("test.sh", annotated("Fixture", """
            printf '%s\\n' "$PWD" "$#" "$1" "$2"
            printf '%s\\n' 'stderr output' >&2
            exit 7
            """))
        let script = try XCTUnwrap(ScriptCommand.discover(in: [folder.path]).commands.first)
        let args = try ArgumentParser.parse(#""中文 路径" '$(touch unintended)'"#)
        let result = try ScriptRunner.run(script, arguments: args, directory: folder, timeout: 5, isCancelled: { false })
        XCTAssertEqual(result.status, .exited(7))
        let lines = result.output.split(separator: "\n", maxSplits: 1)
        let outputDirectory = URL(fileURLWithPath: String(try XCTUnwrap(lines.first)), isDirectory: true)
        XCTAssertEqual(outputDirectory.resolvingSymlinksInPath(), folder.resolvingSymlinksInPath())
        XCTAssertEqual(lines.last, "2\n中文 路径\n$(touch unintended)\nstderr output\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("unintended").path))
    }

    func testCombinedOutputKeepsWriteOrder() throws {
        _ = try write("ordered.sh", annotated("Fixture", """
            printf 'first\\n' >&2
            printf 'second\\n'
            printf 'third\\n' >&2
            printf 'final diagnostic\\n'
            exit 7
            """))
        let script = try XCTUnwrap(ScriptCommand.discover(in: [folder.path]).commands.first)
        let result = try ScriptRunner.run(script, arguments: [], directory: folder, timeout: 5, isCancelled: { false })
        XCTAssertEqual(result.status, .exited(7))
        XCTAssertEqual(result.output, "first\nsecond\nthird\nfinal diagnostic\n")
    }

    func testInlineOutputSeparatesStatusAndDiagnostics() throws {
        let url = try write("inline.sh", """
            # @raycast.schemaVersion 1
            # @raycast.title Inline status
            # @raycast.mode inline
            # @raycast.refreshTime 1m
            printf 'warning\\n' >&2
            printf 'status\\n'
            if [ "$1" = fail ]; then
                printf 'final diagnostic\\n' >&2
                exit 7
            fi
            """)
        let script = try ScriptCommand.read(url.resolvingSymlinksInPath())
        let success = try ScriptRunner.run(script, arguments: [], directory: folder, timeout: 5, isCancelled: { false })
        XCTAssertEqual(success.standardOutput, "status\n")
        let failure = try ScriptRunner.run(script, arguments: ["fail"], directory: folder, timeout: 5, isCancelled: { false })
        XCTAssertEqual(failure.status, .exited(7))
        XCTAssertEqual(failure.output, "warning\nfinal diagnostic\n")
    }

    func testTimeoutStopsChildAndCancellationReturnsDistinctStatus() throws {
        _ = try write("slow.sh", annotated("Fixture", """
            (/bin/sleep 1; /usr/bin/touch escaped) &
            wait
            """))
        let script = try XCTUnwrap(ScriptCommand.discover(in: [folder.path]).commands.first)
        let start = ProcessInfo.processInfo.systemUptime
        let timedOut = try ScriptRunner.run(script, arguments: [], directory: folder, timeout: 0.1, isCancelled: { false })
        XCTAssertEqual(timedOut.status, .timedOut)
        let cancelAt = ProcessInfo.processInfo.systemUptime + 0.1
        let cancelled = try ScriptRunner.run(script, arguments: [], directory: folder, timeout: 4,
                                             isCancelled: { ProcessInfo.processInfo.systemUptime >= cancelAt })
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("escaped").path))
    }

    func testQuietScriptWithClosedOutputDoesNotBusyPoll() throws {
        let url = try write("quiet.sh", annotated("Fixture", "exec 1>&- 2>&-\n/bin/sleep 0.45\n"))
        let script = try ScriptCommand.read(url)
        var checks = 0
        let result = try ScriptRunner.run(script, arguments: [], directory: folder, timeout: 5, isCancelled: {
            checks += 1
            return false
        })
        XCTAssertEqual(result.status, .exited(0))
        XCTAssertLessThanOrEqual(checks, 9)
    }

    func testTruncatedOutputKeepsCompleteUTF8Scalars() throws {
        let url = try write("unicode.sh", annotated("Fixture", """
            /usr/bin/head -c 262143 /dev/zero | /usr/bin/tr '\\000' x
            printf '%s' '中'
            """))
        let script = try ScriptCommand.read(url)
        let result = try ScriptRunner.run(script, arguments: [], directory: folder, timeout: 5, isCancelled: { false })
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.output.utf8.count, 262143)
        XCTAssertEqual(result.output.last, "x")
    }

    func testLargeOutputIsBoundedWithoutBlocking() throws {
        _ = try write("large.sh", annotated("Fixture", "/usr/bin/head -c 300000 /dev/zero | /usr/bin/tr '\\000' x"))
        let script = try XCTUnwrap(ScriptCommand.discover(in: [folder.path]).commands.first)
        let result = try ScriptRunner.run(script, arguments: [], directory: folder, timeout: 5, isCancelled: { false })
        XCTAssertEqual(result.status, .exited(0))
        XCTAssertEqual(result.output.utf8.count, 256 * 1024)
        XCTAssertTrue(result.truncated)
    }
}
