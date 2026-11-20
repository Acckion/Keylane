import Foundation

/// An inventory of the source, not a claim that all records have been migrated.
public struct RaycastImportCategory: Equatable, Sendable {
    public enum Status: String, Sendable { case partial, unsupported, invalid }
    public let source: String
    public let schemaVersion: Int?
    public let arrayRecordCount: Int
    public let fields: [String]
    public let status: Status
    public let explanation: String

    public var summary: String {
        let version = schemaVersion.map { "v\($0)" } ?? "未知版本"
        let state: String
        switch status { case .partial: state = "部分可迁移"; case .unsupported: state = "尚未支持"; case .invalid: state = "结构或版本不支持" }
        return "\(source)（\(version)，直接数组记录 \(arrayRecordCount) 条）：\(state)。\(explanation)"
    }

    static func inventory(_ root: [String: Any]) -> [Self] {
        root.keys.sorted().map { name in
            guard let category = root[name] as? [String: Any],
                  let version = category["schemaVersion"] as? Int, version > 0 else {
                return .init(source: name, schemaVersion: nil, arrayRecordCount: 0, fields: [], status: .invalid,
                             explanation: "未把该内容写入 Keylane。")
            }
            let count = category.values.compactMap { ($0 as? [Any])?.count }.reduce(0, +)
            let status: Status
            let explanation: String
            if version == 1 && name == "settings" && category["commands"] is [[String: Any]] {
                status = .partial; explanation = "仅迁移已验证的通用设置、命令映射；其他字段保留未支持状态。"
            } else if version == 1 && name == "quicklinks" && category["quicklinks"] is [[String: Any]] {
                status = .partial; explanation = "解析可表达的链接；不支持的占位符、目标和应用配置会明确跳过。"
            } else if version == (name == "ai" ? 2 : 1), let field = ["snippets":"snippets", "ai":"chats", "clipboardHistory":"clipboardEntries", "emoji":"emojis", "focusCategories":"focusCategories"][name], (category[field] is [[String:Any]] || (name == "ai" && category["commands"] is [[String:Any]])), let detail = [
                "snippets": "迁移纯文本片段、关键词和标签；富文本、图片及不兼容模板跳过。",
                "ai": "迁移文本聊天、思考文本和自定义提示词；不迁移模型账号、工具结果、附件或 Agent 配置。导入的历史只读查看。",
                "clipboardHistory": "仅迁移文本记录和来源、时间、使用次数；不读取外部图片或文件。",
                "emoji": "迁移已有目录中的使用记录和自定义关键词。",
                "focusCategories": "仅迁移专注分类中的应用与网站；不启动专注会话。"
            ][name] {
                status = .partial; explanation = detail
            } else if ["settings", "quicklinks", "snippets", "ai", "clipboardHistory", "emoji", "focusCategories"].contains(name) {
                status = .invalid; explanation = "该类别的版本或记录结构与当前适配器不匹配。"
            } else {
                status = .unsupported; explanation = "已识别此类别的存在，尚未转换其内容；原导出文件不受影响。"
            }
            return .init(source: name, schemaVersion: version, arrayRecordCount: count,
                         fields: category.keys.sorted(), status: status, explanation: explanation)
        }
    }
}
