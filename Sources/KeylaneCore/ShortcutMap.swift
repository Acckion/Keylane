import Foundation

/// A snapshot of evidence, not a claim that every application shortcut is discoverable.
public struct ShortcutMapEntry: Identifiable, Equatable {
    public enum Source: String, CaseIterable { case keylane, application, system }
    public var id: String
    public var shortcut: Shortcut
    public var title: String
    public var source: Source
    public var applicationID: String?
    public var path: String
    public var enabled: Bool

    public init(id: String, shortcut: Shortcut, title: String, source: Source,
                applicationID: String? = nil, path: String = "", enabled: Bool = true) {
        self.id = id; self.shortcut = shortcut; self.title = title; self.source = source
        self.applicationID = applicationID; self.path = path; self.enabled = enabled
    }

    public enum Conflict: Equatable { case keylaneBinding, systemReserved, applicationOverlap }
    public func conflict(with shortcut: Shortcut, applicationID: String?) -> Conflict? {
        guard enabled, self.shortcut == shortcut else { return nil }
        switch source {
        case .keylane: return .keylaneBinding
        case .system: return .systemReserved
        case .application: return applicationID != nil && self.applicationID == applicationID ? .applicationOverlap : nil
        }
    }
}

public enum ShortcutMapConversion {
    /// AX uses Shift=1, Option=2, Control=4, NoCommand=8, unlike Carbon.
    public static func menu(virtualKey: Int?, modifiers: Int?) -> Shortcut? {
        guard let key = virtualKey, (0..<128).contains(key) else { return nil }
        let flags = modifiers ?? 0
        // Unknown flags cannot be represented by our keyboard and must not be guessed.
        guard flags & ~15 == 0 else { return nil }
        return Shortcut(key: UInt32(key), modifiers: (flags & 1 != 0 ? 512 : 0)
            | (flags & 2 != 0 ? 2048 : 0) | (flags & 4 != 0 ? 4096 : 0) | (flags & 8 == 0 ? 256 : 0))
    }

    public static func registrationError(_ status: Int32) -> String {
        switch status {
        case -9878: return "快捷键已被其他全局注册占用，macOS 未提供所属应用。"
        case -50: return "macOS 不支持这个快捷键参数（-50）。"
        default: return "快捷键注册失败（\(status)），无法据此判断是否被占用。"
        }
    }
}
