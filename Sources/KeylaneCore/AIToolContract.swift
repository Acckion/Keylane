import Foundation

/// A bounded JSON value keeps tool arguments/results independent of any provider or UI framework.
public enum AIToolValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: AIToolValue]), array([AIToolValue]), null

    public init(from decoder: Decoder) throws {
        guard decoder.codingPath.count <= 16 else { throw AIToolContractError.invalidArguments }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self), value.isFinite { self = .number(value) }
        else if let value = try? container.decode([String: AIToolValue].self) { self = .object(value) }
        else if let value = try? container.decode([AIToolValue].self) { self = .array(value) }
        else { throw AIToolContractError.invalidArguments }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public static func arguments(_ text: String) throws -> [String: Self] {
        guard text.utf8.count <= 16_384, let data = text.data(using: .utf8),
              case .object(let values) = try JSONDecoder().decode(Self.self, from: data) else {
            throw AIToolContractError.invalidArguments
        }
        return values
    }
}

public enum AIToolContractError: Error, Equatable, Sendable {
    case invalidDefinition, duplicateTool, invalidArguments, unavailable, limitReached, invalidResult
}

/// Describes a deliberately small strict object schema; providers adapt it to their wire format.
public struct AIToolParameter: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case string(maximumLength: Int)
        case integer(minimum: Int, maximum: Int)
        case boolean
        case choice([String])
    }
    public let name: String
    public let description: String
    public let kind: Kind
    public let required: Bool

    public init(_ name: String, description: String, kind: Kind, required: Bool = true) {
        self.name = name
        self.description = description
        self.kind = kind
        self.required = required
    }

    fileprivate func accepts(_ value: AIToolValue) -> Bool {
        switch (kind, value) {
        case (.string(let maximum), .string(let text)): return text.utf8.count <= maximum
        case (.integer(let minimum, let maximum), .number(let number)):
            return number.isFinite && number.rounded() == number && number >= Double(minimum) && number <= Double(maximum)
        case (.boolean, .bool): return true
        case (.choice(let options), .string(let text)): return options.contains(text)
        default: return false
        }
    }
}

/// Catalog metadata never executes a tool or requests a system permission.
public struct AIToolDefinition: Equatable, Sendable {
    public let name: String
    public let title: String
    public let description: String
    public let parameters: [AIToolParameter]

    public init(name: String, title: String, description: String, parameters: [AIToolParameter] = []) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard !name.isEmpty, name.utf8.count <= 64, name.unicodeScalars.allSatisfy(allowed.contains),
              !title.isEmpty, title.utf8.count <= 256, !description.isEmpty, description.utf8.count <= 4_096,
              parameters.count <= 16, Set(parameters.map(\.name)).count == parameters.count else {
            throw AIToolContractError.invalidDefinition
        }
        for parameter in parameters {
            guard !parameter.name.isEmpty, parameter.name.utf8.count <= 64,
                  parameter.name.unicodeScalars.allSatisfy(allowed.contains), parameter.description.utf8.count <= 1_024 else {
                throw AIToolContractError.invalidDefinition
            }
            switch parameter.kind {
            case .string(let maximum): guard (1...16_384).contains(maximum) else { throw AIToolContractError.invalidDefinition }
            case .integer(let minimum, let maximum): guard minimum <= maximum else { throw AIToolContractError.invalidDefinition }
            case .choice(let values):
                guard !values.isEmpty, values.count <= 64, Set(values).count == values.count,
                      values.allSatisfy({ $0.utf8.count <= 512 }) else { throw AIToolContractError.invalidDefinition }
            case .boolean: break
            }
        }
        self.name = name
        self.title = title
        self.description = description
        self.parameters = parameters
    }

    public func validate(_ arguments: [String: AIToolValue]) throws {
        let names = Set(parameters.map(\.name))
        guard Set(arguments.keys).isSubset(of: names) else { throw AIToolContractError.invalidArguments }
        for parameter in parameters {
            guard let value = arguments[parameter.name] else {
                if parameter.required { throw AIToolContractError.invalidArguments }
                continue
            }
            guard parameter.accepts(value) else { throw AIToolContractError.invalidArguments }
        }
    }

    public var inputSchema: AIToolValue {
        var properties: [String: AIToolValue] = [:]
        for parameter in parameters {
            var property: [String: AIToolValue] = ["description": .string(parameter.description)]
            switch parameter.kind {
            case .string(let maximum): property["type"] = .string("string"); property["maxLength"] = .number(Double(maximum))
            case .integer(let minimum, let maximum):
                property["type"] = .string("integer")
                property["minimum"] = .number(Double(minimum)); property["maximum"] = .number(Double(maximum))
            case .boolean: property["type"] = .string("boolean")
            case .choice(let values): property["type"] = .string("string"); property["enum"] = .array(values.map(AIToolValue.string))
            }
            properties[parameter.name] = .object(property)
        }
        return .object(["type": .string("object"), "properties": .object(properties),
                        "required": .array(parameters.filter(\.required).map { .string($0.name) }), "additionalProperties": .bool(false)])
    }
}

public struct AIToolCall: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let arguments: [String: AIToolValue]

    private enum CodingKeys: String, CodingKey { case id, name, arguments }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(String.self, forKey: .id), name: values.decode(String.self, forKey: .name),
                      arguments: values.decode([String: AIToolValue].self, forKey: .arguments))
    }

    public init(id: String, name: String, arguments: [String: AIToolValue]) throws {
        guard !id.isEmpty, id.utf8.count <= 256, !name.isEmpty, name.utf8.count <= 64,
              id.rangeOfCharacter(from: .controlCharacters) == nil,
              try JSONEncoder().encode(arguments).count <= 16_384 else { throw AIToolContractError.invalidArguments }
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct AIToolResult: Codable, Equatable, Sendable {
    public let text: String
    public let isError: Bool

    private enum CodingKeys: String, CodingKey { case text, isError }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(text: values.decode(String.self, forKey: .text), isError: values.decode(Bool.self, forKey: .isError))
    }

    public init(text: String, isError: Bool = false) throws {
        guard text.utf8.count <= 32_768 else { throw AIToolContractError.invalidResult }
        self.text = text
        self.isError = isError
    }
}

/// A per-request catalog is a value snapshot; listing it cannot start background services.
public struct AIToolCatalog: Sendable {
    public let definitions: [AIToolDefinition]
    private let byName: [String: AIToolDefinition]

    public init(_ definitions: [AIToolDefinition]) throws {
        guard definitions.count <= 32 else { throw AIToolContractError.invalidDefinition }
        guard Set(definitions.map(\.name)).count == definitions.count else { throw AIToolContractError.duplicateTool }
        self.definitions = definitions
        byName = Dictionary(uniqueKeysWithValues: definitions.map { ($0.name, $0) })
    }

    public func validate(_ call: AIToolCall) throws {
        guard let definition = byName[call.name] else { throw AIToolContractError.unavailable }
        try definition.validate(call.arguments)
    }
}

/// One budget is owned by one generation; a denied/failed call still consumes its admission.
public struct AIToolRunBudget: Sendable {
    public private(set) var rounds = 0
    public private(set) var callCount = 0
    public private(set) var resultBytes = 0
    private var calls: Set<String> = []
    private var completed: Set<String> = []
    public init() {}

    public mutating func beginRound() throws {
        guard rounds < 6 else { throw AIToolContractError.limitReached }
        rounds += 1
    }

    public mutating func admit(_ batch: [AIToolCall]) throws {
        let ids = Set(batch.map(\.id))
        guard ids.count == batch.count, ids.isDisjoint(with: calls) else { throw AIToolContractError.invalidArguments }
        guard callCount + batch.count <= 12 else { throw AIToolContractError.limitReached }
        calls.formUnion(ids)
        callCount += batch.count
    }

    public mutating func record(_ result: AIToolResult, for callID: String) throws {
        guard calls.contains(callID), !completed.contains(callID) else { throw AIToolContractError.invalidResult }
        guard resultBytes + result.text.utf8.count <= 131_072 else { throw AIToolContractError.limitReached }
        completed.insert(callID)
        resultBytes += result.text.utf8.count
    }
}
