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

    public static let appearance = SettingsItem(id: "appearance", page: "general", title: "外观", keywords: "主题 深色 浅色 系统 界面 大小 appearance theme dark light size")
    public static let windowMode = SettingsItem(id: "window-mode", page: "general", title: "窗口模式与紧凑收藏", keywords: "紧凑 展开 收藏 compact expanded favorites")
    public static let windowPosition = SettingsItem(id: "position", page: "general", title: "窗口位置", keywords: "屏幕 显示器 居中 记住 position screen")
    public static let keyboard = SettingsItem(id: "keyboard", page: "general", title: "Keylane 热键与键盘", keywords: "唤起 导航 修饰键 hyperkey hotkey keyboard")
    public static let login = SettingsItem(id: "login", page: "general", title: "登录时启动", keywords: "开机 自启动 startup login")
    public static let glass = SettingsItem(id: "glass", page: "general", title: "液态玻璃与辅助功能", keywords: "透明度 动画 对比度 glass transparency motion accessibility")
    public static let fileSearchScope = SettingsItem(id: "file-search-scope", page: "files", title: "文件搜索范围", keywords: "文件 Spotlight 索引 file search index scope")
    public static let fileSearchInline = SettingsItem(id: "file-search-inline", page: "files", title: "在主界面搜索文件", keywords: "主搜索 启动器 直接 搜索 文件 launcher inline file search")
    public static let menuBar = SettingsItem(id: "menu-bar", page: "menu-bar", title: "菜单栏项目", keywords: "显示 隐藏 状态 图标 menu bar status item")
    public static let systemShortcuts = SettingsItem(id: "system-shortcuts", page: "shortcuts", title: "Apple 快捷指令", keywords: "别名 热键 apple shortcuts alias hotkey")
    public static let accessibilityPermission = SettingsItem(id: "permission-accessibility", page: "permissions", title: "辅助功能权限", keywords: "权限 授权 粘贴 窗口 菜单 accessibility permission")
    public static let inputMonitoringPermission = SettingsItem(id: "permission-input-monitoring", page: "permissions", title: "输入监控", keywords: "权限 授权 键盘 Hyperkey input monitoring permission")
    public static let contactsPermission = SettingsItem(id: "permission-contacts", page: "permissions", title: "联系人权限", keywords: "授权 通讯录 contacts permission")
    public static let automationPermission = SettingsItem(id: "permission-automation", page: "permissions", title: "自动化权限", keywords: "授权 Finder 快捷指令 automation permission")
    public static let folderPermissions = SettingsItem(id: "permission-folders", page: "permissions", title: "文件与文件夹权限", keywords: "授权 搜索范围 截图 files folders permission")
    public static let calendarAccess = SettingsItem(id: "calendar-access", page: "permissions", title: "日历权限", keywords: "日程 权限 calendar events permission")
    public static let calendarMenuBar = SettingsItem(id: "calendar-menu-bar", page: "calendar", title: "日历菜单栏摘要", keywords: "下一个 日程 日期 calendar agenda menu bar")
    public static let calendarSelection = SettingsItem(id: "calendar-selection", page: "calendar", title: "选择显示的日历", keywords: "日历 筛选 账户 calendar account filter")
    public static let clipboardCapture = SettingsItem(id: "capture", page: "clipboard", title: "记录剪贴板历史", keywords: "文字 图片 文件 保留 采集 置顶 OCR capture clipboard history")
    public static let clipboardRetention = SettingsItem(id: "clipboard-retention", page: "clipboard", title: "剪贴板保留历史记录", keywords: "保留时间 clipboard retention")
    public static let clipboardRecognition = SettingsItem(id: "clipboard-recognition", page: "clipboard", title: "剪贴板文字识别", keywords: "图片 快速 准确 clipboard OCR recognition")
    public static let clipboardExclusions = SettingsItem(id: "clipboard-exclusions", page: "clipboard", title: "不记录这些应用", keywords: "剪贴板 排除 应用 clipboard disabled applications")
    public static let noteExport = SettingsItem(id: "export", page: "notes", title: "导出便笺", keywords: "笔记 备份 notes backup export")
    public static let quicklink = SettingsItem(id: "quicklink", page: "links", title: "默认快捷链接", keywords: "网址 url quicklink")
    public static let dataDirectory = SettingsItem(id: "directory", page: "advanced", title: "资料目录", keywords: "数据 sqlite directory storage")
    public static let privacy = SettingsItem(id: "privacy", page: "advanced", title: "隐私与遥测", keywords: "privacy telemetry")
    public static let version = SettingsItem(id: "version", page: "about", title: "关于 Keylane", keywords: "版本 许可 about version license")
    public static let developmentStatus = SettingsItem(id: "status", page: "about", title: "开发状态", keywords: "功能 限制 roadmap status")

    public static let all: [SettingsItem] = [
        appearance,
        windowMode,
        windowPosition,
        keyboard,
        login,
        glass,
        applicationScopes,
        fileSearchScope,
        fileSearchInline,
        screenshotColumns,
        screenshotScopes,
        screenshotText,
        applicationFavorites,
        menuBar,
        systemShortcuts,
        accessibilityPermission,
        inputMonitoringPermission,
        calendarAccess,
        contactsPermission,
        automationPermission,
        folderPermissions,
        calendarMenuBar,
        calendarSelection,
        clipboardCapture,
        clipboardRetention,
        clipboardRecognition,
        clipboardExclusions,
        noteExport,
        quicklink,
        dataDirectory,
        privacy,
        version,
        developmentStatus
    ]
    public static func search(_ query: String, in items: [SettingsItem] = all) -> [SettingsItem] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }
        return items.filter { item in words.allSatisfy { (item.title + " " + item.keywords).localizedCaseInsensitiveContains($0) } }
    }
}
public enum NavigationBounds {
    public static func move(_ index: Int, by delta: Int, count: Int) -> Int { min(max(0, index + delta), max(0, count - 1)) }

    /// Keeps the column when crossing rows or sections and clamps only on a short row.
    public static func moveGrid(section: Int, item: Int, by delta: Int, vertical: Bool,
                                columns: Int, counts: [Int]) -> (section: Int, item: Int)? {
        guard counts.indices.contains(section), (0..<counts[section]).contains(item),
              columns > 0, delta == -1 || delta == 1 else { return nil }
        let count = counts[section]
        if vertical {
            let row = item / columns + delta
            if row >= 0 && row <= (count - 1) / columns {
                return (section, min(row * columns + item % columns, count - 1))
            }
        } else if (0..<count).contains(item + delta) {
            return (section, item + delta)
        }

        var next = section + delta
        while counts.indices.contains(next) {
            let nextCount = counts[next]
            if nextCount > 0 {
                let boundary = delta < 0 ? nextCount - 1 : 0
                let target = vertical ? (boundary / columns) * columns + item % columns : boundary
                return (next, min(target, nextCount - 1))
            }
            next += delta
        }
        return (section, item)
    }
}
