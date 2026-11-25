import Foundation

package enum MacOSNoViewCapabilities {
    package typealias Presenter = @MainActor @Sendable (Presentation) -> Void
    static let preferences = "preferences.read"
    static let toast = "feedback.toast"
    static let clipboard = "clipboard.write"
    static let closeWindow = "navigation.close"
    static let clearSearch = "navigation.clearSearch"
    static let popToRoot = "navigation.popToRoot"
    static let navigation: Set<String> = [closeWindow, clearSearch, popToRoot]
    @TaskLocal package static var navigationCommitted = false
    @TaskLocal package static var allowsNavigation: (@MainActor @Sendable () -> Bool)?
    package struct DisplayPreferences: Sendable {
        package enum Appearance: String, Sendable { case light, dark }
        package enum TextSize: String, Sendable { case medium, large }
        let appearance: Appearance
        let textSize: TextSize

        package init(appearance: Appearance, textSize: TextSize) {
            self.appearance = appearance
            self.textSize = textSize
        }
    }

    @TaskLocal package static var displayPreferences: DisplayPreferences?
    static let supported = navigation.union([preferences, toast, clipboard])

    struct Request: Encodable {
        let source: String
        let environment: [String: String]
        let arguments: [String: String]
        let preferences: [String: StoreGuestLaunchContext.OrdinaryPreference]
        let toast: Bool
        let clipboard: Bool
        let closeWindow: Bool
        let clearSearch: Bool
        let popToRoot: Bool
    }

    struct Response: Decodable {
        let effects: [Effect]
    }

    struct Effect: Decodable {
        enum Kind: String, Decodable { case toast, copy, close, clearSearch, popToRoot }
        let kind: Kind
        let value: String
    }

    package enum CloseBehavior: String, Sendable {
        case `default`, immediate, suspended
    }

    package enum Presentation: Sendable {
        case toast(RaycastStoreToastState.Presentation)
        case copy(String)
        case closeWindow(clearSearch: Bool, behavior: CloseBehavior)
        case clearSearch(forceScrollToTop: Bool)
        case popToRoot(clearSearch: Bool)
    }

    static func validate(_ response: Response, ticket: StoreGuestRunTicket) throws -> ([Presentation], Set<String>) {
        guard response.effects.count <= 8 else { throw MacOSRestrictedNoViewDriver.Failure.rejected }
        var toastState = RaycastStoreToastState()
        var needed: Set<String> = []
        var presentations: [Presentation] = []
        var pendingToastIndex: Int?
        for effect in response.effects {
            switch effect.kind {
            case .toast:
                needed.insert(toast)
                if let index = pendingToastIndex {
                    presentations.remove(at: index)
                    pendingToastIndex = nil
                }
                let object = try JSONSerialization.jsonObject(with: Data(effect.value.utf8)) as? [String: Any]
                if object?["operation"] as? String == "hide" {
                    try toastState.withdraw(effect.value, from: ticket.id)
                } else {
                    pendingToastIndex = presentations.count
                    presentations.append(.toast(try toastState.apply(effect.value, from: ticket.id)))
                }
            case .close:
                needed.insert(closeWindow)
                let fields = effect.value.split(separator: ":", omittingEmptySubsequences: false)
                guard let flag = fields.last, flag == "true" || flag == "false" else {
                    throw MacOSRestrictedNoViewDriver.Failure.rejected
                }
                if fields.count == 1 {
                    presentations.append(.closeWindow(clearSearch: flag == "true", behavior: .default))
                } else {
                    guard fields.count == 2, let behavior = CloseBehavior(rawValue: String(fields[0])),
                          behavior != .default else { throw MacOSRestrictedNoViewDriver.Failure.rejected }
                    presentations.append(.closeWindow(clearSearch: flag == "true", behavior: behavior))
                }
            case .clearSearch, .popToRoot:
                guard effect.value == "true" || effect.value == "false" else { throw MacOSRestrictedNoViewDriver.Failure.rejected }
                let flag = effect.value == "true"
                if effect.kind == .clearSearch {
                    needed.insert(clearSearch)
                    presentations.append(.clearSearch(forceScrollToTop: flag))
                    continue
                }
                needed.insert(popToRoot)
                presentations.append(.popToRoot(clearSearch: flag))
            case .copy:
                needed.insert(clipboard)
                guard !effect.value.isEmpty, effect.value.utf8.count <= 4096, !effect.value.contains("\0") else {
                    throw MacOSRestrictedNoViewDriver.Failure.rejected
                }
                presentations.append(.copy(effect.value))
            }
        }
        guard needed.isSubset(of: ticket.capabilities) else { throw MacOSRestrictedNoViewDriver.Failure.rejected }
        return (presentations, needed)
    }
}
