import Combine
import Foundation

enum QuickAIPrimaryAction: String, CaseIterable { case paste, copy }
enum QuickAIModelPreference: String, CaseIterable {
    case balanced, fast, quality
    var title: String { switch self { case .balanced: "均衡"; case .fast: "速度优先"; case .quality: "质量优先" } }
}

final class AIInteractionPreferences: ObservableObject {
    private enum Key {
        static let rootFallback = "ai.quick.rootFallback"
        static let rootTab = "ai.quick.rootTab"
        static let chatReturn = "ai.chat.sendWithReturn"
        static let chatFloating = "ai.chat.floating"
    }

    @Published var primaryAction: QuickAIPrimaryAction { didSet { preferences.set(primaryAction.rawValue, forKey: "ai.quick.primaryAction") } }
    @Published var modelPreference: QuickAIModelPreference { didSet { preferences.set(modelPreference.rawValue, forKey: "ai.quick.modelPreference") } }
    @Published var preferenceModels: [String: String] { didSet { preferences.set(preferenceModels, forKey: "ai.quick.preferenceModels") } }
    var preferredModelID: UUID? { preferenceModels[modelPreference.rawValue].flatMap(UUID.init(uuidString:)) }

    var showsRootHint: Bool { rootTab || rootFallback }

    @Published var rootFallback: Bool { didSet { preferences.set(rootFallback, forKey: Key.rootFallback) } }
    @Published var rootTab: Bool { didSet { preferences.set(rootTab, forKey: Key.rootTab) } }
    @Published var chatReturn: Bool { didSet { preferences.set(chatReturn, forKey: Key.chatReturn) } }
    @Published var chatFloating: Bool { didSet { preferences.set(chatFloating, forKey: Key.chatFloating) } }
    private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        primaryAction = QuickAIPrimaryAction(rawValue: preferences.string(forKey: "ai.quick.primaryAction") ?? "") ?? .paste
        modelPreference = QuickAIModelPreference(rawValue: preferences.string(forKey: "ai.quick.modelPreference") ?? "") ?? .balanced
        preferenceModels = preferences.dictionary(forKey: "ai.quick.preferenceModels") as? [String: String] ?? [:]
        rootFallback = preferences.object(forKey: Key.rootFallback) as? Bool ?? true
        rootTab = preferences.object(forKey: Key.rootTab) as? Bool ?? true
        chatReturn = preferences.bool(forKey: Key.chatReturn)
        chatFloating = preferences.bool(forKey: Key.chatFloating)
    }
}
