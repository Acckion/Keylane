import XCTest
@testable import KeylaneCore

final class FileIndexTests: XCTestCase {
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
        try put("正文测试.txt",body:"独立内容关键词")
        XCTAssertTrue(try db.search("内容关键词",options:options).isEmpty)
        options.contentSearch = true
        XCTAssertEqual(try db.search("内容关键词",options:options).map(\.name),["正文测试.txt"])
        try db.clearBodies()
        XCTAssertTrue(try db.search("内容关键词",options:options).isEmpty)
        try put("外接磁盘.txt",external:true)
        options.externalVolumes = false
        XCTAssertTrue(try db.search("外接",options:options).isEmpty)
        XCTAssertEqual(try db.stats().entries,5)
        try db.removeUnseen(root:"/fixtures",epoch:"new")
        XCTAssertEqual(try db.stats().entries,0)
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
}
