import Foundation

public struct SettingsItem: Identifiable, Equatable {
    public let id: String
    public let page: String
    public let title: String
    public let keywords: String
    public static let applicationScopes = SettingsItem(id: "scopes", page: "applications", title: "应用搜索范围", keywords: "应用 文件夹 applications folders scope")
    public static let applicationFavorites = SettingsItem(id: "favorites", page: "applications", title: "收藏", keywords: "排序 favorite pin")
    public static let screenshotColumns = SettingsItem(id: "screenshot-columns", page: "screenshots", title: "截图列数", keywords: "screenshots grid columns 截屏 缩略图")
    public static let screenshotScopes = SettingsItem(id: "screenshot-scopes", page: "screenshots", title: "截图搜索范围", keywords: "screenshots folders scope 截屏 录屏")
    public static let screenshotText = SettingsItem(id: "screenshot-text", page: "screenshots", title: "截图文字识别", keywords: "screenshots OCR text cloud 图片内容 云端")

    public static let all: [SettingsItem] = [
        .init(id: "appearance", page: "general", title: "外观", keywords: "主题 深色 浅色 系统 界面 大小 appearance theme dark light size"),
        .init(id: "window-mode", page: "general", title: "窗口模式与紧凑收藏", keywords: "紧凑 展开 收藏 compact expanded favorites"),
        .init(id: "position", page: "general", title: "窗口位置", keywords: "屏幕 显示器 居中 记住 position screen"),
        .init(id: "keyboard", page: "general", title: "Keylane 热键与键盘", keywords: "唤起 导航 修饰键 hyperkey hotkey keyboard"),
        .init(id: "login", page: "general", title: "登录时启动", keywords: "开机 自启动 startup login"),
        .init(id: "glass", page: "general", title: "液态玻璃与辅助功能", keywords: "透明度 动画 对比度 glass transparency motion accessibility"),
        applicationScopes,
        .init(id: "file-search-scope", page: "files", title: "文件搜索范围", keywords: "文件 Spotlight 索引 file search index scope"),
        .init(id: "file-search-inline", page: "files", title: "在主界面搜索文件", keywords: "主搜索 启动器 直接 搜索 文件 launcher inline file search"),
        screenshotColumns,
        screenshotScopes,
        screenshotText,
        applicationFavorites,
        .init(id: "menu-bar", page: "menu-bar", title: "菜单栏项目", keywords: "显示 隐藏 状态 图标 menu bar status item"),
        .init(id: "system-shortcuts", page: "shortcuts", title: "Apple 快捷指令", keywords: "别名 热键 apple shortcuts alias hotkey"),
        .init(id: "calendar-access", page: "calendar", title: "连接系统日历", keywords: "日程 权限 calendar events permission"),
        .init(id: "calendar-menu-bar", page: "calendar", title: "日历菜单栏摘要", keywords: "下一个 日程 日期 calendar agenda menu bar"),
        .init(id: "calendar-selection", page: "calendar", title: "选择显示的日历", keywords: "日历 筛选 账户 calendar account filter"),
        .init(id: "capture", page: "clipboard", title: "记录剪贴板历史", keywords: "文字 图片 文件 保留 采集 置顶 OCR capture clipboard history"),
        .init(id: "export", page: "notes", title: "导出便笺", keywords: "笔记 备份 notes backup export"),
        .init(id: "quicklink", page: "links", title: "默认快捷链接", keywords: "网址 url quicklink"),
        .init(id: "directory", page: "advanced", title: "资料目录", keywords: "数据 sqlite directory storage"),
        .init(id: "privacy", page: "advanced", title: "隐私与遥测", keywords: "privacy telemetry"),
        .init(id: "version", page: "about", title: "关于 Keylane", keywords: "版本 许可 about version license"),
        .init(id: "status", page: "about", title: "开发状态", keywords: "功能 限制 roadmap status")
    ]
    public static func search(_ query: String, in items: [SettingsItem] = all) -> [SettingsItem] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }
        return items.filter { item in words.allSatisfy { (item.title + " " + item.keywords).localizedCaseInsensitiveContains($0) } }
    }
}
public enum NavigationBounds {
    public static func move(_ index: Int, by delta: Int, count: Int) -> Int { min(max(0, index + delta), max(0, count - 1)) }
}
