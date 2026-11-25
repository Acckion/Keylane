import AppKit
import ImageIO
import SwiftUI
import KeylaneCore

enum ModuleArtwork {
    private static let settingsNames = [
        "general": "general", "launcher": "launcher", "keyboard": "keyboard", "hotkeys": "hotkeys",
        "menu-bar": "menu-bar", "permissions": "permissions", "advanced": "advanced", "about": "about",
        "applications": "applications", SettingsItem.applicationAutoQuit.page: "auto-quit",
        "files": "file-search", "screenshots": "screenshots",
        "clipboard": "clipboard-history", "calendar": "calendar", "shortcuts": "shortcuts",
        "links": "quicklinks", "script-commands": "script-commands",
        "keylane.calculator": "calculator", "keylane.system": "system-actions",
        "keylane.app-utilities": "keylane-app", "keylane.navigation": "navigation",
        "keylane.contacts": "contacts", "keylane.dictionary": "dictionary", "keylane.emoji": "emoji",
        "keylane.apple-notes": "notes", "keylane.window-management": "window-management",
        "snippets": "snippets",
        "ai": "ai", "ai-models": "ai-models", "ai-text-commands": "ai-commands",
        "translator": "translator", "dictation": "dictation",
        "dictation-personalization": "dictation-vocabulary", "dictation-styles": "dictation-style",
        "dictation-statistics": "dictation-statistics",
        "keylane.drop-shelf": "drop-shelf", "keylane.focus": "focus",
        "keylane.downloads": "downloads", "keylane.themes": "theme-studio",
    ]

    private static let modulePages = [
        "keylane.host": "general", "keylane.applications": "applications", "keylane.files": "files",
        "keylane.clipboard": "clipboard", "keylane.screenshots": "screenshots", "keylane.calendar": "calendar",
        "keylane.shortcuts": "shortcuts", "keylane.script-commands": "script-commands",
        "keylane.snippets": "snippets", "keylane.links": "links",
        "keylane.ai": "ai", "keylane.translator": "translator", "keylane.dictation": "dictation",
    ]

    private static let commandNames = [
        "search-downloads": "downloads",
        "theme-studio": "theme-studio",
        "switch-theme": "theme-switch",
        "ai-polish": "ai-polish",
        "ai-summarize": "ai-summarize",
        "dictate": "dictation",
        "dictate-to-note": "dictation-note",
        "dictate-to-ai": "dictation-ai",
        "dictation-history": "dictation-history",
        "dictation-last": "dictation-last",
        "create-dictation-style": "dictation-style",
        "add-dictation-word": "dictation-vocabulary",
        "paste-sequentially": "clipboard-sequence",
        "reset-paste-sequence": "clipboard-reset",
        "clipboard-ai-chat": "ai-chat",
        "clipboard-ai-ask": "ai-chat",
        "clipboard-ai-summarize": "ai-summarize",
        "clipboard-ai-translate": "translator",
        "search-apple-notes": "notes-search",
        "create-apple-note": "notes-create",
        "apple-note-ai-chat": "ai-chat",
        "apple-note-ai-summarize": "ai-summarize",
        "apple-note-ai-polish": "ai-polish",
        "apple-note-ai-todos": "notes-todos",
        "search-quicklinks": "quicklink-search",
        "manage-quicklinks": "quicklink-search",
        "create-quicklink": "quicklink-create",
        "import-quicklinks": "quicklink-import",
        "export-quicklinks": "quicklink-export",
        "dismiss-notifications": "notifications-clear",
        "eject-all-disks": "eject-disks",
        "empty-trash": "trash-empty",
        "log-out": "log-out",
        "next-track": "media-next",
        "open-trash": "trash-open",
        "play-pause": "media-play",
        "previous-track": "media-previous",
        "quit-all-applications": "quit-apps",
        "quit-other-applications": "quit-apps",
        "restart-mac": "restart",
        "restart-frontmost-application": "restart",
        "set-output-volume": "volume-set",
        "show-desktop": "desktop",
        "show-screen-saver": "screen-saver",
        "shut-down": "power-off",
        "toggle-bluetooth": "bluetooth",
        "toggle-hidden-files": "hidden-files",
        "toggle-stage-manager": "stage-manager",
        "toggle-system-appearance": "theme-switch",
        "volume-down": "volume-down",
        "volume-up": "volume-up",
        "capture-keylane-window": "capture-window",
        "check-extension-updates": "extension-updates",
        "copy-keylane-logs": "logs-copy",
        "copy-keylane-version": "version-copy",
        "import-settings": "import-settings",
        "open-keylane-website": "website",
        "open-keylane-github": "source-code",
        "quit-keylane": "log-out",
        "reveal-keylane-logs": "logs-folder",
        "send-keylane-feedback": "feedback",
        "share-keylane": "share",
        "keylane-extension-store": "extension-store",
        "settings": "general", "show-onboarding": "launcher",
        "quick-ai": "ai", "ai-chat": "ai-chat", "translate": "translator",
        "ask-files": "ai", "ask-finder": "ai",
        "calculator": "calculator", "calculator-hint": "calculator", "calculator-help": "calculator",
        "screenshot": "screenshots", "paste-latest-screenshot": "paste-screenshot", "color": "color-picker", "speak": "read-aloud",
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

    private static let cache = ResourceCache<NSString, NSImage>(.artwork)

    static func settings(_ pageID: String) -> NSImage? {
        settingsNames[pageID].flatMap(image)
    }

    static func module(_ id: ModuleID) -> NSImage? {
        settings(modulePages[id.rawValue] ?? id.rawValue)
    }

    static func command(_ id: CommandID, settingsPage: String? = nil, moduleID: ModuleID? = nil) -> NSImage? {
        if let name = commandNames[id.rawValue] { return image(name) }
        if id.rawValue.hasPrefix("quicklink:") { return settings("links") }
        if id.rawValue.hasPrefix("ai-command:") { return image("ai-commands") }
        if id.rawValue.hasPrefix("translate:") { return settings("translator") }
        if id.rawValue.hasPrefix("set-output-volume-") { return image("volume-set") }
        return settingsPage.flatMap(settings) ?? moduleID.flatMap(module)
    }

    private static func nativeArtwork(_ icon: NSImage) -> NSImage? {
        // Keep the existing safe-area crop without retaining the full application
        // icon in a deferred drawing closure. Raster resolution remains 2x.
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        icon.draw(in: NSRect(x: -8, y: -8, width: 144, height: 144))
        guard let image = bitmap.cgImage else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: 128, height: 128))
    }

    private static func image(_ name: String) -> NSImage? {
        let key = name as NSString
        if let cached = cache.object(forKey: key) { return cached }
        if name == "keylane-app" {
            let icon = Bundle.main.url(forResource: "Keylane", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.keylane.launcher")
                    .map { NSWorkspace.shared.icon(forFile: $0.path) }
            guard let icon else { return nil }
            guard let artwork = nativeArtwork(icon) else { return nil }
            cache.setObject(artwork, forKey: key, cost: 256 * 256 * 4)
            return artwork
        }
        if name == "shortcuts",
           let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
            let icon = NSWorkspace.shared.icon(forFile: application.path)
            guard let artwork = nativeArtwork(icon) else { return nil }
            cache.setObject(artwork, forKey: key, cost: 256 * 256 * 4)
            return artwork
        }
        var url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "ModuleArtwork")
        #if DEBUG
        if url == nil {
            url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/ModuleArtwork/\(name).png")
        }
        #endif
        // Decode near display size rather than retaining a 256×256 bitmap for each module.
        guard let url,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: name == "auto-quit" ? 120 : 96,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let artwork = NSImage(cgImage: image, size: .zero)
        cache.setObject(artwork, forKey: key, cost: image.bytesPerRow * image.height)
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
