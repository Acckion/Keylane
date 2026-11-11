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
            let needle = SystemSettingsCatalog.pageQuery(query)
            let scores = SystemSettingsCatalog.pages.compactMap { page -> (String, Int)? in
                guard let score = page.searchNames.compactMap({ SearchRanker.score($0, query: needle) }).max() else { return nil }
                return (page.id, score)
            }
            XCTAssertEqual(scores.max(by: { $0.1 < $1.1 })?.0, "system-setting:" + key, query)
            XCTAssertEqual(scores.filter { $0.1 == 1000 }.count, 1, query)
        }
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
