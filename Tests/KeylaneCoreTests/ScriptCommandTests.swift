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

    func testDiscoveryDoesNotExecuteAndSkipsSymlinks() throws {
        let original = try write("测试.sh", #"touch "${0%/*}/ran""#)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("copy.sh"), withDestinationURL: original)
        _ = try write(".hidden.sh", "exit 0")
        _ = try write("readme.txt", "exit 0")
        let catalog = ScriptCommand.discover(in: [folder.path, folder.path])
        XCTAssertEqual(catalog.commands.map(\.url), [original])
        XCTAssertTrue(catalog.unavailable.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("ran").path))
    }

    func testArgumentsWorkingDirectoryAndFailureOutput() throws {
        _ = try write("test.sh", """
            printf '%s\\n' "$PWD" "$#" "$1" "$2"
            printf '%s\\n' 'stderr output' >&2
            exit 7
            """)
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

    func testTimeoutStopsChildAndCancellationReturnsDistinctStatus() throws {
        _ = try write("slow.sh", """
            (/bin/sleep 1; /usr/bin/touch escaped) &
            wait
            """)
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

    func testLargeOutputIsBoundedWithoutBlocking() throws {
        _ = try write("large.sh", "/usr/bin/head -c 300000 /dev/zero | /usr/bin/tr '\\000' x")
        let script = try XCTUnwrap(ScriptCommand.discover(in: [folder.path]).commands.first)
        let result = try ScriptRunner.run(script, arguments: [], directory: folder, timeout: 5, isCancelled: { false })
        XCTAssertEqual(result.status, .exited(0))
        XCTAssertEqual(result.output.utf8.count, 256 * 1024)
        XCTAssertTrue(result.truncated)
    }
}
