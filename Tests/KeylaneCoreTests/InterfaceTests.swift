import XCTest
@testable import KeylaneCore
final class InterfaceTests: XCTestCase {
    func testSettingsSearchFindsActualControlsAcrossLanguages() {
        XCTAssertEqual(SettingsItem.search("深色").map(\.id), ["appearance"])
        XCTAssertEqual(SettingsItem.search("备份").map(\.id), ["export"])
        XCTAssertEqual(SettingsItem.search("CLIPBOARD history").map(\.id), ["capture"])
        XCTAssertTrue(SettingsItem.search("不存在的配置项").isEmpty)
        XCTAssertTrue(SettingsItem.search("  \n").isEmpty)
        XCTAssertEqual(Set(SettingsItem.all.map(\.id)).count,SettingsItem.all.count)
    }
    func testKeyboardSelectionClampsEmptyAndShrinkingLists() {
        XCTAssertEqual(NavigationBounds.move(0, by: -1, count: 5),0)
        XCTAssertEqual(NavigationBounds.move(4, by: 1, count: 5),4)
        XCTAssertEqual(NavigationBounds.move(0, by: 1, count: 0),0)
        XCTAssertEqual(NavigationBounds.move(8, by: 1, count: 2),1)
        XCTAssertEqual(NavigationBounds.move(1, by: -1, count: 2),0)
    }
}
