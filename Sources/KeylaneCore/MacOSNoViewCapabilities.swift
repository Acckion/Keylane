import Foundation
import OSLog

package enum MacOSNoViewCapabilities {
    package typealias Presenter = @MainActor @Sendable (Presentation) -> Void
    static let preferences = "preferences.read"
    static let selectedPreferences = "preferences.selection.read"
    static let secretPreferences = "preferences.secrets.read"
    static let toast = "feedback.toast"
    static let clipboard = "clipboard.write"
    static let closeWindow = "navigation.close"
    static let clearSearch = "navigation.clearSearch"
    static let popToRoot = "navigation.popToRoot"
    static let openPreferences = "preferences.open"
    static let diagnostics = "diagnostics.capture"
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
    static let supported = navigation.union([preferences, selectedPreferences, secretPreferences, toast, clipboard, openPreferences, diagnostics, MacOSReviewedRaycastAssets.capability, MacOSReviewedRaycastAssets.supportCapability, MacOSReviewedRaycastCache.capability,
                                             MacOSReviewedRaycastLocalStorage.capability])

    struct Request: Encodable {
        let cacheSnapshot: String?
        let localStorageSnapshot: String?
        let source: String
        let environment: [String: String]
        let arguments: [String: String]
        let preferences: [String: StoreGuestLaunchContext.OrdinaryPreference]
        let preferenceFields: [RaycastExtensionManifest.Field]
        let packagedAssets: [String: Data]?
        let supportFiles: [String: Data]?
        let toast: Bool
        let clipboard: Bool
        let closeWindow: Bool
        let clearSearch: Bool
        let popToRoot: Bool
        let openPreferences: Bool
        let diagnostics: Bool
    }

    struct Response: Decodable {
        let effects: [Effect]
        let cache: Data?
        let localStorage: Data?
        let diagnostics: [Diagnostic]?
        let supportFiles: Data?

        init(effects: [Effect], cache: Data? = nil, localStorage: Data? = nil, diagnostics: [Diagnostic]? = nil, supportFiles: Data? = nil) {
            self.effects = effects
            self.cache = cache
            self.localStorage = localStorage
            self.diagnostics = diagnostics
            self.supportFiles = supportFiles
        }
    }

    package struct Diagnostic: Codable, Sendable {
        package enum Category: String, Codable, Sendable {
            case undefined, boolean, number, string, bigint, symbol, object, function
        }
        package let exceptionCategory: Category?
        package let peakResidentBytes: UInt64?
        package let residentBytes: UInt64?

        func validate() throws {
            guard (exceptionCategory != nil) != (peakResidentBytes != nil),
                  peakResidentBytes.map({ $0 > 0 && $0 <= (1 << 40) }) ?? true,
                  residentBytes.map({ current in peakResidentBytes.map { current > 0 && current <= $0 } ?? false }) ?? true else {
                throw MacOSRestrictedNoViewDriver.Failure.rejected
            }
        }

        func log() {
            let log = Logger(subsystem: "org.keylane.launcher", category: "ExtensionDiagnostics")
            if let exceptionCategory {
                log.debug("Extension exception category: \(exceptionCategory.rawValue, privacy: .public)")
            } else if let peakResidentBytes {
                log.debug("Extension peak resident bytes: \(peakResidentBytes, privacy: .public)")
            }
        }
    }

    struct Effect: Decodable {
        enum Kind: String, Decodable { case toast, copy, close, clearSearch, popToRoot, openPreferences }
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
        case diagnostics(installationID: String, generation: UInt64, samples: [Diagnostic])
        case openPreferences(installationID: String, generation: UInt64, commandID: String?)
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
            case .openPreferences:
                guard effect.value == "extension" || effect.value == "command" else {
                    throw MacOSRestrictedNoViewDriver.Failure.rejected
                }
                needed.insert(openPreferences)
                presentations.append(.openPreferences(installationID: ticket.installation.id, generation: ticket.installation.generation,
                    commandID: effect.value == "command" ? ticket.commandID : nil))
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
