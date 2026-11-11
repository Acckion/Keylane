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
    func testGridMovementKeepsColumnAndHandlesShortRowsAndEmptySections() {
        let counts = [6, 0, 8]
        let shortRow = NavigationBounds.moveGrid(section: 0, item: 3, by: 1, vertical: true, columns: 4, counts: counts)
        XCTAssertEqual(shortRow?.section, 0)
        XCTAssertEqual(shortRow?.item, 5)
        let nextSection = NavigationBounds.moveGrid(section: 0, item: 5, by: 1, vertical: true, columns: 4, counts: counts)
        XCTAssertEqual(nextSection?.section, 2)
        XCTAssertEqual(nextSection?.item, 1)
        let previousSection = NavigationBounds.moveGrid(section: 2, item: 3, by: -1, vertical: true, columns: 4, counts: counts)
        XCTAssertEqual(previousSection?.section, 0)
        XCTAssertEqual(previousSection?.item, 5)
        XCTAssertEqual(NavigationBounds.moveGrid(section: 2, item: 4, by: 1, vertical: true, columns: 4, counts: counts)?.item, 4)
        XCTAssertEqual(NavigationBounds.moveGrid(section: 0, item: 5, by: 1, vertical: false, columns: 4, counts: counts)?.item, 0)
        XCTAssertNil(NavigationBounds.moveGrid(section: 0, item: 0, by: 1, vertical: true, columns: 4, counts: []))
    }
}
