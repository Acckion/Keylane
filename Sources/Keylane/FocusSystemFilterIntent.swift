import AppIntents
import AppKit
import KeylaneCore

struct FocusCategoryEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "专注分类")
    static var defaultQuery = FocusCategoryEntityQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)") }
    init(_ category: FocusCategory) { id = category.id.uuidString; name = category.name }
}
struct FocusCategoryEntityQuery: EntityStringQuery {
    private func all() throws -> [FocusCategoryEntity] {
        let stored = try FocusStore(url: FocusStore.defaultURL).load()
        return (stored.categories + FocusCategory.builtIn).map(FocusCategoryEntity.init)
    }
    func entities(for identifiers: [String]) async throws -> [FocusCategoryEntity] {
        let available = try all()
        return try identifiers.map { identifier in
            guard let item = available.first(where: { $0.id.caseInsensitiveCompare(identifier) == .orderedSame }) else {
                throw FocusSystemFilterError.missingCategory
            }
            return item
        }
    }
    func suggestedEntities() async throws -> [FocusCategoryEntity] { try all() }
    func entities(matching string: String) async throws -> [FocusCategoryEntity] {
        try all().filter { string.isEmpty || $0.name.localizedCaseInsensitiveContains(string) }
    }
}
enum FocusFilterMode: String, AppEnum {
    case block, allow
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "专注模式")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .block: "屏蔽应用与网站", .allow: "允许应用与网站"
    ]
}

/// Stable type and parameter names are part of the system-saved filter identity.
struct KeylaneFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "管理专注会话"
    static var description: IntentDescription = "选择分类后，系统专注模式开启时自动运行，关闭时结束自动会话。手动会话优先。请先在 Keylane 中启用专注并完成权限授权。"
    @Parameter(title: "专注分类") var categories: [FocusCategoryEntity]?
    @Parameter(title: "模式", default: .block) var mode: FocusFilterMode
    @Parameter(title: "目标") var goal: String?
    var displayRepresentation: DisplayRepresentation {
        let names = categories?.map(\.name).joined(separator: "、") ?? "未选择分类"
        return .init(title: "Keylane 专注", subtitle: "\(mode == .block ? "屏蔽" : "允许")：\(names)")
    }
    func request() throws -> FocusSystemFilter {
        let ids = try (categories ?? []).map { value -> UUID in
            guard let id = UUID(uuidString: value.id) else { throw FocusSystemFilterError.missingCategory }
            return id
        }
        return .init(categories: ids, mode: mode == .block ? .block : .allow, goal: goal)
    }
    @MainActor func perform() async throws -> some IntentResult {
        try FocusFilterRuntime.deliver(request())
        return .result()
    }
}

/// The main app stays resident as a launcher. Reconcile once at startup as well
/// as receiving OS deliveries, including when no launcher window is visible.
enum FocusFilterRuntime {
    private static weak var controller: FocusController?
    private static var generation = 0
    private static var refreshTask: Task<Void, Never>?
    private static var activation: NSObjectProtocol?
    static func attach(_ value: FocusController) {
        detach(); controller = value
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                            object: nil, queue: .main) { _ in refresh() }
        refresh(recovering: true)
    }
    static func detach() {
        generation += 1; refreshTask?.cancel(); refreshTask = nil; controller = nil
        if let activation { NotificationCenter.default.removeObserver(activation) }; activation = nil
    }
    static func deliver(_ request: FocusSystemFilter) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        generation += 1; refreshTask?.cancel(); refreshTask = nil
        guard let controller else { throw FocusSystemFilterError.unavailable }
        try controller.applySystemFilter(request)
    }
    static func refresh(recovering: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        refreshTask?.cancel(); generation += 1
        let ticket = generation
        refreshTask = Task {
            do {
                let request: FocusSystemFilter
                do { request = try await KeylaneFocusFilter.current.request() }
                catch SetFocusFilterIntentError.notFound { request = .init() }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard generation == ticket, let controller else { return }
                    do { try controller.applySystemFilter(request, recovering: recovering) }
                    catch { controller.message = error.localizedDescription }
                }
            } catch {
                // A transient lookup failure is not a reset notification.
                await MainActor.run {
                    guard generation == ticket else { return }
                    controller?.message = "无法读取系统专注过滤条件：" + error.localizedDescription
                }
            }
        }
    }
}
