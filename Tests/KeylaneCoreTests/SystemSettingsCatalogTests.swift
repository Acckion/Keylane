import XCTest
@testable import KeylaneCore

final class SystemSettingsCatalogTests: XCTestCase {
    func testSettingsNamesMatchInEitherLanguage() {
        for (query, key) in [
            ("蓝牙", "bluetooth"), ("Bluetooth", "bluetooth"), ("蓝牙设置", "bluetooth"),
            ("System Settings Bluetooth", "bluetooth"), ("系统设置蓝牙", "bluetooth"),
            ("WLAN", "wifi"), ("无线局域网", "wifi"), ("Wi-Fi settings", "wifi"),
            ("软件更新", "software-update"), ("Software Update", "software-update"),
            ("声效", "sound"), ("Sound", "sound"),
            ("录屏权限", "privacy-screen-recording"), ("Screen Recording", "privacy-screen-recording"),
            ("Full Disk Access", "privacy-full-disk-access"), ("完全磁盘访问权限", "privacy-full-disk-access")
        ] {
            let ranking = LauncherSearchRanking(query: query, aliases: [:], favorites: [], usage: [:])
            let matches = SystemSettingsCatalog.pages.compactMap { page in
                ranking.match(id: page.id, title: page.title(), names: page.searchNames, kind: .systemSetting)
            }
            XCTAssertEqual(matches.sorted { $0.precedes($1) }.first?.id, "system-setting:" + key, query)
            XCTAssertEqual(matches.filter { $0.score == 1000 }.count, 1, query)
        }
    }

    func testSettingsRankingRequiresStrongNamesAndKeepsExactAliases() throws {
        let page = try XCTUnwrap(SystemSettingsCatalog.pages.first { $0.id == "system-setting:bluetooth" })
        let ranking = LauncherSearchRanking(query: "bth", aliases: [:], favorites: [], usage: [:])
        XCTAssertNotNil(ranking.match(id: page.id, title: page.english))
        XCTAssertNil(ranking.match(id: page.id, title: page.english, names: page.searchNames, kind: .systemSetting))

        let rankingWithAlias = LauncherSearchRanking(query: "bth", aliases: [page.id: "bth"],
                                                    favorites: [page.id], usage: [page.id: 3])
        let match = rankingWithAlias.match(id: page.id, title: page.english, names: page.searchNames, kind: .systemSetting)
        XCTAssertEqual(match?.score, 1500)
        XCTAssertEqual(match?.favorite, true)
        XCTAssertEqual(match?.uses, 3)
    }

    func testGenericSettingsQueriesDoNotExpandToEveryPage() {
        for query in ["", " settings ", "System Settings", "System Preferences", "系统设置", "系統設定"] {
            XCTAssertTrue(SystemSettingsCatalog.pageQuery(query).isEmpty, query)
        }
    }

    func testCatalogURLsAndLocalizedTitles() {
        let pages = SystemSettingsCatalog.pages
        XCTAssertEqual(Set(pages.map(\.id)).count, pages.count)
        XCTAssertTrue(pages.allSatisfy { $0.url.scheme == "x-apple.systempreferences" })
        let bluetooth = pages.first { $0.id == "system-setting:bluetooth" }
        XCTAssertEqual(bluetooth?.title(languages: ["zh-Hans"]), "蓝牙")
        XCTAssertEqual(bluetooth?.title(languages: ["en-US"]), "Bluetooth")
        let screenRecording = pages.first { $0.id == "system-setting:privacy-screen-recording" }
        XCTAssertEqual(screenRecording?.url.query, "Privacy_ScreenCapture")
    }
}
