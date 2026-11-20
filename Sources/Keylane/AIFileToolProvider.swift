import Combine
import Foundation
import KeylaneCore

final class AIFileToolPreferences: ObservableObject {
    @Published var enabled: Bool { willSet { changed() } didSet { store.set(enabled, forKey: "ai.files.enabled") } }
    @Published private(set) var scopes: [AIFileToolScope]
    private(set) var lease = AIFileAccessLease()
    let service = AIFileToolService()
    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
        enabled = store.bool(forKey: "ai.files.enabled")
        scopes = store.data(forKey: "ai.files.scopes").flatMap { try? JSONDecoder().decode([AIFileToolScope].self, from: $0) } ?? []
    }
    private func changed() { lease.revoke(); lease = AIFileAccessLease() }
    func add(_ scope: AIFileToolScope) {
        guard scopes.count < 16, !scopes.contains(where: { $0.path == scope.path }) else { return }
        changed(); scopes.append(scope); persist()
    }
    func remove(_ path: String) { changed(); scopes.removeAll { $0.path == path }; persist() }
    private func persist() { store.set(try? JSONEncoder().encode(scopes), forKey: "ai.files.scopes") }
}

enum AIFileToolProvider {
    static func registrations(preferences: AIFileToolPreferences, project: AIChatProject?,
                              currentProject: @escaping @MainActor @Sendable () -> AIChatProject?) -> [AIToolRegistration] {
        guard preferences.enabled else { return [] }
        let lease = preferences.lease
        let service = preferences.service
        let configuredScopes = preferences.scopes
        var scopes = configuredScopes
        if let directory = project?.directory {
            let scope = AIFileToolScope(path: directory.standardizedFileURL.path, bookmark: project?.directoryBookmark)
            scopes.removeAll { $0.path == scope.path }; scopes.insert(scope, at: 0)
        }
        let snapshot = scopes
        let available: @MainActor @Sendable () -> Bool = { [weak preferences] in
            guard let preferences, preferences.enabled, preferences.lease === lease,
                  preferences.scopes == configuredScopes, currentProject() == project else { return false }
            return true
        }
        let root = AIToolParameter("root", description: "授权根句柄，如 root_1；未指定时使用默认根。", kind: .string(maximumLength: 32), required: false)
        let path = AIToolParameter("path", description: "相对授权根的路径；使用 keylane_file_roots 返回的根句柄，不要猜测本机绝对路径。", kind: .string(maximumLength: 4096))
        let limit = AIToolParameter("limit", description: "最多返回条数；文件读取时表示字节数（最大4096），目录时最大100。", kind: .integer(minimum: 1, maximum: 4096), required: false)
        let offset = AIToolParameter("offset", description: "文件字节偏移或目录条目偏移；续读使用 next_offset。", kind: .integer(minimum: 0, maximum: 1_073_741_824), required: false)
        let hidden = AIToolParameter("include_hidden", description: "是否包含隐藏名称，默认false。", kind: .boolean, required: false)
        let pattern = AIToolParameter("pattern", description: "相对目录的通配模式，支持 *、?、**，例如 **/*.swift。", kind: .string(maximumLength: 256))
        let count = AIToolParameter("limit", description: "最多匹配数，默认50，上限100。", kind: .integer(minimum: 1, maximum: 100), required: false)
        let depth = AIToolParameter("depth", description: "最多递归层数，默认6，上限12。", kind: .integer(minimum: 1, maximum: 12), required: false)
        let declarations: [(String, String, String, [AIToolParameter])] = [
            ("keylane_file_roots", "查看文件授权目录", "返回用户为 AI 配置的目录及默认目录，仅返回不含本机路径的根句柄；需要确认向当前接收方披露。", []),
            ("keylane_read_file", "读取文件或目录", "Read：读取普通 UTF-8 文件的有界片段，或按名称排序列出目录，不递归、不跟随符号链接。目录 limit 不得超过100。", [root, path, offset, limit, hidden]),
            ("keylane_file_info", "查看文件信息", "返回文件或目录的元数据与 revision，不读取正文。", [root, path]),
            ("keylane_glob", "匹配文件路径", "Glob：在授权目录内按通配模式寻找文件或目录，不读取正文、不启动索引。", [root, path, pattern, count, depth, hidden]),
            ("keylane_grep", "搜索文件文字", "Grep：在普通 UTF-8 文件中查找文字（非正则），返回路径、行号与短摘录；跳过凭据、隐藏项及超大文件，扫描有预算。", [root, path, pattern, .init("query", description: "要搜索的文字，忽略大小写。", kind: .string(maximumLength: 512)), count, depth]),
            ("keylane_write_file", "创建文本文件", "仅在匹配授权根中创建一级 UTF-8 文件，每次确认；不支持子目录写入、覆盖、replace 或编辑；原子创建不可用时失败。", [root, path, .init("content", description: "完整文本内容。", kind: .string(maximumLength: 12_000))]),
            ("keylane_create_directory", "创建文件夹", "仅在匹配授权根中创建一级文件夹，每次确认；不覆盖。子目录创建须先单独授权该父目录。", [root, path])
        ]
        return declarations.map { name, title, description, parameters in
            .init(definition: try! AIToolDefinition(name: name, title: title, description: description, parameters: parameters),
                  requiresConfirmation: true,
                  prepare: { arguments, recipient in
                      guard let recipient, !recipient.destination.isEmpty, available() else { throw AIToolContractError.unavailable }
                      try lease.check()
                      let plan = try await service.prepare(name, arguments: arguments, scopes: snapshot, lease: lease)
                      let display = try AIToolWire.string(plan.displayArguments)
                      let reviewValues: [String: AIToolValue] = [
                          "授权根（仅本机显示）": .array(plan.localRoots.map(AIToolValue.string)),
                          "规范化目标": .string(plan.localTarget),
                          "直接接收方": .string(recipient.destination), "模型": .string(recipient.model),
                          "操作参数": .object(plan.displayArguments)
                      ]
                      let encoder = JSONEncoder()
                      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                      let review = String(decoding: try encoder.encode(reviewValues), as: UTF8.self) +
                          "\n名称、元数据或读取正文将发送给上述直接接收方。根目录路径只在本机确认界面显示。"
                      return AIToolPreparedOperation(displayArguments: display, approvalArguments: review) {
                          guard available() else { throw CancellationError() }
                          let cancellation = AIFileAccessLease()
                          return try await withTaskCancellationHandler {
                              try Task.checkCancellation()
                              do { return try await service.execute(plan, lease: lease, cancellation: cancellation) }
                              catch let error as AIFileToolError { return try .init(text: error.localizedDescription, isError: true) }
                          } onCancel: { cancellation.revoke() }
                      }
                  }, available: available) { _ in
                // File effects and disclosure must never bypass preparation/approval.
                throw AIToolContractError.unavailable
            }
        }
    }

    static func discovery(_ tools: [AIToolRegistration]) -> AIToolRegistration {
        let definitions = tools.map(\.definition)
        return .init(definition: try! AIToolDefinition(name: "keylane_search_tools", title: "搜索工具", description: "Search Tools：搜索本次可用工具的名称、说明及参数，不执行工具或申请权限。", parameters: [
            .init("query", description: "工具用途或关键词，例如 read、文件、日历。", kind: .string(maximumLength: 256)),
            .init("limit", description: "最多返回条数，默认10。", kind: .integer(minimum: 1, maximum: 10), required: false)
        ])) { arguments in
            guard case .string(let query) = arguments["query"] else { throw AIToolContractError.invalidArguments }
            let limit: Int = { if case .number(let n) = arguments["limit"] { return Int(n) }; return 10 }()
            return try AIToolWire.result(["tools": .array(definitions.filter {
                query.isEmpty || ($0.name + " " + $0.title + " " + $0.description).localizedCaseInsensitiveContains(query)
            }.prefix(limit).map { .object(["name": .string($0.name), "title": .string($0.title), "description": .string($0.description), "input_schema": $0.inputSchema]) })])
        }
    }
}
