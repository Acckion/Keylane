import Foundation

public struct ModuleID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct CommandID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct PageID: RawRepresentable, Hashable, Sendable {
    public static let root = PageID(rawValue: "Commands")
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct LauncherCommandDeclaration: Identifiable, Sendable {
    public enum Destination: Equatable, Sendable {
        case action
        case page(PageID)
        case settings(String?)
    }

    public let id: CommandID
    public let title: String
    public let detail: String
    public let symbol: String
    public let keywords: [String]
    public let destination: Destination
    public let settingsPage: String?

    public init(id: CommandID, title: String, detail: String, symbol: String, keywords: [String],
                destination: Destination = .action, settingsPage: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.keywords = keywords
        self.destination = destination
        self.settingsPage = settingsPage
    }
}

public enum LauncherCommandNamespace: Equatable, Sendable {
    case exact(CommandID)
    case prefix(String)

    public func contains(_ id: CommandID) -> Bool {
        switch self {
        case .exact(let exact): return id == exact
        case .prefix(let prefix): return id.rawValue.hasPrefix(prefix)
        }
    }

    public func overlaps(_ other: Self) -> Bool {
        switch (self, other) {
        case (.exact(let id), _): return other.contains(id)
        case (_, .exact(let id)): return contains(id)
        case (.prefix(let lhs), .prefix(let rhs)): return lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
        }
    }
}

public struct LauncherModuleDeclaration: Sendable {
    public let id: ModuleID
    public let commands: [LauncherCommandDeclaration]
    public let pages: [PageID]
    public let settingsPages: [String]
    public let providers: [LauncherCommandNamespace]

    public init(id: ModuleID, commands: [LauncherCommandDeclaration] = [], pages: [PageID] = [], settingsPages: [String] = [], providers: [LauncherCommandNamespace] = []) {
        self.id = id
        self.commands = commands
        self.pages = pages
        self.settingsPages = settingsPages
        self.providers = providers
    }
}

/// Validates the full native catalog before the host exposes any commands.
public struct LauncherModuleCatalog {
    public enum ValidationError: Error, Equatable {
        case duplicateModule(ModuleID)
        case duplicateCommand(CommandID)
        case duplicatePage(PageID)
        case reservedPage(PageID)
        case duplicateSettingsPage(String)
        case overlappingProvider(LauncherCommandNamespace)
        case providerOwnsStaticCommand(CommandID)
        case missingPage(CommandID, PageID)
        case missingSettingsPage(CommandID, String)
    }

    public let commands: [LauncherCommandDeclaration]

    public init(modules: [LauncherModuleDeclaration]) throws {
        var moduleIDs = Set<ModuleID>()
        var commandIDs = Set<CommandID>()
        var pages = Set<PageID>()
        var settings = Set<String>()
        for module in modules {
            guard moduleIDs.insert(module.id).inserted else { throw ValidationError.duplicateModule(module.id) }
            for command in module.commands {
                guard commandIDs.insert(command.id).inserted else { throw ValidationError.duplicateCommand(command.id) }
            }
            for page in module.pages {
                guard page != .root else { throw ValidationError.reservedPage(page) }
                guard pages.insert(page).inserted else { throw ValidationError.duplicatePage(page) }
            }
            for page in module.settingsPages {
                guard settings.insert(page).inserted else { throw ValidationError.duplicateSettingsPage(page) }
            }
        }
        var namespaces: [LauncherCommandNamespace] = []
        for namespace in modules.flatMap(\.providers) {
            if namespaces.contains(where: { $0.overlaps(namespace) }) {
                throw ValidationError.overlappingProvider(namespace)
            }
            if let conflict = commandIDs.first(where: { namespace.contains($0) }) {
                throw ValidationError.providerOwnsStaticCommand(conflict)
            }
            namespaces.append(namespace)
        }
        let commands = modules.flatMap(\.commands)
        for command in commands {
            if case let .page(page) = command.destination, !pages.contains(page) {
                throw ValidationError.missingPage(command.id, page)
            }
            if case let .settings(page?) = command.destination, !settings.contains(page) {
                throw ValidationError.missingSettingsPage(command.id, page)
            }
            if let page = command.settingsPage, !settings.contains(page) {
                throw ValidationError.missingSettingsPage(command.id, page)
            }
        }
        self.commands = commands
    }
}
