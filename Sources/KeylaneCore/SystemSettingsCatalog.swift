import Foundation

public struct SystemSettingsPage: Identifiable {
    public let id: String
    public let chinese: String
    public let english: String
    public let symbol: String
    public let aliases: [String]
    public let url: URL

    fileprivate init(_ key: String, _ chinese: String, _ english: String,
                     _ symbol: String, _ destination: String, _ aliases: [String] = []) {
        self.id = "system-setting:" + key
        self.chinese = chinese
        self.english = english
        self.symbol = symbol
        self.aliases = aliases
        // These routes are fixed catalog data. Search input never forms part of a URL.
        self.url = URL(string: "x-apple.systempreferences:" + destination)!
    }

    public func title(languages: [String] = Locale.preferredLanguages) -> String {
        SystemSettingsCatalog.prefersChinese(languages) ? chinese : english
    }

    public var searchNames: [String] { [chinese, english] + aliases }
}

public enum SystemSettingsCatalog {
    public static let resultKind = "System Setting"

    public static func prefersChinese(_ languages: [String] = Locale.preferredLanguages) -> Bool {
        languages.first?.lowercased().hasPrefix("zh") == true
    }

    /// Recognize natural queries such as “蓝牙设置” and “system settings bluetooth”.
    /// The general System Settings application remains searchable by its own name.
    public static func pageQuery(_ query: String) -> String {
        var words = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if ["system settings", "system preferences", "settings", "preferences", "系统设置", "系統設定", "设置", "設定"].contains(words.lowercased()) {
            return ""
        }
        for prefix in ["system settings ", "system preferences ", "settings ", "系统设置", "系統設定"] {
            if words.lowercased().hasPrefix(prefix) {
                words = String(words.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        for suffix in [" settings", " preferences", "设置", "設定"] {
            if words.count > suffix.count && words.lowercased().hasSuffix(suffix) {
                words = String(words.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return words
    }

    private static func privacy(_ key: String, _ chinese: String, _ english: String, _ symbol: String,
                                _ anchor: String, _ aliases: [String] = []) -> SystemSettingsPage {
        .init(key, chinese, english, symbol, "com.apple.preference.security?Privacy_" + anchor, aliases)
    }

    public static let pages: [SystemSettingsPage] = [
        .init("wifi", "Wi-Fi", "Wi-Fi", "wifi", "com.apple.wifi-settings-extension",
              ["Wi‑Fi", "WiFi", "WLAN", "无线局域网", "无线网络", "无线网"]),
        .init("bluetooth", "蓝牙", "Bluetooth", "wave.3.right", "com.apple.BluetoothSettings"),
        .init("network", "网络", "Network", "network", "com.apple.Network-Settings.extension",
              ["Ethernet", "以太网"]),
        .init("vpn", "VPN", "VPN", "network.badge.shield.half.filled", "com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension",
              ["虚拟专用网络"]),
        .init("battery", "电池", "Battery", "battery.100percent", "com.apple.Battery-Settings.extension",
              ["Battery Health", "电池健康", "低电量模式", "Low Power Mode"]),
        .init("general", "通用", "General", "gearshape", "com.apple.systempreferences.GeneralSettings"),
        .init("about", "关于本机", "About This Mac", "info.circle", "com.apple.SystemProfiler.AboutExtension",
              ["About", "本机信息"]),
        .init("software-update", "软件更新", "Software Update", "arrow.trianglehead.clockwise.rotate.90", "com.apple.Software-Update-Settings.extension",
              ["系统更新", "macOS Update"]),
        .init("storage", "储存空间", "Storage", "internaldrive", "com.apple.settings.Storage",
              ["存储空间", "磁盘空间", "Disk Space"]),
        .init("airdrop-handoff", "隔空投送与接力", "AirDrop & Handoff", "airdrop", "com.apple.AirDrop-Handoff-Settings.extension",
              ["隔空投送与连续互通", "隔空投送", "接力", "AirDrop", "Handoff", "Continuity"]),
        .init("login-items", "登录项与扩展", "Login Items & Extensions", "rectangle.and.text.magnifyingglass", "com.apple.LoginItems-Settings.extension",
              ["登录项", "开机启动", "启动项", "Login Items", "Startup Apps", "Extensions"]),
        .init("language-region", "语言与地区", "Language & Region", "globe", "com.apple.Localization-Settings.extension",
              ["语言", "地区", "Language and Region"]),
        .init("date-time", "日期与时间", "Date & Time", "clock", "com.apple.Date-Time-Settings.extension",
              ["日期", "时间", "时区", "Date and Time", "Time Zone"]),
        .init("sharing", "共享", "Sharing", "square.and.arrow.up", "com.apple.Sharing-Settings.extension",
              ["文件共享", "屏幕共享", "远程登录", "File Sharing", "Screen Sharing", "Remote Login"]),
        .init("time-machine", "时间机器", "Time Machine", "clock.arrow.circlepath", "com.apple.Time-Machine-Settings.extension",
              ["备份", "Backup"]),
        .init("startup-disk", "启动磁盘", "Startup Disk", "internaldrive", "com.apple.Startup-Disk-Settings.extension",
              ["启动盘", "Boot Disk"]),
        .init("transfer-reset", "传输或还原", "Transfer or Reset", "arrow.left.arrow.right", "com.apple.Transfer-Reset-Settings.extension",
              ["迁移", "还原", "Migration", "Reset"]),
        .init("accessibility", "辅助功能", "Accessibility", "accessibility", "com.apple.Accessibility-Settings.extension",
              ["无障碍"]),
        .init("menu-bar", "菜单栏", "Menu Bar", "menubar.rectangle", "com.apple.ControlCenter-Settings.extension",
              ["控制中心", "Control Center"]),
        .init("spotlight", "聚焦", "Spotlight", "magnifyingglass", "com.apple.Spotlight-Settings.extension",
              ["聚焦搜索", "Spotlight Search"]),
        .init("wallpaper", "墙纸", "Wallpaper", "photo", "com.apple.Wallpaper-Settings.extension",
              ["壁纸", "桌面背景", "Desktop Background"]),
        .init("appearance", "外观", "Appearance", "circle.lefthalf.filled", "com.apple.Appearance-Settings.extension",
              ["主题", "深色模式", "浅色模式", "Dark Mode", "Light Mode", "Theme"]),
        .init("displays", "显示器", "Displays", "display", "com.apple.Displays-Settings.extension",
              ["显示", "分辨率", "亮度", "夜览", "Display", "Resolution", "Brightness", "Night Shift"]),
        .init("desktop-dock", "桌面与程序坞", "Desktop & Dock", "dock.rectangle", "com.apple.Desktop-Settings.extension",
              ["程序坞", "Dock", "桌面和程序坞", "调度中心", "Desktop and Dock", "Stage Manager"]),
        .init("siri", "Siri", "Siri", "waveform", "com.apple.Siri-Settings.extension",
              ["Apple Intelligence & Siri", "Apple Intelligence", "Apple 智能", "Apple 智慧"]),
        .init("notifications", "通知", "Notifications", "bell", "com.apple.Notifications-Settings.extension"),
        .init("sound", "声音", "Sound", "speaker.wave.2", "com.apple.Sound-Settings.extension",
              ["声效", "音量", "音频", "Volume", "Audio", "Sound Output", "Sound Input"]),
        .init("focus", "专注模式", "Focus", "moon", "com.apple.Focus-Settings.extension",
              ["勿扰模式", "Do Not Disturb"]),
        .init("screen-time", "屏幕使用时间", "Screen Time", "hourglass", "com.apple.Screen-Time-Settings.extension", ["屏幕时间"]),
        .init("lock-screen", "锁定屏幕", "Lock Screen", "lock", "com.apple.Lock-Screen-Settings.extension",
              ["锁屏"]),
        .init("privacy-security", "隐私与安全性", "Privacy & Security", "hand.raised", "com.apple.settings.PrivacySecurity.extension",
              ["隐私", "隐私与安全", "隐私和安全性", "Privacy and Security"]),
        privacy("privacy-accessibility", "辅助功能权限", "Accessibility Permissions", "accessibility",
                "Accessibility", ["辅助功能授权", "无障碍权限", "设备控制和数据访问", "Privacy Accessibility"]),
        privacy("privacy-screen-recording", "屏幕与系统音频录制", "Screen & System Audio Recording", "record.circle",
                "ScreenCapture", ["录屏与系统录音", "屏幕与系统录音", "屏幕录制权限", "录屏权限", "屏幕录制", "Screen Recording", "Screen Recording Permission"]),
        privacy("privacy-full-disk-access", "完全磁盘访问权限", "Full Disk Access", "internaldrive",
                "AllFiles", ["完全磁盘访问", "全磁盘访问"]),
        privacy("privacy-files", "文件与文件夹权限", "Files and Folders", "folder",
                "FilesAndFolders", ["文件与文件夹", "文件和文件夹", "文件访问权限", "Files & Folders"]),
        privacy("privacy-camera", "相机权限", "Camera Permissions", "camera",
                "Camera", ["相机", "摄像头", "摄像头权限", "Camera Privacy"]),
        privacy("privacy-microphone", "麦克风权限", "Microphone Permissions", "mic",
                "Microphone", ["麦克风", "话筒权限", "Microphone Privacy"]),
        privacy("privacy-location", "定位服务", "Location Services", "location",
                "LocationServices", ["定位权限", "Location Privacy"]),
        privacy("privacy-calendar", "日历权限", "Calendar Permissions", "calendar",
                "Calendars", ["日历授权", "Calendar Privacy"]),
        privacy("privacy-contacts", "联系人权限", "Contacts Permissions", "person.crop.circle",
                "Contacts", ["通讯录权限", "Contacts Privacy"]),
        privacy("privacy-automation", "自动化权限", "Automation Permissions", "bolt.horizontal.circle",
                "Automation", ["自动化", "Automation Privacy"]),
        .init("touch-id", "触控 ID 与密码", "Touch ID & Password", "touchid", "com.apple.Touch-ID-Settings.extension",
              ["触控ID与密码", "指纹", "Touch ID", "Touch ID and Password"]),
        .init("users-groups", "用户与群组", "Users & Groups", "person.2", "com.apple.Users-Groups-Settings.extension",
              ["用户账户", "用户和群组", "Users and Groups", "User Accounts"]),
        .init("internet-accounts", "互联网账户", "Internet Accounts", "at", "com.apple.Internet-Accounts-Settings.extension",
              ["互联网账号", "网络账户"]),
        .init("keyboard", "键盘", "Keyboard", "keyboard", "com.apple.Keyboard-Settings.extension",
              ["输入法", "键盘快捷键", "Input Sources", "Keyboard Shortcuts"]),
        .init("trackpad", "触控板", "Trackpad", "trackpad", "com.apple.Trackpad-Settings.extension",
              ["触摸板", "手势", "Gestures"]),
        .init("printers-scanners", "打印机与扫描仪", "Printers & Scanners", "printer", "com.apple.Print-Scan-Settings.extension",
              ["打印机", "扫描仪", "Printer", "Scanner", "Printers and Scanners"])
    ]
}
