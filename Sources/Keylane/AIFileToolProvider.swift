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

struct AIFileToolIndexSource: Sendable {
    let isCurrent: @MainActor @Sendable () -> Bool
    let search: @MainActor @Sendable (String, String) async throws -> [String]
}

enum AIFileToolProvider {
    static func registrations(preferences: AIFileToolPreferences, project: AIChatProject?,
                              currentProject: @escaping @MainActor @Sendable () -> AIChatProject?, index: AIFileToolIndexSource? = nil) -> [AIToolRegistration] {
        guard preferences.enabled else { return [] }
        let lease = preferences.lease
        let service = preferences.service
        let readSession = AIFileToolService.ReadSession()
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
        let count = AIToolParameter("limit", description: "本页匹配数，默认50，上限100；有cursor时可继续。", kind: .integer(minimum: 1, maximum: 100), required: false)
        let depth = AIToolParameter("depth", description: "最多递归层数，默认6，上限12。", kind: .integer(minimum: 1, maximum: 12), required: false)
        var declarations: [(String, String, String, [AIToolParameter])] = [
            ("keylane_file_roots", "查看文件授权目录", "返回用户为 AI 配置的目录及默认目录，仅返回不含本机路径的根句柄；需要确认向当前接收方披露。", []),
            ("keylane_read_file", "读取文件或目录", "Read：读取 UTF-8 文本或有文字PDF，或按名称列出目录。正文每页最多4096字节，目录每页最多100条；有cursor时用keylane_read_result继续，引用仅本次请求有效。PDF最大8MiB/100页，不OCR、不跟随符号链接。", [root, path, offset, limit, hidden, .init("page", description: "PDF 起始页（从1开始），不可与offset同时指定；扫描件不自动OCR。", kind: .integer(minimum: 1, maximum: 100), required: false)]),
            ("keylane_file_info", "查看文件信息", "返回文件或目录的元数据与 revision，不读取正文。", [root, path]),
            ("keylane_glob", "匹配文件路径", "Glob：在授权目录内按通配模式寻找文件或目录，不读取正文、不启动索引。", [root, path, pattern, count, depth, hidden]),
            ("keylane_grep", "搜索文件文字", "Grep：在普通 UTF-8 文件中查找文字（非正则），返回路径、行号与短摘录；跳过凭据、隐藏项及超大文件，扫描有预算。", [root, path, pattern, .init("query", description: "要搜索的文字，忽略大小写。", kind: .string(maximumLength: 512)), count, depth]),
            ("keylane_write_file", "创建文本文件", "仅在匹配授权根中创建一级 UTF-8 文件，每次确认；不支持子目录写入、覆盖、replace 或编辑；安全创建不可用时不回退。目录被外部移动时结果可能无法确认，勿自动重试。", [root, path, .init("content", description: "完整文本内容。", kind: .string(maximumLength: 12_000))]),
            ("keylane_create_directory", "创建文件夹", "仅在匹配授权根中创建一级文件夹，每次确认；不覆盖。子目录创建须先单独授权该父目录。目录被外部移动时结果可能无法确认，勿自动重试。", [root, path])
        ]
        declarations.append(("keylane_read_result", "继续读取结果", "读取本次请求返回的opaque cursor，仍逐次确认；不是文件路径或永久文件引用。文本limit最大4096字节，列表limit最大100条；来源变化后需重新发起。", [
            .init("cursor", description: "上一次文件工具返回的原样cursor。", kind: .string(maximumLength: 64)), limit
        ]))
        if index != nil {
            declarations.append(("keylane_search_indexed_files", "搜索已索引文件", "仅在本次匹配授权根与文件搜索范围的交集中查找已索引的文件名；不启动扫描，不读取正文。结果使用根句柄和相对路径，仍需确认；之后用公共Read读取。", [root,
                .init("path", description: "相对根的查询目录。", kind: path.kind),
                .init("query", description: "要搜索的文件名或关键词。", kind: .string(maximumLength: 256)), count]))
        }
        return declarations.map { name, title, description, parameters in
            let impact: AIActionImpact = name == "keylane_write_file" ? .createFile
                : name == "keylane_create_directory" ? .createDirectory : .privateRead
            let toolAvailable: @MainActor @Sendable () -> Bool = {
                available() && (name != "keylane_search_indexed_files" || index?.isCurrent() == true)
            }
            return .init(definition: try! AIToolDefinition(name: name, title: title, description: description, parameters: parameters),
                  requiresConfirmation: true, impact: impact,
                  prepare: { arguments, recipient in
                      guard let recipient, !recipient.destination.isEmpty, toolAvailable() else { throw AIToolContractError.unavailable }
                      try lease.check()
                      try readSession.bind(to: recipient.runID)
                      let plan = try await service.prepare(name, arguments: arguments, scopes: snapshot, lease: lease, session: readSession)
                      let indexBound = plan.sourceTool == "keylane_search_indexed_files"
                      let operationAvailable: @MainActor @Sendable () -> Bool = { toolAvailable() && (!indexBound || index?.isCurrent() == true) }
                      guard operationAvailable() else { throw AIToolContractError.unavailable }
                      let display = try AIToolWire.string(plan.displayArguments)
                      let quota: String
                      if name == "keylane_read_result" {
                          quota = "仅续读原文件版本或快照，不重新扫描。当前页文本最多4096字节，列表最多100条。"
                      } else {
                          switch name {
                          case "keylane_read_file": quota = "文本仅读当前片段；PDF原文件最多8MiB/100页、提取文字最多2MiB；目录本机快照最多10000名称/2MiB。当前页正文最多4096字节或列表100条，更多内容须再次确认。"
                          case "keylane_glob", "keylane_grep": quota = "本机扫描最多10000名称、1000匹配；文字搜索单文件最多1MiB、累计8MiB。当前页最多100条，更多结果保存在本次请求的私有快照中，续读须再次确认。"
                          case "keylane_search_indexed_files": quota = "只查已有文件名索引，最多200候选，不扫描或读取正文。当前页最多100条，更多结果须再次确认。"
                          default: quota = "仅执行所列操作；覆盖和编辑不支持。"
                          }
                      }
                      let reviewValues: [String: AIToolValue] = [
                          "授权根（仅本机显示）": .array(plan.localRoots.map(AIToolValue.string)),
                          "规范化目标": .string(plan.localTarget),
                          "直接接收方": .string(recipient.destination), "模型": .string(recipient.model),
                          "操作参数": .object(plan.displayArguments), "本次读取范围与限额": .string(quota)
                      ]
                      let encoder = JSONEncoder()
                      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                      let review = String(decoding: try encoder.encode(reviewValues), as: UTF8.self) +
                          "\n名称、元数据或读取正文将发送给上述直接接收方。根目录路径只在本机确认界面显示。"
                      let creationNotice = ["keylane_write_file", "keylane_create_directory"].contains(name)
                          ? "\n创建绑定已确认的目录对象。其他进程仍可能移动它；创建后核对失败不能证明未写入。结果无法确认时请人工核对，勿直接重试；不自动回滚。"
                          : ""
                      return AIToolPreparedOperation(displayArguments: display, approvalArguments: review + creationNotice, isCurrent: operationAvailable, impact: impact) {
                          guard operationAvailable() else { throw CancellationError() }
                          let cancellation = AIFileAccessLease()
                          return try await withTaskCancellationHandler {
                              try Task.checkCancellation()
                              do {
                                  var paths: [String] = []
                                  if name == "keylane_search_indexed_files", let index, case .string(let query) = arguments["query"] {
                                      paths = try await index.search(query, plan.localTarget)
                                      guard operationAvailable() else { throw CancellationError() }
                                  }
                                  let result = try await service.execute(plan, lease: lease, cancellation: cancellation, session: readSession, indexedPaths: paths)
                                  guard operationAvailable() else { throw CancellationError() }
                                  return result
                              }
                              catch let error as AIFileDocumentText.Failure { return try .init(text: error.localizedDescription, isError: true) }
                              catch let error as AIFileToolError { return try .init(text: error.localizedDescription, isError: true) }
                          } onCancel: { cancellation.revoke() }
                      }
                  }, available: toolAvailable) { _ in
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
        ]), impact: .publicRead) { arguments in
            guard case .string(let query) = arguments["query"] else { throw AIToolContractError.invalidArguments }
            let limit: Int = { if case .number(let n) = arguments["limit"] { return Int(n) }; return 10 }()
            return try AIToolWire.result(["tools": .array(definitions.filter {
                query.isEmpty || ($0.name + " " + $0.title + " " + $0.description).localizedCaseInsensitiveContains(query)
            }.prefix(limit).map { .object(["name": .string($0.name), "title": .string($0.title), "description": .string($0.description), "input_schema": $0.inputSchema]) })])
        }
    }
}
