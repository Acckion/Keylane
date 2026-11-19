import Combine
import Foundation

final class AIInteractionPreferences: ObservableObject {
    private enum Key {
        static let rootFallback = "ai.quick.rootFallback"
        static let rootTab = "ai.quick.rootTab"
        static let chatReturn = "ai.chat.sendWithReturn"
        static let chatFloating = "ai.chat.floating"
    }

    var showsRootHint: Bool { rootTab || rootFallback }

    @Published var rootFallback: Bool { didSet { preferences.set(rootFallback, forKey: Key.rootFallback) } }
    @Published var rootTab: Bool { didSet { preferences.set(rootTab, forKey: Key.rootTab) } }
    @Published var chatReturn: Bool { didSet { preferences.set(chatReturn, forKey: Key.chatReturn) } }
    @Published var chatFloating: Bool { didSet { preferences.set(chatFloating, forKey: Key.chatFloating) } }
    private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        rootFallback = preferences.object(forKey: Key.rootFallback) as? Bool ?? true
        rootTab = preferences.object(forKey: Key.rootTab) as? Bool ?? true
        chatReturn = preferences.bool(forKey: Key.chatReturn)
        chatFloating = preferences.bool(forKey: Key.chatFloating)
    }
}

final class AIChatComposer: ObservableObject {
    @Published var text = ""

    func offer(_ prompt: String) {
        guard text.isEmpty, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        text = prompt
    }
}
