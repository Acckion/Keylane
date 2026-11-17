import AppKit
import Combine
import KeylaneCore

struct WindowCommand: Identifiable {
    enum Action {
        case place(WindowPlacement)
        case half(WindowEdge)
        case almostMaximize
        case adjustSize(Int)
        case edge(WindowEdge)
        case display(Int)
        case minimize, minimizeDisplay, fullscreen
        case coordinate(resizing: Bool)
        case grid
        case switchSpace(Int), moveToSpace(Int)
        case createCommand, createLayout, saveLayout, importLayouts
    }

    let id: String
    let chinese: String
    let english: String
    let symbol: String
    let action: Action

    var title: String { NavigationText.label(chinese, english) }

    init(_ id: String, _ chinese: String, _ english: String, _ symbol: String, _ action: Action) {
        self.id = "window-" + id
        self.chinese = chinese
        self.english = english
        self.symbol = symbol
        self.action = action
    }

    var isSpaceSwitch: Bool {
        if case .switchSpace = action { return true }
        return false
    }

    var hasOptions: Bool {
        switch action {
        case .almostMaximize, .adjustSize, .edge, .display, .switchSpace: true
        default: false
        }
    }

    var region: CGRect? {
        switch action {
        case .half(let edge): Self.half(edge).fixedRegion
        case .place(let placement): placement.fixedRegion
        default: nil
        }
    }

    var fixedGeometry: WindowGeometry? { region.map(WindowGeometry.init(region:)) }

    static func half(_ edge: WindowEdge) -> WindowPlacement {
        switch edge {
        case .left: .left
        case .right: .right
        case .top: .top
        case .bottom: .bottom
        }
    }

    static let all: [Self] = {
        let halfCommands: [Self] = [
            .init("left-half", "左半屏", "Left Half", "rectangle.lefthalf.filled", .half(.left)),
            .init("right-half", "右半屏", "Right Half", "rectangle.righthalf.filled", .half(.right)),
            .init("top-half", "上半屏", "Top Half", "rectangle.tophalf.filled", .half(.top)),
            .init("bottom-half", "下半屏", "Bottom Half", "rectangle.bottomhalf.filled", .half(.bottom))
        ]
        let operations: [Self] = [
            .init("almost-maximize", "接近最大化", "Almost Maximize", "arrow.up.left.and.arrow.down.right", .almostMaximize),
            .init("maximize", "最大化窗口", "Maximize Window", "arrow.up.left.and.arrow.down.right", .place(.maximize)),
            .init("maximize-width", "最大化窗口宽度", "Maximize Width", "arrow.left.and.right", .place(.maximizeWidth)),
            .init("maximize-height", "最大化窗口高度", "Maximize Height", "arrow.up.and.down", .place(.maximizeHeight)),
            .init("center", "居中窗口", "Center Window", "rectangle.center.inset.filled", .place(.center)),
            .init("reasonable-size", "适中窗口大小", "Reasonable Size", "rectangle.center.inset.filled", .place(.proportional(0.6, maximum: CGSize(width: 1025, height: 900)))),
            .init("restore", "恢复窗口位置和大小", "Restore Window Position and Size", "arrow.uturn.backward", .place(.restore)),
            .init("next-display", "移到下一台显示器", "Move Window to Next Display", "display.2", .display(1)),
            .init("previous-display", "移到上一台显示器", "Move Window to Previous Display", "display.2", .display(-1)),
            .init("move-left", "窗口靠左", "Move Left", "arrow.left", .edge(.left)),
            .init("move-right", "窗口靠右", "Move Right", "arrow.right", .edge(.right)),
            .init("move-top", "窗口靠上", "Move Top", "arrow.up", .edge(.top)),
            .init("move-bottom", "窗口靠下", "Move Bottom", "arrow.down", .edge(.bottom)),
            .init("larger", "放大窗口", "Make Larger", "plus", .adjustSize(1)),
            .init("smaller", "缩小窗口", "Make Smaller", "minus", .adjustSize(-1)),
            .init("move", "移动窗口", "Move Window", "arrow.up.and.down.and.arrow.left.and.right", .coordinate(resizing: false)),
            .init("resize", "调整窗口大小", "Resize Window", "arrow.up.left.and.arrow.down.right", .coordinate(resizing: true)),
            .init("minimize", "最小化窗口", "Minimize", "minus.rectangle", .minimize),
            .init("minimize-display", "最小化本显示器窗口", "Minimize on This Display", "minus.rectangle.on.rectangle", .minimizeDisplay),
            .init("fullscreen", "切换全屏", "Toggle Fullscreen", "arrow.up.left.and.arrow.down.right", .fullscreen),
            .init("grid", "切换窗口网格", "Toggle Grid Overlay", "grid", .grid),
            .init("move-next-space", "将窗口移到下一个空间", "Move to Next Space", "arrow.right.square", .moveToSpace(1)),
            .init("move-previous-space", "将窗口移到上一个空间", "Move to Previous Space", "arrow.left.square", .moveToSpace(-1)),
            .init("create-command", "创建窗口命令", "Create Window Command", "rectangle.badge.plus", .createCommand),
            .init("create-layout", "创建窗口布局", "Create Window Layout", "rectangle.split.2x1", .createLayout),
            .init("save-layout", "保存当前窗口布局", "Save Current Layout", "rectangle.stack.badge.plus", .saveLayout),
            .init("import-layouts", "导入窗口命令和布局", "Import Commands & Layouts", "square.and.arrow.down", .importLayouts),
            .init("switch-next-space", "切换到下一个空间", "Switch to Next Space", "arrow.right.square", .switchSpace(1)),
            .init("switch-previous-space", "切换到上一个空间", "Switch to Previous Space", "arrow.left.square", .switchSpace(-1))
        ]
        var tiles: [Self] = []
        func tile(_ id: String, _ cn: String, _ en: String, _ region: CGRect, _ symbol: String = "rectangle.inset.filled") {
            tiles.append(.init(id, cn, en, symbol, .place(.region(region))))
        }
        let horizontal: [(String, String, String, CGFloat, CGFloat)] = [
            ("first-fourth", "最左四分之一", "First Fourth", 0, 1/4),
            ("second-fourth", "从左第二个四分之一", "Second Fourth", 1/4, 1/4),
            ("third-fourth", "从左第三个四分之一", "Third Fourth", 1/2, 1/4),
            ("last-fourth", "最右四分之一", "Last Fourth", 3/4, 1/4),
            ("first-third", "左侧三分之一", "First Third", 0, 1/3),
            ("center-third", "中央三分之一", "Center Third", 1/3, 1/3),
            ("last-third", "右侧三分之一", "Last Third", 2/3, 1/3),
            ("first-two-thirds", "左侧三分之二", "First Two Thirds", 0, 2/3),
            ("center-two-thirds", "中央三分之二", "Center Two Thirds", 1/6, 2/3),
            ("last-two-thirds", "右侧三分之二", "Last Two Thirds", 1/3, 2/3),
            ("first-three-fourths", "左侧四分之三", "First Three Fourths", 0, 3/4),
            ("center-three-fourths", "中央四分之三", "Center Three Fourths", 1/8, 3/4),
            ("last-three-fourths", "右侧四分之三", "Last Three Fourths", 1/4, 3/4),
            ("center-half", "中央半屏", "Center Half", 1/4, 1/2)
        ]
        for (id, cn, en, x, width) in horizontal {
            tile(id, cn, en, CGRect(x: x, y: 0, width: width, height: 1), "rectangle.split.3x1")
        }
        let vertical: [(String, String, String, CGFloat, CGFloat)] = [
            ("top-first-fourth", "最上四分之一", "Top First Fourth", 0, 1/4),
            ("top-second-fourth", "从上第二个四分之一", "Top Second Fourth", 1/4, 1/4),
            ("top-third-fourth", "从上第三个四分之一", "Top Third Fourth", 1/2, 1/4),
            ("top-last-fourth", "最下四分之一", "Top Last Fourth", 3/4, 1/4),
            ("top-third", "上侧三分之一", "Top Third", 0, 1/3),
            ("middle-third", "中间三分之一", "Middle Third", 1/3, 1/3),
            ("bottom-third", "下侧三分之一", "Bottom Third", 2/3, 1/3),
            ("top-two-thirds", "上侧三分之二", "Top Two Thirds", 0, 2/3),
            ("bottom-two-thirds", "下侧三分之二", "Bottom Two Thirds", 1/3, 2/3),
            ("top-three-fourths", "上侧四分之三", "Top Three Fourths", 0, 3/4),
            ("bottom-three-fourths", "下侧四分之三", "Bottom Three Fourths", 1/4, 3/4)
        ]
        for (id, cn, en, y, height) in vertical {
            tile(id, cn, en, CGRect(x: 0, y: y, width: 1, height: height), "rectangle.split.1x2")
        }
        for (rowID, rowCN, row, y) in [("top", "上", "Top", 0.0), ("bottom", "下", "Bottom", 0.5)] {
            for (columnID, columnCN, column, x) in [("left", "左", "Left", 0.0), ("right", "右", "Right", 0.5)] {
                tile("\(rowID)-\(columnID)-quarter", "\(columnCN)\(rowCN)四分之一", "\(row) \(column) Quarter",
                     CGRect(x: x, y: y, width: 0.5, height: 0.5), "rectangle.split.2x2")
            }
            for (index, column) in ["Left", "Center", "Right"].enumerated() {
                let columnCN = ["左", "中", "右"][index]
                tile("\(rowID)-\(column.lowercased())-sixth", "\(rowCN)\(columnCN)六分之一", "\(row) \(column) Sixth",
                     CGRect(x: CGFloat(index) / 3, y: y, width: 1/3, height: 0.5), "grid")
            }
            tile("\(rowID)-center-two-thirds", "\(rowCN)侧居中三分之二", "\(row) Center Two Thirds",
                 CGRect(x: 1/6, y: y, width: 2/3, height: 0.5), "rectangle.center.inset.filled")
        }
        return (halfCommands + operations + tiles).sorted { $0.english < $1.english }
    }()
}

final class WindowManagementPreferences: ObservableObject {
    enum Cycling: String, CaseIterable {
        case off, halves, thirds, displays

        var label: String {
            switch self {
            case .off: "不循环"
            case .halves: "循环 ½ 和 ⅔"
            case .thirds: "循环 ½、⅔ 和 ⅓"
            case .displays: "在显示器之间循环"
            }
        }

        var fractions: [CGFloat] {
            switch self {
            case .off, .displays: [0.5]
            case .halves: [0.5, 2/3]
            case .thirds: [0.5, 2/3, 1/3]
            }
        }
    }

    struct Options: Codable {
        var percentage = 60
        var step = 32
        var center = true
        var wrap = true
        var aspect = true
        var animateSpace = false
    }

    @Published var windowGap: Int { didSet { defaults.set(windowGap, forKey: "windowManagement.windowGap") } }
    @Published var screenGap: Int { didSet { defaults.set(screenGap, forKey: "windowManagement.screenGap") } }
    @Published var cycling: Cycling { didSet { defaults.set(cycling.rawValue, forKey: "windowManagement.cycling") } }
    @Published var respectStageManager: Bool { didSet { defaults.set(respectStageManager, forKey: "windowManagement.stageManager") } }
    @Published private(set) var options: [String: Options] {
        didSet { defaults.set(try? JSONEncoder().encode(options), forKey: "windowManagement.commandOptions") }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        windowGap = max(0, defaults.integer(forKey: "windowManagement.windowGap"))
        screenGap = max(0, defaults.integer(forKey: "windowManagement.screenGap"))
        cycling = defaults.string(forKey: "windowManagement.cycling").flatMap(Cycling.init(rawValue:)) ?? .off
        respectStageManager = defaults.bool(forKey: "windowManagement.stageManager")
        options = defaults.data(forKey: "windowManagement.commandOptions")
            .flatMap { try? JSONDecoder().decode([String: Options].self, from: $0) } ?? [:]
    }

    func options(for command: WindowCommand) -> Options { options[command.id] ?? Options() }

    func set<Value>(_ field: WritableKeyPath<Options, Value>, for command: WindowCommand, to value: Value) {
        var next = options(for: command)
        next[keyPath: field] = value
        options[command.id] = next
    }

    var placementOptions: WindowPlacementOptions {
        .init(windowGap: CGFloat(windowGap), screenGap: CGFloat(screenGap), respectStageManager: respectStageManager,
              halfFractions: cycling.fractions, cycleDisplays: cycling == .displays)
    }
}
