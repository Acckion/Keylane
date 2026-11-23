import XCTest
import SQLite3
@testable import KeylaneCore

final class FileIndexTests: XCTestCase {
    func testRecoveryPointPersistenceInvalidationRollbackAndClear() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite")
        let db = try FileSearchIndex(url: url)
        XCTAssertNil(try db.recoveryPoint(), "Existing indexes without an event cursor require recovery")
        let point = FileSearchIndex.RecoveryPoint(eventID: UInt64.max - 1, configuration: "授权目录与规则")
        try db.saveRecoveryPoint(point)
        XCTAssertEqual(try FileSearchIndex(url: url).recoveryPoint(), point)
        enum Interrupted: Error { case fixture }
        XCTAssertThrowsError(try db.transaction {
            try db.invalidateRecoveryPoint()
            throw Interrupted.fixture
        })
        XCTAssertEqual(try db.recoveryPoint(), point)
        try db.invalidateRecoveryPoint()
        XCTAssertNil(try db.recoveryPoint())
        try db.saveRecoveryPoint(point)
        try db.clear()
        XCTAssertNil(try FileSearchIndex(url: url).recoveryPoint())
    }

    func testPartialRecoveryKeepsUnreadableSubtreesAndPrunesOtherStaleRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try FileSearchIndex(url: directory.appendingPathComponent("index.sqlite"))
        for i in 0..<1100 {
            let path = i % 2 == 0 ? "/fixture/locked/item-\(i)" : "/fixture/removed-\(i)"
            try db.put(.init(path: path, name: "item", volume: "/", modified: 1, directory: false, symlink: false), root: "/fixture", epoch: "old")
        }
        try db.put(.init(path: "/fixture/locked-sibling", name: "sibling", volume: "/", modified: 1, directory: false, symlink: false), root: "/fixture", epoch: "old")
        try db.removeUnseen(root: "/fixture", epoch: "new", preserving: ["/fixture/locked"])
        XCTAssertEqual(try db.stats().entries, 550)
        let point = FileSearchIndex.RecoveryPoint(eventID: 42, configuration: "fixture", retryPaths: ["/fixture/locked"])
        try db.saveRecoveryPoint(point)
        XCTAssertEqual(try db.recoveryPoint(), point)
        try db.removeUnseen(root: "/fixture", subtree: "/fixture/locked", epoch: "new", preserving: [])
        XCTAssertEqual(try db.stats().entries, 0)
        let legacy = Data(#"{"eventID":42,"configuration":"fixture"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(FileSearchIndex.RecoveryPoint.self, from: legacy).retryPaths, [])
    }

    func testStatisticsStayConsistentAcrossConnectionsAndRollback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite")
        let writer = try FileSearchIndex(url: url)
        let reader = try FileSearchIndex(url: url)
        func put(_ name: String, directory: Bool = false, symlink: Bool = false) throws {
            try writer.put(.init(path: "/fixture/" + name, name: name, volume: "/", modified: 1,
                                 directory: directory, symlink: symlink), root: "/fixture", epoch: "first")
        }
        try put("text")
        try put("folder", directory: true)
        try put("link", symlink: true)
        let initial = try reader.stats()
        XCTAssertEqual([initial.entries, initial.files, initial.directories, initial.symlinks], [3, 1, 1, 1])
        try put("text", directory: true)
        let changed = try reader.stats()
        XCTAssertEqual([changed.entries, changed.files, changed.directories, changed.symlinks], [3, 0, 2, 1])
        enum Failure: Error { case rollback }
        XCTAssertThrowsError(try writer.transaction {
            try put("rolled-back")
            try writer.removeScope("/fixture")
            throw Failure.rollback
        })
        XCTAssertEqual(try reader.stats().entries, 3)
        try writer.removeUnseen(root: "/fixture", subtree: "/fixture/folder", epoch: "next")
        XCTAssertEqual(try reader.stats().directories, 1)
        try writer.clear()
        XCTAssertEqual(try reader.stats().entries, 0)
    }

    func testStatisticsInitializeExistingDatabaseOnceAndTrackOlderWriter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite")
        var index: FileSearchIndex? = try FileSearchIndex(url: url)
        try index!.put(.init(path: "/fixture/retained", name: "retained", volume: "/", modified: 1,
                             directory: false, symlink: false), root: "/fixture", epoch: "old")
        index = nil
        var legacy: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &legacy), SQLITE_OK)
        defer { sqlite3_close(legacy) }
        // Recreate the pre-counter state without changing the file records.
        XCTAssertEqual(sqlite3_exec(legacy, "DROP TRIGGER file_counts_insert; DROP TRIGGER file_counts_delete; DROP TRIGGER file_counts_update; DROP TABLE file_counts", nil, nil, nil), SQLITE_OK)
        let migrated = try FileSearchIndex(url: url)
        XCTAssertEqual(try migrated.stats().entries, 1)
        XCTAssertEqual(sqlite3_exec(legacy, "DELETE FROM files", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try migrated.stats().entries, 0)
        XCTAssertEqual(try FileSearchIndex(url: url).stats().entries, 0)
    }

    func testSubtreeCleanupPreservesEpochOwnerAndSiblingBoundaries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try FileSearchIndex(url: directory.appendingPathComponent("index.sqlite"))
        let root = "/fixture"
        let rows = [
            ("/fixture/target", root, "old"),
            ("/fixture/target/removed.txt", root, "old"),
            ("/fixture/target/current.txt", root, "current"),
            ("/fixture/target/other-owner.txt", "/other", "old"),
            ("/fixture/target-extra.txt", root, "old"),
            ("/fixture/target0/sibling.txt", root, "old")
        ]
        for (path, owner, epoch) in rows {
            try db.put(.init(path: path, name: URL(fileURLWithPath: path).lastPathComponent,
                             volume: "/", modified: 1, directory: false, symlink: false),
                       body: String(repeating: "body ", count: 1024), root: owner, epoch: epoch)
        }
        try db.removeUnseen(root: root, subtree: "/fixture/target", epoch: "current")
        XCTAssertEqual(try db.stats().entries, 4)
        let options = FileSearchOptions(roots: [root, "/other"])
        XCTAssertTrue(try db.search("removed", options: options).isEmpty)
        for query in ["current", "other-owner", "target-extra", "sibling"] {
            XCTAssertEqual(try db.search(query, options: options).count, 1)
        }
    }

    func testChineseMultiwordNamesAndLiteralPunctuation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        var options = FileSearchOptions(roots:["/fixtures"])
        let db = try FileSearchIndex(url:directory.appendingPathComponent("index.sqlite"))
        func put(_ name: String, body: String = "", external: Bool = false) throws {
            try db.put(.init(path:"/fixtures/"+name,name:name,volume:"/",modified:1,directory:false,symlink:false,external:external),body:body,root:"/fixtures",epoch:"first")
        }
        try put("作业-2.pdf"); try put("报告 预算2026.txt"); try put("100%_value.txt")
        XCTAssertEqual(try db.search("作业",options:options).map(\.name),["作业-2.pdf"])
        XCTAssertEqual(try db.search("预算 报告",options:options).map(\.name),["报告 预算2026.txt"])
        XCTAssertEqual(try db.search("100%_",options:options).map(\.name),["100%_value.txt"])
        XCTAssertTrue(try db.search("100__",options:options).isEmpty)
        XCTAssertEqual(try db.search("%_", options: options).map(\.name), ["100%_value.txt"])
        XCTAssertEqual(try db.search("ＶＡ", options: options).map(\.name), ["100%_value.txt"])
        try put("正文测试.txt",body:"独立内容关键词")
        XCTAssertTrue(try db.search("内容关键词",options:options).isEmpty)
        options.contentSearch = true
        XCTAssertEqual(try db.search("内容关键词",options:options).map(\.name),["正文测试.txt"])
        XCTAssertEqual(try db.search("内容",options:options).map(\.name),["正文测试.txt"])
        try db.clearBodies()
        XCTAssertTrue(try db.search("内容关键词",options:options).isEmpty)
        try put("外接磁盘.txt",external:true)
        options.externalVolumes = false
        XCTAssertTrue(try db.search("外接",options:options).isEmpty)
        XCTAssertEqual(try db.stats().entries,5)
        try db.removeUnseen(root:"/fixtures",epoch:"new")
        XCTAssertEqual(try db.stats().entries,0)
    }
    func testRelevanceBeforeCandidateLimit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try FileSearchIndex(url: directory.appendingPathComponent("index.sqlite"))
        let root = "/fixture"
        func insert(_ name: String, modified: Double) throws {
            try db.put(.init(path: root + "/" + name, name: name, volume: "/", modified: modified,
                             directory: false, symlink: false), root: root, epoch: "n:fixture")
        }
        try db.transaction {
            try insert("作业", modified: 0)
            try insert("作业原稿", modified: 1)
            for i in 0..<2000 { try insert("备份作业-\(i)", modified: Double(i + 2)) }
        }
        let hits = try db.search("作业", options: .init(roots: [root]), limit: 2)
        XCTAssertEqual(hits.map(\.name), ["作业", "作业原稿"])
    }
    func testLauncherOptionDecodesOldSettingsWithoutLosingScopes() throws {
        var config = FileSearchOptions(roots:["/preserved-scope"]); config.contentSearch = true
        let data = try JSONEncoder().encode(config)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        json.removeValue(forKey:"searchFromLauncher")
        let previous = try JSONSerialization.data(withJSONObject:json)
        let restored = try JSONDecoder().decode(FileSearchOptions.self,from:previous)
        XCTAssertEqual(restored.roots,["/preserved-scope"]); XCTAssertTrue(restored.contentSearch); XCTAssertFalse(restored.searchFromLauncher)
    }
    func testCancelledDatabaseSearchCanBeFollowedByAnotherSearch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let db = try FileSearchIndex(url:directory.appendingPathComponent("index.sqlite"))
        try db.transaction { for index in 0..<2000 { try db.put(.init(path:"/fixture/作业-\(index).pdf",name:"作业-\(index).pdf",volume:"/",modified:1,directory:false,symlink:false),root:"/fixture",epoch:"n:1") } }
        let config = FileSearchOptions(roots:["/fixture"])
        var checks = 0
        XCTAssertTrue(try db.search("作业",options:config,isCancelled:{ checks += 1; return checks > 4 }).isEmpty)
        XCTAssertEqual(try db.search("作业",options:config).count,200)
    }
    func testGlobsAndInheritedIgnoreRules() {
        let patterns = ["*.tmp", "build/", "**/[Cc]ache/**", "/root/exact.txt"]
        let paths = ["/root/build", "/root/Cache", "/root/a.tmp", "/root/exact.txt", "/root/文档"]
        for directory in [false, true] {
            let filter = FileSearchRules.pathFilter(patterns, directory: directory)
            for path in paths {
                let name = URL(fileURLWithPath: path).lastPathComponent
                XCTAssertEqual(filter(path, name), patterns.contains {
                    FileSearchRules.glob($0, matches: path, directory: directory)
                }, path)
            }
        }
        XCTAssertTrue(FileSearchRules.glob("node_modules",matches:"/root/node_modules",directory:true))
        XCTAssertTrue(FileSearchRules.glob("**/[Cc]ache/**",matches:"/root/Cache",directory:true))
        XCTAssertTrue(FileSearchRules.glob("**/.git/**",matches:"/root/.git",directory:true))
        XCTAssertTrue(FileSearchRules.glob("*.tmp",matches:"/root/sub/file.tmp"))
        XCTAssertFalse(FileSearchRules.glob("*.tmp",matches:"/root/sub/file.txt"))
        let rules = [FileSearchRules.IgnoreRule(base:"/root",line:"*.log"),FileSearchRules.IgnoreRule(base:"/root",line:"!keep.log")]
        XCTAssertTrue(FileSearchRules.ignored(URL(fileURLWithPath:"/root/no.log"),directory:false,patterns:[],rules:rules))
        XCTAssertFalse(FileSearchRules.ignored(URL(fileURLWithPath:"/root/keep.log"),directory:false,patterns:[],rules:rules))
        XCTAssertFalse(FileSearchRules.ignored(URL(fileURLWithPath:"/other/no.log"),directory:false,patterns:[],rules:rules))
        let anchored = [FileSearchRules.IgnoreRule(base:"/root",line:"/only.txt")]
        XCTAssertTrue(FileSearchRules.ignored(URL(fileURLWithPath:"/root/only.txt"),directory:false,patterns:[],rules:anchored))
        XCTAssertFalse(FileSearchRules.ignored(URL(fileURLWithPath:"/root/sub/only.txt"),directory:false,patterns:[],rules:anchored))
        let escaped = [FileSearchRules.IgnoreRule(base:"/root",line:"\\!literal.txt")]
        XCTAssertTrue(FileSearchRules.ignored(URL(fileURLWithPath:"/root/!literal.txt"),directory:false,patterns:[],rules:escaped))
    }
    func testIndexPersistsAndDisabledSearchDoesNotExposeRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let url = directory.appendingPathComponent("index.sqlite")
        do { let db = try FileSearchIndex(url:url); try db.put(.init(path:"/offline/作业.pdf",name:"作业.pdf",volume:"/offline",modified:1,directory:false,symlink:false),root:"/offline",epoch:"1") }
        let reopened = try FileSearchIndex(url:url)
        var config = FileSearchOptions(roots:["/offline"])
        XCTAssertEqual(try reopened.search("作业",options:config).count,1)
        config.enabled = false
        XCTAssertTrue(try reopened.search("作业",options:config).isEmpty)
        try reopened.removeScope("/offline")
        XCTAssertEqual(try reopened.stats().entries,0)
    }

    func testAncestorExclusionsPrecedeBothCandidateAndResultCaps() throws {
        let parent = try XCTUnwrap(FileSearchLocation.canonicalPath(FileManager.default.temporaryDirectory.path))
        let fixture = URL(fileURLWithPath: parent).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixture) }
        for excludedCount in [240, 2400] {
            let root = fixture.appendingPathComponent("scope-\(excludedCount)").path
            let db = try FileSearchIndex(url: fixture.appendingPathComponent("index-\(excludedCount).sqlite"))
            var options = FileSearchOptions(roots: [root])
            options.ignorePatterns = ["__pycache__", "custom-excluded"]
            options.useIgnoreFiles = false
            try db.transaction {
                for i in 0..<excludedCount {
                    let folder = i.isMultiple(of: 2) ? "package/__pycache__/nested" : "custom-excluded/nested"
                    let name = "needle-obsolete-\(i).txt"
                    try db.put(.init(path: root + "/" + folder + "/" + name, name: name, volume: "/",
                                     modified: Double(10_000 + i), directory: false, symlink: false), root: root, epoch: "saved")
                }
                for i in 0..<250 {
                    let name = "needle-visible-\(i).txt"
                    try db.put(.init(path: root + "/" + name, name: name, volume: "/", modified: Double(i),
                                     directory: false, symlink: false), root: root, epoch: "saved")
                }
            }
            let expected = (50..<250).reversed().map { "needle-visible-\($0).txt" }
            XCTAssertEqual(try db.search("needle", options: options).map(\.name), expected)
            XCTAssertEqual(try db.search("needle", options: options, limit: 5).map(\.name), Array(expected.prefix(5)))
            // Cover the short-name covering-index query as well as the FTS path.
            XCTAssertEqual(try db.search("ne", options: options, limit: 5).map(\.name), Array(expected.prefix(5)))
            var checks = 0
            XCTAssertTrue(try db.search("needle", options: options, isCancelled: { checks += 1; return checks > 80 }).isEmpty)
            XCTAssertEqual(try db.search("needle", options: options, limit: 5).map(\.name), Array(expected.prefix(5)))
            XCTAssertEqual(try db.stats().entries, excludedCount + 250)
        }
    }


    func testPrelimitPolicyPreservesExplicitlyRestoredDirectories() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let db = try FileSearchIndex(url: fixture.appendingPathComponent("index.sqlite"))
        let root = "/offline-fixture"
        let restored = root + "/DerivedData"
        let path = restored + "/needle-restored.txt"
        var options = FileSearchOptions(roots: [root])
        options.ignorePatterns = []
        options.useIgnoreFiles = false
        try db.put(.init(path: path, name: "needle-restored.txt", volume: "/", modified: 1,
                         directory: false, symlink: false), root: root, epoch: "saved")
        var excluded = FileSearchLocation(options: options, automaticExclusions: [])
        var allowed = FileSearchLocation(options: options, automaticExclusions: [], restored: [restored])
        XCTAssertTrue(try db.search("needle", options: options,
            pathAllowed: { excluded.includesSavedResult(at: $0, directory: $1) }).isEmpty)
        XCTAssertEqual(try db.search("needle", options: options,
            pathAllowed: { allowed.includesSavedResult(at: $0, directory: $1) }).map(\.id), [path])
        XCTAssertTrue(try db.search("needle", options: options,
            pathAllowed: { excluded.includesSavedResult(at: $0, directory: $1) }).isEmpty)
    }


    func testSavedDirectoryBitSurvivesDirectoryOnlyAllowRulesAndOfflineMetadata() throws {
        let parent = try XCTUnwrap(FileSearchLocation.canonicalPath(FileManager.default.temporaryDirectory.path))
        let fixture = URL(fileURLWithPath: parent).appendingPathComponent(UUID().uuidString)
        let scope = fixture.appendingPathComponent("scope")
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        try Data("*\n!kept*/\n".utf8).write(to: scope.appendingPathComponent(".gitignore"))
        let folder = scope.appendingPathComponent("kept-offline")
        let file = scope.appendingPathComponent("kept-file")
        let db = try FileSearchIndex(url: fixture.appendingPathComponent("index.sqlite"))
        for (url, directory) in [(folder, true), (file, false)] {
            try db.put(.init(path: url.path, name: url.lastPathComponent, volume: "/", modified: 1,
                             directory: directory, symlink: false), root: scope.path, epoch: "saved")
        }
        var options = FileSearchOptions(roots: [scope.path]); options.ignorePatterns = []
        var locations = FileSearchLocation(options: options, automaticExclusions: [])
        XCTAssertTrue(locations.includesSavedResult(at: folder.path, directory: true))
        XCTAssertFalse(locations.includesSavedResult(at: folder.path, directory: false))
        let rows = try db.searchRanked("kept", options: options,
            pathAllowed: { locations.includesSavedResult(at: $0, directory: $1) }).map(\.file)
        XCTAssertEqual(rows.map(\.id), [folder.path])
        let saved = try XCTUnwrap(rows.first)
        XCTAssertTrue(saved.isDirectory, "Use the saved directory column before the publication recheck")
        XCTAssertTrue(locations.includesSavedResult(at: saved.id, directory: saved.isDirectory))
        XCTAssertTrue(saved.readingResourceMetadata().isDirectory, "Missing files must retain the saved directory bit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try db.stats().entries, 2)
    }

}
