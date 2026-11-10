import XCTest
@testable import KeylaneCore
final class LauncherTests: XCTestCase {
    func testCatalogDiscoversAddedRenamedRemovedAndExcludedBundles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func make(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name + ".app"); let contents = url.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleName":name,"CFBundleIdentifier":"org.keylane.test."+name], format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist")); return url
        }
        let first = try make("Alpha")
        XCTAssertEqual(ApplicationCatalog.scan(roots:[root.path,root.path],excluded:[]).count,1)
        let second = try make("Beta")
        XCTAssertEqual(ApplicationCatalog.scan(roots:[root.path],excluded:[]).count,2)
        XCTAssertEqual(ApplicationCatalog.scan(roots:[root.path],excluded:[first.path]).map { $0.url.path },[second.path])
        let renamed = root.appendingPathComponent("Renamed.app"); try FileManager.default.moveItem(at:first,to:renamed)
        XCTAssertTrue(ApplicationCatalog.scan(roots:[root.path],excluded:[]).contains { $0.url.path == renamed.path })
        try FileManager.default.removeItem(at:second)
        XCTAssertEqual(ApplicationCatalog.scan(roots:[root.path],excluded:[]).count,1)
    }
    func testPinyinAndEnglishInitials() {
        XCTAssertNotNil(SearchRanker.score("系统设置",query:"xtsz"))
        XCTAssertNotNil(SearchRanker.score("Visual Studio Code",query:"vsc"))
        XCTAssertNil(SearchRanker.score("系统设置",query:"notanapp"))
    }
    func testChineseNamesPinyinSpacingTraditionalAndWidth() {
        for query in ["系统设置", "设置", "系統設置", "xtsz", "xitongshezhi", "xi tong she zhi", "xì tǒng shè zhì", "ｘｔｓｚ"] {
            XCTAssertNotNil(SearchRanker.score("系统设置", query: query), query)
        }
        XCTAssertNotNil(SearchRanker.score("剪贴板历史", query: "jian tie ban"))
        XCTAssertNotNil(SearchRanker.score("Visual Studio Code", query: "visual studio"))
        XCTAssertNil(SearchRanker.score("AppCleaner", query: "系统设置"))
        XCTAssertNil(SearchRanker.score("AppCleaner", query: "剪贴板"))
    }
    func testRankingKeepsMatchQualityAheadOfFavoritesAndFrequency() {
        let exact = SearchResultRank(score:1000,favorite:false,uses:0,title:"A",id:"1")
        let fuzzy = SearchResultRank(score:300,favorite:true,uses:999,title:"B",id:"2")
        XCTAssertTrue(exact.precedes(fuzzy)); XCTAssertFalse(fuzzy.precedes(exact))
        XCTAssertTrue(SearchResultRank(score:800,favorite:true,uses:0,title:"B",id:"2").precedes(SearchResultRank(score:800,favorite:false,uses:50,title:"A",id:"1")))
    }
    func testShortcutValidationAndTapSequence() {
        XCTAssertNotNil(ShortcutValidation.conflict(in:["a":.launcher,"b":.launcher]))
        XCTAssertNotNil(ShortcutValidation.conflict(in:["a":Shortcut(key:0,modifiers:0)]))
        XCTAssertNotNil(ShortcutValidation.conflict(in:["a":Shortcut(key:0,modifiers:256)]))
        XCTAssertNil(ShortcutValidation.conflict(in:["a":.launcher]))
        var tap = ModifierTapTracker()
        XCTAssertFalse(tap.update(pressed:true,time:1)); XCTAssertFalse(tap.update(pressed:false,time:1.1))
        XCTAssertFalse(tap.update(pressed:true,time:1.2)); XCTAssertTrue(tap.update(pressed:false,time:1.3))
        tap.cancel(); XCTAssertFalse(tap.update(pressed:true,time:2)); XCTAssertFalse(tap.update(pressed:false,time:2.8))
    }
    func testRealCatalogSearchBaseline() throws {
        // Query assertions below intentionally use Chinese; do not depend on the runner login language.
        let apps = ApplicationCatalog.scan(roots: ApplicationCatalog.defaultRoots, excluded: [], languages: ["zh-Hans"])
        guard !apps.isEmpty else { throw XCTSkip("No installed applications available") }
        var samples: [Double] = []
        for query in ["系统", "System Settings", "xtsz", "Terminal", "vsc", "Safari", "计算器", "Calculator", "设置", "mail", "notes", "finder"] {
            let start = Date()
            let matches = apps.compactMap { $0.identity.score(query: query) }
            samples.append(Date().timeIntervalSince(start))
            if query == "系统" || query == "System Settings" { XCTAssertFalse(matches.isEmpty) }
        }
        let sorted = samples.sorted()
        print("CORE_SEARCH_BASELINE apps=\(apps.count) p95_ms=\(sorted[min(sorted.count-1, Int(Double(sorted.count)*0.95))]*1000)")
    }
    func testArgumentsAreParsedWithoutShellExpansion() throws {
        XCTAssertEqual(try ArgumentParser.parse("--name 'two words' \"\" x\\ y $(echo)"),["--name","two words","","x y","$(echo)"])
        XCTAssertThrowsError(try ArgumentParser.parse("'unfinished"))
        XCTAssertThrowsError(try ArgumentParser.parse("trailing\\"))
    }
}
