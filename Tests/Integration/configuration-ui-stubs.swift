import AppKit
import KeylaneCore

// Link the production configuration UI without the real app's controllers,
// services, filesystem stores or permission features.
enum ConfigurationStartupProbe {
    static var restoreHandled = false
    static var modelsCreated = 0
}
final class ConfigurationFixtureRegistry {
    var independentlyEnabledCommandIDs: Set<String> { [] }
}
final class ConfigurationFixtureSnippets {
    func templateContext(interactive: Bool) -> DynamicTemplate.Context { .init() }
}
final class Model {
    let snippets = ConfigurationFixtureSnippets()
    var apps: [URL] = []
    var launcherModules: ConfigurationFixtureRegistry? = .init()
    init() {
        precondition(ConfigurationStartupProbe.restoreHandled)
        ConfigurationStartupProbe.modelsCreated += 1
    }
}
final class Delegate: NSObject, NSApplicationDelegate {
    let model = Model()
    func hideLauncher() {}
}

// Native preference-panel fixtures deliberately exclude database preparation.
// The production data path is exercised by --verify-raycast-migration instead.
enum RaycastDataMigration {
    struct Prepared {
        var changes: [String: Any] = [:]
        var resources: [RaycastMigrationTransaction.Resource] = []
        var messages: [String] = []
    }
    static func prepare(_ data: RaycastMigrationData, current: [String:Any], root: URL, overwrite: Bool) throws -> Prepared {
        precondition(!data.hasData, "Native-panel fixture must not prepare user databases")
        return Prepared()
    }
}
