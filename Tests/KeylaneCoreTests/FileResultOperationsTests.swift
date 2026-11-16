import Foundation
import XCTest
@testable import KeylaneCore

final class FileResultOperationsTests: XCTestCase {
    func testThreeConsecutiveCopiesKeepExtensionAndContents() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("报告 [预算].txt")
        let contents = Data("source contents".utf8)
        try contents.write(to: source)

        let target = try FileResultOperations.target(for: source)
        let copies = try (1...3).map { _ in try FileResultOperations.duplicate(target) }

        XCTAssertEqual(copies.map(\.lastPathComponent), ["报告 [预算] 副本.txt", "报告 [预算] 副本 2.txt", "报告 [预算] 副本 3.txt"])
        for copy in copies {
            XCTAssertEqual(try Data(contentsOf: copy), contents)
        }
        XCTAssertEqual(try Data(contentsOf: source), contents)
    }

    func testCopiesWithoutExtensionSkipOccupiedNumberWithoutOverwriting() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("README")
        let existing = directory.appendingPathComponent("README 副本 2")
        let sourceContents = Data("source contents".utf8)
        let existingContents = Data("keep this copy".utf8)
        try sourceContents.write(to: source)
        try existingContents.write(to: existing)

        let target = try FileResultOperations.target(for: source)
        let copies = try (1...3).map { _ in try FileResultOperations.duplicate(target) }

        XCTAssertEqual(copies.map(\.lastPathComponent), ["README 副本", "README 副本 3", "README 副本 4"])
        for copy in copies {
            XCTAssertEqual(try Data(contentsOf: copy), sourceContents)
        }
        XCTAssertEqual(try Data(contentsOf: source), sourceContents)
        XCTAssertEqual(try Data(contentsOf: existing), existingContents)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
