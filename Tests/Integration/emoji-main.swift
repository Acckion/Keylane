import AppKit
import KeylaneCore
import SwiftUI

@main
struct EmojiCheck {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let suite = "org.keylane.emoji.fixture." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let board = NSPasteboard.withUniqueName()
        defer { defaults.removePersistentDomain(forName: suite); board.releaseGlobally() }
        let controller = EmojiSearchController(defaults: defaults)

        func search(_ query: String) async throws {
            controller.query = query
            try await wait { !controller.isSearching }
        }

        controller.start()
        try await wait { !controller.isLoading }
        precondition(controller.sections.first?.id == "frequent" && controller.selected?.glyph == "β")
        controller.move(1, vertical: false)
        precondition(controller.selected?.glyph == "λ")
        controller.move(1, vertical: true)
        precondition(controller.selected?.glyph == "😜")

        try await search("grinning cat")
        precondition(controller.selected?.glyph == "😺")
        try await search("大笑的猫")
        precondition(controller.selected?.glyph == "😺")
        try await search("cat")
        let crying = controller.sections[0].items.first { $0.glyph == "😿" }!
        controller.selection = .init(sectionID: "results", itemID: crying.id)
        controller.query = "crying"
        precondition(controller.selected == nil && controller.copy(crying, to: board) == nil)
        controller.query = "crying cat"
        try await wait { !controller.isSearching }
        precondition(controller.selected?.glyph == crying.glyph)
        controller.category = "flags"
        try await wait { !controller.isSearching }
        precondition(controller.sections.isEmpty && controller.selected == nil)
        controller.category = "all"

        for glyph in ["👩🏽‍💻", "👨‍👩‍👧‍👦", "🇨🇳", "❤️", "👩🏽‍💻"] {
            try await search(glyph)
            let selected = controller.selected!
            precondition(selected.glyph == glyph)
            precondition(controller.copy(selected, to: board) == board.changeCount)
            precondition(board.string(forType: .string)?.unicodeScalars.map(\.value) == glyph.unicodeScalars.map(\.value))
        }

        // Rendering uses the real SwiftUI grid in an offscreen AppKit host.
        let host = NSHostingView(rootView: EmojiSearchPage(controller: controller, activate: { _ in }))
        host.frame = NSRect(x: 0, y: 0, width: 740, height: 440)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No rendered grid") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        precondition(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)

        let prior = controller.selected!
        controller.query = "zzzzkeylanenoemoji"
        controller.stop()
        precondition(controller.copy(prior, to: board) == nil)
        for _ in 0..<3 {
            controller.start()
            try await wait { !controller.isSearching }
            precondition(controller.selected == nil && controller.sections.isEmpty)
            controller.stop()
        }

        let restored = EmojiSearchController(defaults: defaults)
        restored.start()
        try await wait { !restored.isLoading }
        precondition(restored.sections.first?.items.first?.glyph == "👩🏽‍💻")
        let usage = defaults.dictionary(forKey: "emojiRecentUsage") as? [String: Int]
        precondition(usage?["👩🏽‍💻"] == 2 && usage?["❤️"] == 1 && usage?[crying.glyph] == nil)
        print("PASS Emoji: bilingual search, grid movement, retained selection, empty result, exact Unicode pasteboard, offscreen grid, cancellation and recents")
    }

    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        precondition(condition(), "Timed out")
    }
}
