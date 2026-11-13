import Foundation

public struct SettingsItem: Identifiable, Equatable {
    public let id: String
    public let page: String
    public let title: String
    public let keywords: String
    public init(id: String, page: String, title: String, keywords: String) {
        self.id = id
        self.page = page
        self.title = title
        self.keywords = keywords
    }

    public static let applicationAutoQuit = SettingsItem(id: "application-auto-quit", page: "applications", title: "自动退出", keywords: "闲置 退出 auto quit idle")
    public static let applicationScopes = SettingsItem(id: "scopes", page: "applications", title: "应用搜索范围", keywords: "应用 文件夹 applications folders scope")
    public static let applicationFavorites = SettingsItem(id: "favorites", page: "applications", title: "收藏", keywords: "排序 favorite pin")
    public static let screenshotColumns = SettingsItem(id: "screenshot-columns", page: "screenshots", title: "截图列数", keywords: "screenshots grid columns 截屏 缩略图")
    public static let screenshotScopes = SettingsItem(id: "screenshot-scopes", page: "screenshots", title: "截图搜索范围", keywords: "screenshots folders scope 截屏 录屏")
    public static let screenshotText = SettingsItem(id: "screenshot-text", page: "screenshots", title: "截图文字识别", keywords: "screenshots OCR text cloud 图片内容 云端")

    public static let appearance = SettingsItem(id: "appearance", page: "general", title: "外观", keywords: "主题 深色 浅色 系统 界面 大小 appearance theme dark light size")
    public static let windowMode = SettingsItem(id: "window-mode", page: "general", title: "窗口模式与紧凑收藏", keywords: "紧凑 展开 收藏 compact expanded favorites")
    public static let windowPosition = SettingsItem(id: "position", page: "launcher", title: "窗口位置", keywords: "屏幕 显示器 居中 记住 position screen")
    public static let launcherReturnDelay = SettingsItem(id: "launcher-return", page: "launcher", title: "返回主搜索", keywords: "返回 重置 查询 隐藏 超时 launcher root reset")
    public static let rootSearchSensitivity = SettingsItem(id: "root-search-sensitivity", page: "launcher", title: "主搜索灵敏度", keywords: "启动器 模糊 匹配 排序 search sensitivity")
    public static let launcherSearchHistory = SettingsItem(id: "launcher-search-history", page: "launcher", title: "搜索历史", keywords: "启动器 近期查询 清除 重置 search history")
    public static let rootFileContentSearch = SettingsItem(id: "root-file-content", page: "launcher", title: "在主搜索中匹配文件内容", keywords: "启动器 正文 PDF file content")
    public static let rootContactsSearch = SettingsItem(id: "root-contacts", page: "launcher", title: "在主搜索中显示联系人", keywords: "启动器 通讯录 contacts")
    public static let launcherFallbackCommands = SettingsItem(id: "launcher-fallbacks", page: "launcher", title: "备选命令", keywords: "启动器 回退 后备 搜索 fallback commands")
    public static let keyboard = SettingsItem(id: "keyboard-launcher-hotkey", page: "keyboard", title: "Keylane 热键", keywords: "唤起 导航 修饰键 hyperkey hotkey keyboard")
    public static let keyboardEscapeBehavior = SettingsItem(id: "keyboard-escape", page: "keyboard", title: "Escape 键行为", keywords: "键盘 返回 隐藏 esc escape")
    public static let keyboardCloseWindow = SettingsItem(id: "keyboard-close-window", page: "keyboard", title: "Escape 键关闭窗口", keywords: "键盘 设置 关闭 esc escape")
    public static let keyboardInputSource = SettingsItem(id: "keyboard-input-source", page: "keyboard", title: "自动切换输入源", keywords: "键盘 输入法 ABC IME input source")
    public static let keyboardNavigation = SettingsItem(id: "keyboard-navigation", page: "keyboard", title: "导航绑定", keywords: "键盘 方向键 Vim Emacs navigation")
    public static let keyboardPageNavigation = SettingsItem(id: "keyboard-page-navigation", page: "keyboard", title: "页面导航键", keywords: "键盘 方括号 前进 后退 navigation brackets")
    public static let keyboardHyperKey = SettingsItem(id: "keyboard-hyper", page: "keyboard", title: "Hyper Key", keywords: "键盘 修饰键 大写锁定 Caps Lock Shift Hyperkey")
    public static let hotkeys = SettingsItem(id: "grouped-hotkeys", page: "hotkeys", title: "快捷键", keywords: "扩展 分组 别名 hotkeys shortcuts aliases")
    public static let login = SettingsItem(id: "login", page: "general", title: "登录时启动", keywords: "开机 自启动 startup login")
    public static let glass = SettingsItem(id: "glass", page: "general", title: "液态玻璃与辅助功能", keywords: "透明度 动画 对比度 glass transparency motion accessibility")
    public static let fileSearchScope = SettingsItem(id: "file-search-scope", page: "files", title: "文件搜索范围", keywords: "文件 Spotlight 索引 file search index scope")
    public static let fileSearchInline = SettingsItem(id: "file-search-inline", page: "launcher", title: "在主界面搜索文件", keywords: "主搜索 启动器 直接 搜索 文件 launcher inline file search")
    public static let menuBar = SettingsItem(id: "menu-bar", page: "menu-bar", title: "菜单栏项目", keywords: "显示 隐藏 状态 图标 menu bar status item")
    public static let scriptFolders = SettingsItem(id: "script-folders", page: "script-commands", title: "脚本搜索范围", keywords: "script folder shell python node 脚本 文件夹")
    public static let scriptCommands = SettingsItem(id: "script-commands", page: "script-commands", title: "脚本命令", keywords: "script commands alias hotkey 脚本 别名 热键")
    public static let systemShortcuts = SettingsItem(id: "system-shortcuts", page: "shortcuts", title: "Apple 快捷指令", keywords: "别名 热键 apple shortcuts alias hotkey")
    public static let accessibilityPermission = SettingsItem(id: "permission-accessibility", page: "permissions", title: "辅助功能权限", keywords: "权限 授权 粘贴 窗口 菜单 accessibility permission")
    public static let inputMonitoringPermission = SettingsItem(id: "permission-input-monitoring", page: "permissions", title: "输入监控", keywords: "权限 授权 键盘 Hyperkey input monitoring permission")
    public static let contactsPermission = SettingsItem(id: "permission-contacts", page: "permissions", title: "联系人权限", keywords: "授权 通讯录 contacts permission")
    public static let cameraPermission = SettingsItem(id: "camera-permission", page: "permissions", title: "相机权限", keywords: "camera 摄像头 预览")
    public static let automationPermission = SettingsItem(id: "permission-automation", page: "permissions", title: "自动化权限", keywords: "授权 Finder 快捷指令 automation permission")
    public static let pasteboardPermission = SettingsItem(id: "permission-pasteboard", page: "permissions", title: "剪贴板访问", keywords: "权限 授权 读取 clipboard pasteboard permission")
    public static let fileSearchPermissions = SettingsItem(id: "permission-file-search", page: "permissions", title: "文件搜索授权", keywords: "权限 文件夹 下载 重新授权 search folders permission")
    public static let folderPermissions = SettingsItem(id: "permission-folders", page: "permissions", title: "文件与文件夹权限", keywords: "授权 搜索范围 截图 files folders permission")
    public static let calendarAccess = SettingsItem(id: "calendar-access", page: "permissions", title: "日历权限", keywords: "日程 权限 calendar events permission")
    public static let calendarDisplay = SettingsItem(id: "calendar-display", page: "calendar", title: "日程显示与默认应用", keywords: "日历 主搜索 默认应用 浏览器 calendar event google meet")
    public static let calendarMeetings = SettingsItem(id: "calendar-meetings", page: "calendar", title: "自动加入会议与相机预览", keywords: "会议 视频 相机 auto join meeting camera")
    public static let calendarMenuBar = SettingsItem(id: "calendar-menu-bar", page: "calendar", title: "日历菜单栏摘要", keywords: "下一个 日程 日期 calendar agenda menu bar")
    public static let calendarSelection = SettingsItem(id: "calendar-selection", page: "calendar-enabled", title: "已启用的日历", keywords: "日历 筛选 账户 calendar account filter")
    public static let clipboardCapture = SettingsItem(id: "capture", page: "clipboard", title: "记录剪贴板历史", keywords: "文字 图片 文件 保留 采集 置顶 OCR capture clipboard history")
    public static let clipboardReplay = SettingsItem(id: "clipboard-replay", page: "clipboard", title: "剪贴板历史命令",
                                                         keywords: "回车 动作 纯文本 粘贴 复制 置顶 排序 预览 链接 图标 clipboard paste replay preview")
    public static let clipboardRetention = SettingsItem(id: "clipboard-retention", page: "clipboard", title: "剪贴板保留历史记录", keywords: "保留时间 clipboard retention")
    public static let clipboardRecognition = SettingsItem(id: "clipboard-recognition", page: "clipboard", title: "剪贴板文字识别", keywords: "图片 快速 准确 clipboard OCR recognition")
    public static let clipboardExclusions = SettingsItem(id: "clipboard-exclusions", page: "clipboard", title: "不记录这些应用", keywords: "剪贴板 排除 应用 clipboard disabled applications")
    public static let snippetSearchCommand = SettingsItem(id: "snippet-search-command", page: "snippets-search-command",
                                                          title: "搜索文字片段的主要操作", keywords: "search snippets primary action paste copy 片段 粘贴 复制")
    public static let snippetExpansion = SettingsItem(id: "snippet-expansion", page: "snippets", title: "文字片段与缩写", keywords: "snippets expansion 片段 缩写 展开")
    public static let quicklink = SettingsItem(id: "quicklink", page: "links", title: "快捷链接", keywords: "网址 参数 别名 热键 标签 置顶 隐藏 导入 导出 url quicklink")
    public static let windowActivation = SettingsItem(id: "advanced-window-activation", page: "advanced", title: "窗口激活行为", keywords: "空间 窗口 window activation behavior spaces")
    public static let faviconProvider = SettingsItem(id: "advanced-favicon", page: "advanced", title: "网站图标提供方", keywords: "网页 图标 favicon provider")
    public static let exportPassphrase = SettingsItem(id: "advanced-export-passphrase", page: "advanced", title: "导出口令", keywords: "加密 备份 export passphrase encryption")
    public static let scheduledExport = SettingsItem(id: "advanced-scheduled-export", page: "advanced", title: "定时导出", keywords: "自动备份 scheduled export backup")
    public static let exportPreferences = SettingsItem(id: "advanced-preferences-export", page: "advanced", title: "导出设置", keywords: "备份 偏好 JSON export preferences settings")
    public static let exportLocalRecords = SettingsItem(id: "advanced-local-export", page: "advanced", title: "导出本地资料", keywords: "备份 JSON export local records")
    public static let systemProxy = SettingsItem(id: "advanced-system-proxy", page: "advanced", title: "使用系统代理设置", keywords: "网络 连接 system proxy settings")
    public static let additionalCertificateAuthority = SettingsItem(id: "advanced-certificate-authority", page: "advanced", title: "额外的证书颁发机构", keywords: "信任 连接 CA certificate authority crt cer pem")
    public static let dataDirectory = SettingsItem(id: "directory", page: "advanced", title: "资料目录", keywords: "数据 sqlite directory storage")
    public static let privacy = SettingsItem(id: "privacy", page: "advanced", title: "隐私与遥测", keywords: "privacy telemetry")
    public static let version = SettingsItem(id: "version", page: "about", title: "关于 Keylane", keywords: "版本 许可 about version license")
    public static let softwareUpdates = SettingsItem(id: "software-updates", page: "about", title: "软件更新", keywords: "检查更新 自动更新 测试版 Alpha Beta GitHub update")
    public static let developmentStatus = SettingsItem(id: "status", page: "about", title: "开发状态", keywords: "功能 限制 roadmap status")

    public static let all: [SettingsItem] = [
        appearance,
        windowMode,
        windowPosition,
        launcherReturnDelay,
        rootSearchSensitivity,
        launcherSearchHistory,
        rootFileContentSearch,
        rootContactsSearch,
        launcherFallbackCommands,
        keyboard,
        keyboardEscapeBehavior,
        keyboardCloseWindow,
        keyboardInputSource,
        keyboardNavigation,
        keyboardPageNavigation,
        keyboardHyperKey,
        hotkeys,
        login,
        glass,
        applicationScopes,
        applicationAutoQuit,
        fileSearchScope,
        fileSearchInline,
        screenshotColumns,
        screenshotScopes,
        screenshotText,
        applicationFavorites,
        menuBar,
        systemShortcuts,
        scriptFolders,
        scriptCommands,
        accessibilityPermission,
        inputMonitoringPermission,
        calendarAccess,
        contactsPermission,
        cameraPermission,
        automationPermission,
        folderPermissions,
        pasteboardPermission,
        fileSearchPermissions,
        calendarDisplay,
        calendarMeetings,
        calendarMenuBar,
        calendarSelection,
        clipboardCapture,
        clipboardRetention,
        clipboardReplay,
        clipboardRecognition,
        clipboardExclusions,
        quicklink,
        snippetExpansion,
        snippetSearchCommand,
        windowActivation,
        faviconProvider,
        exportPassphrase,
        scheduledExport,
        exportPreferences,
        exportLocalRecords,
        systemProxy,
        additionalCertificateAuthority,
        dataDirectory,
        privacy,
        version,
        softwareUpdates,
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
