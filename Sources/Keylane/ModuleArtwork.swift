import AppKit
import SwiftUI
import KeylaneCore

enum ModuleArtwork {
    private static let settingsNames = [
        "general": "general", "launcher": "launcher", "keyboard": "keyboard", "hotkeys": "hotkeys",
        "menu-bar": "menu-bar", "permissions": "permissions", "advanced": "advanced", "about": "about",
        "applications": "applications", "files": "file-search", "screenshots": "screenshots",
        "clipboard": "clipboard-history", "calendar": "calendar", "shortcuts": "shortcuts",
        "notes": "notes", "links": "quicklinks", "script-commands": "script-commands",
        "keylane.calculator": "calculator", "keylane.system-tools": "system-actions",
        "keylane.app-utilities": "keylane-tools", "keylane.navigation": "navigation",
        "keylane.contacts": "contacts", "keylane.dictionary": "dictionary", "keylane.emoji": "emoji",
    ]

    private static let commandNames = [
        "settings": "general", "show-onboarding": "launcher",
        "ask-files": "ai", "ask-finder": "ai",
        "calculator": "calculator", "calculator-hint": "calculator", "calculator-help": "calculator",
        "screenshot": "screenshots", "color": "color-picker", "speak": "read-aloud",
        "stop-speaking": "read-aloud", "finder": "file-search",
        "switch-windows": "navigation", "search-menu-items": "navigation",
        "contacts": "contacts", "dictionary": "dictionary", "dictionary-query": "dictionary",
        "emoji-symbols": "emoji", "export-settings": "export-settings",
        "view-release-notes": "changelog", "check-for-updates": "check-updates", "show-camera": "camera",
    ]

    private static let cache = NSCache<NSString, NSImage>()

    static func settings(_ pageID: String) -> NSImage? {
        settingsNames[pageID].flatMap(image)
    }

    static func command(_ id: CommandID, settingsPage: String? = nil) -> NSImage? {
        if let name = commandNames[id.rawValue] { return image(name) }
        return settingsPage.flatMap(settings)
    }

    private static func image(_ name: String) -> NSImage? {
        let key = name as NSString
        if let cached = cache.object(forKey: key) { return cached }
        var url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "ModuleArtwork")
        #if DEBUG
        if url == nil {
            url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/ModuleArtwork/\(name).png")
        }
        #endif
        guard let url, let artwork = NSImage(contentsOf: url) else { return nil }
        cache.setObject(artwork, forKey: key)
        return artwork
    }
}

struct ModuleArtworkImage: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .accessibilityHidden(true)
    }
}
