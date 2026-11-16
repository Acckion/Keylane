import Foundation
import XCTest
import KeylaneCore

final class SettingsExportTests: XCTestCase {
    func testExportsOnlySupportedPreferences() throws {
        let suite = "Keylane.SettingsExportTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("dark", forKey: "appearance")
        defaults.set(false, forKey: "compactFavorites")
        defaults.set(90, forKey: "launcherReturnDelay")
        defaults.set("secret", forKey: "apiKey")
        defaults.set("private note", forKey: "notes")
        defaults.set(["clipboard history"], forKey: "clipboard")
        defaults.set(["/Users/local/Private"], forKey: "applicationRoots")

        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: SettingsExport.data(defaults: defaults)) as? [String: Any])
        XCTAssertEqual(decoded["schemaVersion"] as? Int, 1)
        let preferences = try XCTUnwrap(decoded["preferences"] as? [String: Any])
        XCTAssertEqual(Set(preferences.keys), ["appearance", "compactFavorites", "launcherReturnDelay"])
        XCTAssertEqual(preferences["appearance"] as? String, "dark")
        XCTAssertEqual(preferences["compactFavorites"] as? Bool, false)
        XCTAssertEqual(preferences["launcherReturnDelay"] as? Int, 90)
    }
}
