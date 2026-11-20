import Foundation
import CryptoKit

/// Module metadata only. Constructing or enumerating this value never reads user content.
public struct AIActionDefinition: Equatable, Sendable {
    public let commandID: CommandID
    public let title: String
    public let instructions: String
    public let maximumInputBytes: Int
    public let acceptsQuestion: Bool
    public init(commandID: CommandID, title: String, instructions: String, maximumInputBytes: Int = 32_000, acceptsQuestion: Bool = false) {
        self.commandID = commandID; self.title = title; self.instructions = instructions
        self.maximumInputBytes = maximumInputBytes; self.acceptsQuestion = acceptsQuestion
    }
    public func validate() throws {
        guard !commandID.rawValue.isEmpty, !title.isEmpty, title.utf8.count <= 256,
              !instructions.isEmpty, instructions.utf8.count <= 16_384,
              (1...64_000).contains(maximumInputBytes) else { throw AIActionError.invalidDefinition }
    }
}

public enum AIActionError: LocalizedError {
    case invalidDefinition, unavailable, staleSource, inputTooLarge, emptyInput
    public var errorDescription: String? {
        switch self {
        case .invalidDefinition: "AI 动作声明无效。"
        case .unavailable: "命令、权限或模型已变化，请重新打开。"
        case .staleSource: "来源内容已变化或已移除，请重新选择。"
        case .inputTooLarge: "内容超过本次处理上限，请缩小范围后重试。"
        case .emptyInput: "没有可处理的文字。"
        }
    }
}

public struct AIActionContext: Sendable, Equatable {
    public let sourceID: String
    public let title: String
    public let text: String
    public let fingerprint: String
    public init(sourceID: String, title: String, text: String, fingerprint: String? = nil) {
        self.sourceID = sourceID; self.title = title; self.text = text
        self.fingerprint = fingerprint ?? Self.digest(text)
    }
    public static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func validate(maximumBytes: Int) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIActionError.emptyInput }
        guard text.utf8.count <= maximumBytes else { throw AIActionError.inputTooLarge }
    }
}
