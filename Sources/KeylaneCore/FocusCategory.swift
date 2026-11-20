import Foundation

public struct FocusApplication: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct FocusCategory: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var applications: [FocusApplication]
    public var websites: [String]
    public init(id: UUID = UUID(), name: String, symbol: String = "target",
                applications: [FocusApplication] = [], websites: [String] = []) {
        self.id = id; self.name = name; self.symbol = symbol
        self.applications = applications; self.websites = websites
    }

    public func validated() throws -> Self {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.name.isEmpty, result.name.count <= 200, !symbol.isEmpty, symbol.count < 100,
              applications.count <= 1000, websites.count <= 1000 else { throw FocusError.invalidCategory }
        var apps = Set<String>()
        guard applications.allSatisfy({ !$0.id.isEmpty && $0.id.count < 300 &&
            $0.id.utf8.allSatisfy { (33...126).contains($0) && $0 != 34 && $0 != 92 && $0 != 47 } }) else {
            throw FocusError.invalidCategory
        }
        result.applications = applications.filter { apps.insert($0.id.lowercased()).inserted }
        result.websites = try Array(Set(websites.map {
            guard let host = FocusWebsite.host($0) else { throw FocusError.invalidWebsite }
            return host
        })).sorted()
        return result
    }

    public static func englishName(for id: UUID) -> String? {
        guard let index = builtIn.firstIndex(where: { $0.id == id }) else { return nil }
        return ["Gaming", "Social", "Travel", "News", "Streaming", "Shopping", "Messaging"][index]
    }
    public static let builtIn: [Self] = [
        ("Gaming", "游戏", "gamecontroller", ["store.steampowered.com", "epicgames.com", "twitch.tv"]),
        ("Social", "社交", "person.2", ["weibo.com", "xiaohongshu.com", "reddit.com", "instagram.com", "facebook.com", "x.com"]),
        ("Travel", "旅行", "airplane", ["trip.com", "booking.com", "airbnb.com"]),
        ("News", "新闻", "newspaper", ["news.qq.com", "news.163.com", "bbc.com", "cnn.com"]),
        ("Streaming", "影音", "play.circle", ["bilibili.com", "youtube.com", "netflix.com", "douyin.com"]),
        ("Shopping", "购物", "cart", ["taobao.com", "jd.com", "amazon.com", "pinduoduo.com"]),
        ("Messaging", "通讯", "message", ["web.whatsapp.com", "web.telegram.org", "discord.com"])
    ].enumerated().map { index, value in
        Self(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!,
             name: value.1, symbol: value.2, applications: [
                [FocusApplication(id: "com.valvesoftware.steam", name: "Steam"), FocusApplication(id: "com.epicgames.EpicGamesLauncher", name: "Epic Games")],
                [FocusApplication(id: "com.xingin.discover", name: "小红书")], [],
                [FocusApplication(id: "com.apple.news", name: "News")],
                [FocusApplication(id: "com.apple.TV", name: "TV"), FocusApplication(id: "com.spotify.client", name: "Spotify")], [],
                [FocusApplication(id: "com.tencent.xinWeChat", name: "微信"), FocusApplication(id: "com.tencent.qq", name: "QQ"), FocusApplication(id: "com.tinyspeck.slackmacgap", name: "Slack"), FocusApplication(id: "com.hnc.Discord", name: "Discord")]
             ][index], websites: value.3)
    }
}

public enum FocusError: LocalizedError {
    case invalidCategory, invalidWebsite, invalidDuration, invalidImport, storage
    public var errorDescription: String? {
        switch self {
        case .invalidCategory: "请填写分类名称，并检查应用列表。"
        case .invalidWebsite: "请输入有效的网站域名，例如 example.com。"
        case .invalidDuration: "请输入 1 分钟至 24 小时的时长，例如 45 min、1:30 或直到 18:00。"
        case .invalidImport: "无法识别分类文件。请选择 Keylane 导出的 Focus JSON 文件。"
        case .storage: "无法保存专注数据，请检查存储空间和文件访问权限。"
        }
    }
}

public enum FocusWebsite {
    public static func host(_ text: String) -> String? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !input.isEmpty, !input.contains(where: \.isWhitespace),
              let url = URL(string: input.contains("://") ? input : "https://" + input),
              ["http", "https"].contains(url.scheme ?? ""), url.user == nil, url.password == nil,
              var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard !host.isEmpty, !host.hasPrefix("."), host.count <= 253, !host.contains(".."),
              host.split(separator: ".").allSatisfy({ label in
                  label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-") &&
                  label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }) else { return nil }
        return host
    }

    public static func matches(_ host: String, rule: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let rule = rule.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !rule.isEmpty else { return false }
        if !rule.contains(".") { return host.split(separator: ".").contains(Substring(rule)) }
        return host == rule || host.hasSuffix("." + rule)
    }
}

public struct FocusConfiguration: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable { case block, allow }
    public var goal = ""
    public var duration: TimeInterval?
    public var mode: Mode = .block
    public var applications: [FocusApplication] = []
    public var websites: [String] = []
    public init() {}
    public func blocks(application id: String) -> Bool {
        let listed = applications.contains { $0.id.caseInsensitiveCompare(id) == .orderedSame }
        return mode == .block ? listed : !listed
    }
    public func blocks(website url: URL, allowAllWebsites: Bool) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased() else { return false }
        let listed = websites.contains { FocusWebsite.matches(host, rule: $0) }
        return mode == .block ? listed : !(listed || (websites.isEmpty && allowAllWebsites))
    }
}
