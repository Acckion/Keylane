import Foundation
import Yams

public struct CustomProviderDocument: Decodable {
    /// Length-prefix UTF-8 components so IDs containing delimiters cannot alias.
    public static func modelIdentity(providerID: String, modelID: String) -> String {
        "\(providerID.utf8.count):\(providerID)\(modelID.utf8.count):\(modelID)"
    }

    public struct Provider: Decodable {
        public let id: String
        public let name: String
        public let base_url: String
        public let api_keys: [String: String]?
        public let models: [Model]
        public let additional_parameters: Parameters?
    }

    public struct Model: Decodable {
        public let id: String
        public let name: String?
        public let provider: String?
        public let context: Int?
        public let abilities: [String: Ability]?
    }

    public struct Ability: Decodable { public let supported: Bool? }
    public enum Parameters: Decodable {
        case object([String: Parameters]), array([Parameters]), string(String), number(Double), bool(Bool), null

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(Double.self) { self = .number(value) }
            else if let value = try? container.decode(String.self) { self = .string(value) }
            else if let value = try? container.decode([String: Parameters].self) { self = .object(value) }
            else { self = .array(try container.decode([Parameters].self)) }
        }

        private var value: Any {
            switch self {
            case .object(let fields): fields.mapValues(\.value)
            case .array(let entries): entries.map(\.value)
            case .string(let value): value
            case .number(let value): value
            case .bool(let value): value
            case .null: NSNull()
            }
        }

        public func json() throws -> String {
            guard case .object(let fields) = self,
                  Set(fields.keys).isDisjoint(with: ["model", "messages", "stream", "tools", "tool_choice", "system"]) else {
                throw Failure("additional_parameters 不可覆盖模型、对话、流式或工具字段。")
            }
            return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
        }
    }

    public struct Failure: LocalizedError {
        public let errorDescription: String?
        public init(_ message: String) { errorDescription = message }
    }
    public let providers: [Provider]

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1_048_576, let yaml = String(data: data, encoding: .utf8) else {
            throw Failure("providers.yaml 须为小于 1 MB 的 UTF-8 文件。")
        }
        let document = try YAMLDecoder().decode(Self.self, from: yaml)
        var providerIDs = Set<String>()
        for provider in document.providers {
            guard !provider.id.isEmpty, providerIDs.insert(provider.id).inserted,
                  !provider.name.isEmpty, !provider.models.isEmpty,
                  let url = URL(string: provider.base_url), let host = url.host,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host)) else {
                throw Failure("提供商 \(provider.id) 的 ID、名称、地址或模型列表无效。")
            }
            if let parameters = provider.additional_parameters { _ = try parameters.json() }
            var modelIDs = Set<String>()
            for model in provider.models {
                guard !model.id.isEmpty, modelIDs.insert(model.id).inserted,
                      model.context.map({ $0 > 0 }) != false else {
                    throw Failure("提供商 \(provider.id) 的模型 ID 重复、为空或上下文长度无效。")
                }
                if let key = model.provider, provider.api_keys?[key] == nil {
                    throw Failure("模型 \(model.id) 引用了不存在的 api_keys 条目。")
                }
                if model.provider == nil, (provider.api_keys?.count ?? 0) > 1 {
                    throw Failure("模型 \(model.id) 须指定 provider，以选择多个 api_keys 中的一项。")
                }
            }
        }
        return document
    }
}
