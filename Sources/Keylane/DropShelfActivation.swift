import AppKit

enum ShelfShakeSensitivity: String, CaseIterable {
    case low, standard, high
    var title: String { switch self { case .low: "低灵敏度"; case .standard: "默认灵敏度"; case .high: "高灵敏度" } }
    var distance: CGFloat { switch self { case .low: 18; case .standard: 12; case .high: 8 } }
    var reversals: Int { self == .low ? 4 : 3 }
}

enum ShelfActivationKey: String, CaseIterable {
    case command, option, control, shift
    var title: String {
        switch self {
        case .command: "使用 ⌘ Command 键"
        case .option: "使用 ⌥ Option 键"
        case .control: "使用 ⌃ Control 键"
        case .shift: "使用 ⇧ Shift 键"
        }
    }
    var flag: NSEvent.ModifierFlags {
        switch self { case .command: .command; case .option: .option; case .control: .control; case .shift: .shift }
    }
}

enum ShelfDefaultPosition: String, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight, pointer
    var title: String {
        switch self { case .topLeft: "左上角"; case .topRight: "右上角"; case .bottomLeft: "左下角"; case .bottomRight: "右下角"; case .pointer: "指针附近" }
    }
    func origin(size: NSSize, in area: NSRect, mouse: NSPoint) -> NSPoint {
        let inset: CGFloat = 12
        let left = area.minX + inset, right = area.maxX - size.width - inset
        let bottom = area.minY + inset, top = area.maxY - size.height - inset
        switch self {
        case .topLeft: return NSPoint(x: left, y: top)
        case .topRight: return NSPoint(x: right, y: top)
        case .bottomLeft: return NSPoint(x: left, y: bottom)
        case .bottomRight: return NSPoint(x: right, y: bottom)
        case .pointer:
            return NSPoint(x: max(area.minX, min(mouse.x + 25, area.maxX - size.width)),
                           y: max(area.minY, min(mouse.y - size.height / 2, area.maxY - size.height)))
        }
    }
}

enum ShelfAddBehavior: String, CaseIterable {
    case newWindow, existingWindow
    var title: String { self == .newWindow ? "在新窗口中显示" : "加入当前打开的暂存架" }
}

enum ShelfNotchHighlight: String, CaseIterable {
    case hover, nearby
    var title: String { self == .hover ? "光标悬停在刘海时高亮" : "拖动到刘海附近时高亮" }
}

final class ShelfNotchTarget {
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let surface = DropShelfDropView(frame: .zero)
    private(set) var receiving = false
    private var alwaysHighlight = false

    init(receive: @escaping (NSPasteboard) -> Bool) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = surface
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 10
        // Keep an almost invisible fill so the panel remains a WindowServer drop target.
        surface.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.02).cgColor
        surface.receive = receive
        surface.dragActivity = { [weak self] active in
            self?.receiving = active
            self?.updateHighlight()
        }
    }

    static func region(on screen: NSScreen) -> NSRect? {
        region(frame: screen.frame, topInset: screen.safeAreaInsets.top,
               left: screen.auxiliaryTopLeftArea, right: screen.auxiliaryTopRightArea)
    }

    static func region(frame: NSRect, topInset: CGFloat, left: NSRect?, right: NSRect?) -> NSRect? {
        guard topInset > 0, let left, let right, !left.isEmpty, !right.isEmpty, left.maxX < right.minX else { return nil }
        // Extend just below the hardware notch, where the cursor can target it.
        let height = topInset + 12
        return NSRect(x: left.maxX, y: frame.maxY - height, width: right.minX - left.maxX, height: height)
    }

    func show(in region: NSRect, highlight: ShelfNotchHighlight) {
        alwaysHighlight = highlight == .nearby
        if panel.frame != region { panel.setFrame(region, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
        updateHighlight()
    }

    func hide() {
        receiving = false
        panel.orderOut(nil)
    }

    private func updateHighlight() {
        surface.layer?.borderWidth = receiving || alwaysHighlight ? 3 : 0
        surface.layer?.borderColor = NSColor.systemBlue.cgColor
    }
}
