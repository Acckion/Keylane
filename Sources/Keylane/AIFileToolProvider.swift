import Combine
import Foundation
import KeylaneCore

final class AIFileToolPreferences: ObservableObject {
    @Published var enabled: Bool { didSet { changed(); store.set(enabled, forKey: "ai.files.enabled") } }
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
        var scopes = preferences.scopes
        if let directory = project?.directory {
            let scope = AIFileToolScope(path: directory.standardizedFileURL.path, bookmark: project?.directoryBookmark)
            scopes.removeAll { $0.path == scope.path }; scopes.insert(scope, at: 0)
        }
        let snapshot = scopes
        let available: @MainActor @Sendable () -> Bool = { [weak preferences] in
            guard let preferences, preferences.enabled, preferences.lease === lease,
                  currentProject() == project else { return false }
            return true
        }
        let path = AIToolParameter("path", description: "已授权目录内的绝对路径、~/ 路径或相对默认目录的路径。先调用 keylane_file_roots 查看已配置目录。", kind: .string(maximumLength: 4096))
        let limit = AIToolParameter("limit", description: "最多返回条数；文件读取时表示字节数（最大4096），目录时最大100。", kind: .integer(minimum: 1, maximum: 4096), required: false)
        let offset = AIToolParameter("offset", description: "文件字节偏移或目录条目偏移；续读使用 next_offset。", kind: .integer(minimum: 0, maximum: 1_073_741_824), required: false)
        let hidden = AIToolParameter("include_hidden", description: "是否包含隐藏名称，默认false。", kind: .boolean, required: false)
        let pattern = AIToolParameter("pattern", description: "相对目录的通配模式，支持 *、?、**，例如 **/*.swift。", kind: .string(maximumLength: 256))
        let count = AIToolParameter("limit", description: "最多匹配数，默认50，上限100。", kind: .integer(minimum: 1, maximum: 100), required: false)
        let depth = AIToolParameter("depth", description: "最多递归层数，默认6，上限12。", kind: .integer(minimum: 1, maximum: 12), required: false)
        let revision = AIToolParameter("expected_revision", description: "必须使用最近 Read/File Info 返回的 revision，变化后重新读取。", kind: .string(maximumLength: 64))
        let declarations: [(String, String, String, [AIToolParameter], Bool)] = [
            ("keylane_file_roots", "查看文件授权目录", "返回用户为 AI 配置的目录及默认目录，不扫描文件；实际访问仍检查权限。", [], false),
            ("keylane_read_file", "读取文件或目录", "Read：读取普通 UTF-8 文件的有界片段，或按名称排序列出目录，不递归、不跟随符号链接。目录 limit 不得超过100。", [path, offset, limit, hidden], false),
            ("keylane_file_info", "查看文件信息", "返回文件或目录的元数据与 revision，不读取正文。", [path], false),
            ("keylane_glob", "匹配文件路径", "Glob：在授权目录内按通配模式寻找文件或目录，不读取正文、不启动索引。", [path, pattern, count, depth, hidden], false),
            ("keylane_grep", "搜索文件文字", "Grep：在普通 UTF-8 文件中查找文字（非正则），返回路径、行号与短摘录；跳过凭据、隐藏项及超大文件，扫描有预算。", [path, pattern, .init("query", description: "要搜索的文字，忽略大小写。", kind: .string(maximumLength: 512)), count, depth], false),
            ("keylane_write_file", "写入文本文件", "Write：新建或替换 UTF-8 文本，每次确认。默认create且拒绝覆盖；replace必须先Read/File Info获取revision。", [path, .init("content", description: "完整文本内容。", kind: .string(maximumLength: 12_000)), .init("mode", description: "create（默认）或replace。", kind: .choice(["create", "replace"]), required: false), .init("expected_revision", description: revision.description, kind: revision.kind, required: false)], true),
            ("keylane_edit_file", "修改文本文件", "Edit：用精确文本替换修改 UTF-8 文件，每次确认；先读取并提供当前revision，默认拒绝匹配多处。", [path, revision, .init("old_text", description: "原始精确文本，不能为空。", kind: .string(maximumLength: 4096)), .init("new_text", description: "替换后的文本。", kind: .string(maximumLength: 8192)), .init("replace_all", description: "明确替换全部匹配，默认false。", kind: .boolean, required: false)], true),
            ("keylane_create_directory", "创建文件夹", "在已存在的授权父目录内创建一个新文件夹，每次确认；不覆盖、不递归创建父目录。", [path], true)
        ]
        return declarations.map { name, title, description, parameters, confirmation in
            .init(definition: try! AIToolDefinition(name: name, title: title, description: description, parameters: parameters),
                  requiresConfirmation: confirmation,
                  confirmationRequired: { arguments in
                      if name == "keylane_read_file", case .string(let path) = arguments["path"] {
                          return AIFileToolService.isSensitive(path) || (snapshot.first.map { AIFileToolService.isSensitive($0.path) } ?? false)
                      }
                      return false
                  }, available: available) { arguments in
                try lease.check()
                if name == "keylane_file_roots" {
                    return try AIToolWire.result(["directories": .array(snapshot.map { .string($0.path) }),
                        "default_directory": snapshot.first.map { .string($0.path) } ?? .null])
                }
                do { return try await service.execute(name, arguments: arguments, scopes: snapshot, check: { try lease.check() }) }
                catch let error as AIFileToolError { return try .init(text: error.localizedDescription, isError: true) }
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
