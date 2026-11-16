import AppKit

// Link the production configuration UI without the real app's controllers,
// services, filesystem stores or permission features.
enum ConfigurationStartupProbe {
    static var restoreHandled = false
    static var modelsCreated = 0
}
final class ConfigurationFixtureRegistry {
    var independentlyEnabledCommandIDs: Set<String> { [] }
}
final class Model {
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
