import Foundation

public enum SettingsExport {
    // Explicit lists keep tokens, history, paths, free-form content and grants out of the export.
    private static let strings = ["appearance", "placement", "rootSearchSensitivity", "interfaceSize",
                                  "windowMode", "applicationHotkeyAction", "navigation", "windowActivationBehavior",
                                  "launcherEscapeBehavior", "pageNavigationKeys", "doubleTap"]
    private static let flags = ["rootFileContentSearch", "compactFavorites", "applicationsEnabled",
                                "escapeClosesUtilityWindows", "hyperIncludesShift", "replaceHyperKeycaps", "hyperkey"]

    public static func data(defaults: UserDefaults) throws -> Data {
        var settings: [String: Any] = [:]
        for key in strings { settings[key] = defaults.string(forKey: key) }
        for key in flags { settings[key] = defaults.object(forKey: key) as? Bool }
        settings["launcherReturnDelay"] = defaults.object(forKey: "launcherReturnDelay") as? Int
        return try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "preferences": settings],
                                          options: [.prettyPrinted, .sortedKeys])
    }
}
