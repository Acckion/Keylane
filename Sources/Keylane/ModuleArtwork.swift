import AppKit
import ImageIO
import SwiftUI
import KeylaneCore

enum ModuleArtwork {
    private static let settingsNames = [
        "general": "general", "launcher": "launcher", "keyboard": "keyboard", "hotkeys": "hotkeys",
        "menu-bar": "menu-bar", "permissions": "permissions", "advanced": "advanced", "about": "about",
        "applications": "applications", "files": "file-search", "screenshots": "screenshots",
        "clipboard": "clipboard-history", "calendar": "calendar", "shortcuts": "shortcuts",
        "links": "quicklinks", "script-commands": "script-commands",
        "keylane.calculator": "calculator", "keylane.system-tools": "system-actions",
        "keylane.app-utilities": "keylane-tools", "keylane.navigation": "navigation",
        "keylane.contacts": "contacts", "keylane.dictionary": "dictionary", "keylane.emoji": "emoji",
        "keylane.apple-notes": "notes", "keylane.window-management": "window-management",
        "snippets": "snippets",
    ]

    private static let modulePages = [
        "keylane.host": "general", "keylane.applications": "applications", "keylane.files": "files",
        "keylane.clipboard": "clipboard", "keylane.screenshots": "screenshots", "keylane.calendar": "calendar",
        "keylane.shortcuts": "shortcuts", "keylane.script-commands": "script-commands",
        "keylane.snippets": "snippets", "keylane.links": "links",
    ]

    private static let commandNames = [
        "settings": "general", "show-onboarding": "launcher",
        "ask-files": "ai", "ask-finder": "ai",
        "calculator": "calculator", "calculator-hint": "calculator", "calculator-help": "calculator",
        "screenshot": "capture-screen", "paste-latest-screenshot": "paste-screenshot", "color": "color-picker", "speak": "read-aloud",
        "stop-speaking": "read-aloud", "finder": "file-search",
        "switch-windows": "navigation", "search-menu-items": "navigation",
        "contacts": "contacts", "dictionary": "dictionary", "dictionary-query": "dictionary",
        "emoji-symbols": "emoji", "export-settings": "export-settings",
        "view-release-notes": "changelog", "check-for-updates": "check-updates", "show-camera": "camera",
        "window-left-half": "window-left", "window-right-half": "window-right",
        "window-top-half": "window-top", "window-bottom-half": "window-bottom",
        "window-center": "window-center", "window-maximize": "window-maximize",
        "window-restore": "window-restore", "window-next-display": "window-next-display",
        "uninstall-application": "app-uninstall", "manage-auto-quit": "auto-quit",
        "lock-screen": "lock-screen", "sleep-mac": "sleep", "sleep-displays": "display-sleep",
        "toggle-output-mute": "mute-audio", "hide-other-applications": "hide-apps", "unhide-applications": "show-apps",
        "cancel-running-script": "script-commands", "quicklink": "quicklinks",
    ]

    private static let cache = NSCache<NSString, NSImage>()

    static func settings(_ pageID: String) -> NSImage? {
        settingsNames[pageID].flatMap(image)
    }

    static func module(_ id: ModuleID) -> NSImage? {
        settings(modulePages[id.rawValue] ?? id.rawValue)
    }

    static func command(_ id: CommandID, settingsPage: String? = nil, moduleID: ModuleID? = nil) -> NSImage? {
        if let name = commandNames[id.rawValue] { return image(name) }
        if id.rawValue.hasPrefix("quicklink:") { return settings("links") }
        return settingsPage.flatMap(settings) ?? moduleID.flatMap(module)
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
        // Artwork is displayed at up to 36 points. Decode at Retina size
        // rather than retaining a 256×256 bitmap for each module.
        guard let url,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 96,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let artwork = NSImage(cgImage: image, size: .zero)
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
