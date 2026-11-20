import AppKit
import Combine
import KeylaneCore

extension Notification.Name { static let keylaneThemeChanged = Notification.Name("KeylaneThemeChanged") }

final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    @Published private(set) var library: ThemeLibrary
    let defaults: UserDefaults
    private let key = "themes.library.v1"
    private var readFailed = false
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key) {
            do {
                guard data.count <= 1_000_000 else { throw ThemeError.invalid("主题库数据过大。") }
                library = try JSONDecoder().decode(ThemeLibrary.self, from: data).validated()
            }
            catch { library = .init(); readFailed = true }
        } else { library = .init(); readFailed = defaults.object(forKey: key) != nil }
    }
    func save(_ theme: ThemeDefinition) throws { var next = library; try next.save(theme); try persist(next) }
    func assign(_ id: UUID) throws { var next = library; try next.assign(id); try persist(next) }
    func remove(_ id: UUID) throws { var next = library; try next.remove(id); try persist(next) }
    private func persist(_ value: ThemeLibrary) throws {
        guard !readFailed else { throw ThemeError.invalid("主题库读取失败，当前更改尚未保存。") }
        let value = try value.validated()
        let data = try JSONEncoder().encode(value)
        guard data.count <= 1_000_000 else { throw ThemeError.invalid("主题库数据过大。") }
        defaults.set(data, forKey: key)
        library = value
        NotificationCenter.default.post(name: .keylaneThemeChanged, object: self)
    }
    func theme(for appearance: NSAppearance) -> ThemeDefinition {
        library.theme(for: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light)
    }
}
