import Foundation

/// Native declarations describe effects, not permission. Omitted metadata stays unknown.
public struct AIActionImpact: Codable, Equatable, Sendable {
    public enum Effect: String, Codable, CaseIterable, Sendable {
        case computation, publicRead, privateRead, modelDisclosure, createFile, createDirectory, openApplication
        public var title: String {
            switch self {
            case .computation: "本机计算"
            case .publicRead: "读取公共信息"
            case .privateRead: "读取私人数据"
            case .modelDisclosure: "发送给所选模型"
            case .createFile: "创建文件"
            case .createDirectory: "创建文件夹"
            case .openApplication: "打开应用"
            }
        }
    }
    public let effects: Set<Effect>
    public init(_ effects: Set<Effect> = []) { self.effects = effects }
    public static let unspecified = Self()
    public static let computation = Self([.computation])
    public static let publicRead = Self([.publicRead])
    public static let privateRead = Self([.privateRead, .modelDisclosure])
    public static let createFile = Self([.createFile])
    public static let createDirectory = Self([.createDirectory])
    public static let openApplication = Self([.openApplication])
    public var containsSensitiveEffects: Bool {
        !effects.isDisjoint(with: [.privateRead, .modelDisclosure, .createFile, .createDirectory, .openApplication])
    }
    public var summary: String {
        Effect.allCases.filter { effects.contains($0) }.map(\.title).joined(separator: " · ")
    }
    /// A prepared target may add detail but cannot remove a declared effect.
    public func merging(_ other: Self) -> Self { .init(effects.union(other.effects)) }
}

public struct AIToolApprovalContext: Equatable, Sendable {
    public let title: String
    public let arguments: String
    public let impact: AIActionImpact
    public init(title: String, arguments: String, impact: AIActionImpact = .unspecified) {
        self.title = title; self.arguments = arguments; self.impact = impact
    }
}
