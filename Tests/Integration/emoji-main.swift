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

        if CommandLine.arguments.contains("-AppleLanguages") {
            precondition(EmojiCatalog.usesChinese, "Expected Chinese UI for bilingual symbol regression")
        }
        for query in ["lambda", "LAMBDA", "lamda", "兰姆达"] {
            try await search(query)
            let items = controller.sections.flatMap(\.items)
            precondition(Set(items.map(\.glyph)).isSuperset(of: ["λ", "Λ"]), "Missing Greek lambda variants for: \(query)")
        }
        try await search("small lambda")
        precondition(controller.selected?.glyph == "λ")
        if EmojiCatalog.usesChinese {
            precondition(controller.selected?.title == "希腊小写字母兰姆达")
        }
        try await search("capital lambda")
        precondition(controller.selected?.glyph == "Λ")

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

        controller.columns = 10
        controller.primaryAction = .copy
        controller.skinTone = 3
        controller.disablesInlinePicker = true
        let preferences = EmojiSearchController(defaults: defaults)
        precondition(preferences.columns == 10 && preferences.primaryAction == .copy)
        precondition(preferences.skinTone == 3 && preferences.disablesInlinePicker)
        try await search("👋")
        let wave = controller.selected!
        precondition(controller.glyph(for: wave) == "👋🏽")
        precondition(controller.copy(wave, to: board) != nil && board.string(forType: .string) == "👋🏽")
        try await search("👩🏽‍💻")

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
        restored.setAIModelIdentity("fixture-model")
        restored.query = "表达一种成功后松口气的感觉"
        try await wait { !restored.isSearching }
        try restored.showAIRecommendations("[\"😄\",\"not-local\",\"😄\",\"❤️\"]", description: restored.query)
        try await wait { !restored.isSearching }
        precondition(restored.sections.first?.id == "ai-results")
        precondition(restored.sections.first?.items.map(\.glyph) == ["😄", "❤️"])
        let recommended = restored.selected!
        precondition(restored.copy(recommended, to: board) != nil)
        precondition(board.string(forType: .string) == recommended.glyph)
        let description = restored.query
        restored.query = "different local query"
        try await wait { !restored.isSearching }
        precondition(!restored.sections.contains { $0.id == "ai-results" })
        restored.query = description
        try await wait { !restored.isSearching }
        precondition(restored.sections.first?.id == "ai-results", "Exact query should reuse memory cache")
        restored.category = "math"
        try await wait { !restored.isSearching }
        precondition(!restored.sections.contains { $0.id == "ai-results" })
        restored.category = "all"
        try await wait { !restored.isSearching }
        restored.setAIModelIdentity("different-model")
        try await wait { !restored.isSearching }
        precondition(!restored.sections.contains { $0.id == "ai-results" })
        try restored.showAIRecommendations("[\"😄\"]", description: description, now: Date().addingTimeInterval(-901))
        try await wait { !restored.isSearching }
        precondition(!restored.sections.contains { $0.id == "ai-results" }, "Expired cache must not be displayed")
        print("PASS Emoji AI: local-catalog validation, real grid and copy, exact-query cache, category/model isolation and expiry; no model requests")
        print("PASS Emoji: bilingual search, grid movement, retained selection, empty result, exact Unicode pasteboard, offscreen grid, cancellation and recents")
    }

    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        precondition(condition(), "Timed out")
    }
}
