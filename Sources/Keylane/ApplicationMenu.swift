import AppKit

/// Cocoa text editing shortcuts use the responder chain, including IME field editors.
func installApplicationMenu(settingsTarget: AnyObject, settingsAction: Selector) {
    let main = NSMenu()
    let app = NSMenu(title: "Keylane")
    let root = NSMenuItem(); root.submenu = app; main.addItem(root)
    let launcher = app.addItem(withTitle: "显示启动器", action: Selector(("revealLauncher")), keyEquivalent: ""); launcher.target = settingsTarget
    let settings = app.addItem(withTitle: "设置…", action: settingsAction, keyEquivalent: ","); settings.target = settingsTarget
    app.addItem(.separator())
    app.addItem(withTitle: "隐藏 Keylane", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    app.addItem(withTitle: "退出 Keylane", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let edit = NSMenu(title: "编辑")
    let editRoot = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); editRoot.submenu = edit; main.addItem(editRoot)
    edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]
    edit.addItem(.separator())
    edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let windows = NSMenu(title: "窗口")
    let windowRoot = NSMenuItem(title: "窗口", action: nil, keyEquivalent: ""); windowRoot.submenu = windows; main.addItem(windowRoot)
    windows.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    NSApp.mainMenu = main; NSApp.windowsMenu = windows
}
