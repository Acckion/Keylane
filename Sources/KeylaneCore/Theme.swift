import Foundation

public enum ThemeError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

public struct ThemeRGBA: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double
    public init(_ value: String) throws {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard [3, 4, 6, 8].contains(value.count), value.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) else {
            throw ThemeError.invalid("颜色需要使用 #RGB、#RGBA、#RRGGBB 或 #RRGGBBAA。")
        }
        if value.count <= 4 { value = value.map { "\($0)\($0)" }.joined() }
        if value.count == 6 { value += "FF" }
        guard let number = UInt32(value, radix: 16) else { throw ThemeError.invalid("颜色格式无效。") }
        red = Double((number >> 24) & 255) / 255
        green = Double((number >> 16) & 255) / 255
        blue = Double((number >> 8) & 255) / 255
        alpha = Double(number & 255) / 255
    }
    public var hex: String {
        let bytes = [red, green, blue, alpha].map { Int(($0 * 255).rounded()) }
        let channels = alpha == 1 ? Array(bytes.prefix(3)) : bytes
        return "#" + channels.map { String(format: "%02X", $0) }.joined()
    }
}

public enum ThemeAppearance: String, Codable, CaseIterable, Sendable { case light, dark }
public enum ThemeColorRole: String, Codable, CaseIterable, Sendable {
    case text, selection, loader, red, orange, yellow, green, blue, purple, magenta
    public var title: String {
        switch self {
        case .text: "文字"
        case .selection: "选中项"
        case .loader: "加载指示器"
        case .red: "红色"
        case .orange: "橙色"
        case .yellow: "黄色"
        case .green: "绿色"
        case .blue: "蓝色"
        case .purple: "紫色"
        case .magenta: "品红色"
        }
    }
}

public struct ThemeBackground: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case solid, gradient }
    public var kind: Kind = .solid
    public var color: String
    public var endColor: String
    public var angle: Double = 135
    public init(color: String, endColor: String? = nil) { self.color = color; self.endColor = endColor ?? color }
}

public struct ThemeDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var appearance: ThemeAppearance
    public var background: ThemeBackground
    public var colors: [String: String]
    public init(id: UUID = UUID(), name: String, appearance: ThemeAppearance, background: ThemeBackground, colors: [String: String]) {
        self.id = id; self.name = name; self.appearance = appearance; self.background = background; self.colors = colors
    }
    public func color(_ role: ThemeColorRole) -> ThemeRGBA {
        (try? ThemeRGBA(colors[role.rawValue] ?? "")) ?? (try! ThemeRGBA(appearance == .dark ? "#F4F4F5" : "#242426"))
    }
    public func validated() throws -> Self {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.name.isEmpty, copy.name.count <= 80, copy.name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ThemeError.invalid("主题名称需要 1–80 个字符，且不能包含控制字符。")
        }
        guard background.angle.isFinite, (0...360).contains(background.angle) else { throw ThemeError.invalid("渐变角度需要在 0–360° 之间。") }
        copy.background.color = try ThemeRGBA(background.color).hex
        copy.background.endColor = try ThemeRGBA(background.endColor).hex
        guard Set(colors.keys) == Set(ThemeColorRole.allCases.map(\.rawValue)) else { throw ThemeError.invalid("主题颜色配置不完整或包含未知颜色。") }
        for role in ThemeColorRole.allCases { copy.colors[role.rawValue] = try ThemeRGBA(colors[role.rawValue]!).hex }
        return copy
    }
    public func duplicate(name: String? = nil) -> Self {
        var copy = self; copy.id = UUID(); copy.name = name ?? String(self.name.prefix(77)) + " 副本"; return copy
    }
    public static let darkID = UUID(uuidString: "AF874002-9C89-4B92-A01D-000000000001")!
    public static let lightID = UUID(uuidString: "AF874002-9C89-4B92-A01D-000000000002")!
    public var isBuiltin: Bool { Self.builtins.contains { $0.id == id } }
    public var usesSystemMaterial: Bool { id == Self.darkID || id == Self.lightID }
    public static let builtins: [Self] = {
        let common = ["selection": "#4C83FF", "loader": "#538CFF", "red": "#F05B65", "orange": "#EC9953", "yellow": "#E4C957", "green": "#50BB8D", "blue": "#508EEA", "purple": "#A782E3", "magenta": "#D574B6"]
        func theme(_ id: UUID, _ name: String, _ appearance: ThemeAppearance, _ background: String, _ text: String) -> Self {
            .init(id: id, name: name, appearance: appearance, background: .init(color: background), colors: common.merging(["text": text]) { _, value in value })
        }
        var harbor = theme(UUID(uuidString: "AF874002-9C89-4B92-A01D-000000000003")!, "雾港", .dark, "#182B38F2", "#E3F0F3")
        harbor.background.kind = .gradient; harbor.background.endColor = "#28384FF2"; harbor.colors["selection"] = "#509FAB"
        var dusk = theme(UUID(uuidString: "AF874002-9C89-4B92-A01D-000000000004")!, "暮色", .dark, "#322532F5", "#FFE6D6")
        dusk.background.kind = .gradient; dusk.background.endColor = "#44312DF5"; dusk.colors["selection"] = "#BD7B64"
        var forest = theme(UUID(uuidString: "AF874002-9C89-4B92-A01D-000000000005")!, "松间", .light, "#EEF2E9FA", "#243E34")
        forest.colors["selection"] = "#53876B"; forest.colors["loader"] = "#53876B"
        var morning = theme(UUID(uuidString: "AF874002-9C89-4B92-A01D-000000000006")!, "晨光", .light, "#FFF0DFFA", "#5C3C2E")
        morning.background.kind = .gradient; morning.background.endColor = "#F4E5E5FA"; morning.colors["selection"] = "#BE7B50"
        return [theme(darkID, "Keylane 深色", .dark, "#242426", "#F4F4F5"), theme(lightID, "Keylane 浅色", .light, "#F1F1F3", "#242426"), harbor, dusk, forest, morning]
    }()
}

public struct ThemeLibrary: Codable, Equatable, Sendable {
    public var custom: [ThemeDefinition] = []
    public var lightID: UUID = ThemeDefinition.lightID
    public var darkID: UUID = ThemeDefinition.darkID
    public init() {}
    public var all: [ThemeDefinition] { ThemeDefinition.builtins + custom }
    public func theme(for appearance: ThemeAppearance) -> ThemeDefinition {
        all.first { $0.id == (appearance == .dark ? darkID : lightID) && $0.appearance == appearance }
            ?? ThemeDefinition.builtins.first { $0.id == (appearance == .dark ? ThemeDefinition.darkID : ThemeDefinition.lightID) }!
    }
    public mutating func save(_ theme: ThemeDefinition) throws {
        guard !theme.isBuiltin else { throw ThemeError.invalid("内置主题只读，请先复制。") }
        let value = try theme.validated()
        guard custom.count < 100 || custom.contains(where: { $0.id == value.id }) else { throw ThemeError.invalid("最多保存 100 个自定义主题。") }
        if let index = custom.firstIndex(where: { $0.id == value.id }) { custom[index] = value }
        else { custom.append(value) }
        // Changing an assigned theme's appearance restores the other slot to its native default.
        if lightID == value.id && value.appearance != .light { lightID = ThemeDefinition.lightID }
        if darkID == value.id && value.appearance != .dark { darkID = ThemeDefinition.darkID }
    }
    public mutating func assign(_ id: UUID) throws {
        guard let theme = all.first(where: { $0.id == id }) else { throw ThemeError.invalid("主题不存在，请先保存。") }
        if theme.appearance == .dark { darkID = id } else { lightID = id }
    }
    public mutating func remove(_ id: UUID) throws {
        guard custom.contains(where: { $0.id == id }) else { throw ThemeError.invalid("内置主题不能删除。") }
        custom.removeAll { $0.id == id }
        if lightID == id { lightID = ThemeDefinition.lightID }
        if darkID == id { darkID = ThemeDefinition.darkID }
    }
    public func validated() throws -> Self {
        guard custom.count <= 100, Set(custom.map(\.id)).count == custom.count, !custom.contains(where: \.isBuiltin) else { throw ThemeError.invalid("主题库包含重复或保留标识。") }
        var copy = self; copy.custom = try custom.map { try $0.validated() }
        copy.lightID = copy.theme(for: .light).id; copy.darkID = copy.theme(for: .dark).id
        return copy
    }
}

public enum ThemeArchive {
    private struct Envelope: Codable { var schemaVersion = 1; let theme: ThemeDefinition }
    public static let maximumBytes = 64_000
    public static func data(_ theme: ThemeDefinition) throws -> Data {
        let data = try JSONEncoder().encode(Envelope(theme: theme.validated()))
        guard data.count <= maximumBytes else { throw ThemeError.invalid("主题数据过大。") }
        return data
    }
    public static func decode(_ data: Data) throws -> ThemeDefinition {
        guard data.count <= maximumBytes else { throw ThemeError.invalid("主题文件不能超过 64 KB。") }
        let value = try JSONDecoder().decode(Envelope.self, from: data)
        guard value.schemaVersion == 1 else { throw ThemeError.invalid("不支持此主题格式版本。") }
        // Import is always a new editable draft; it cannot replace a built-in or existing theme.
        return try value.theme.validated().duplicate(name: value.theme.name)
    }
    public static func url(_ theme: ThemeDefinition) throws -> URL {
        var parts = URLComponents(); parts.scheme = "keylane"; parts.host = "theme"
        parts.queryItems = [URLQueryItem(name: "data", value: try data(theme).base64EncodedString())]
        return parts.url!
    }
    public static func decode(_ text: String) throws -> ThemeDefinition {
        guard text.utf8.count <= maximumBytes * 2 else { throw ThemeError.invalid("主题数据过大。") }
        if let url = URL(string: text), url.scheme?.lowercased() == "keylane" {
            guard text.utf8.count <= maximumBytes * 2, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.host == "theme", parts.path.isEmpty, parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
                  let items = parts.queryItems, items.count == 1, items[0].name == "data", let value = items[0].value,
                  let bytes = Data(base64Encoded: value) else { throw ThemeError.invalid("主题分享链接无效。") }
            return try decode(bytes)
        }
        return try decode(Data(text.utf8))
    }
}
