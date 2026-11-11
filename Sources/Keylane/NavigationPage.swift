import SwiftUI
import ApplicationServices
import KeylaneCore

final class NavigationController: ObservableObject {
    @Published private(set) var results: [NavigationItem] = []
    @Published private(set) var targetName: String?
    @Published private(set) var status: Status = .loading
    @Published private(set) var incomplete = false
    @Published private(set) var performing = false
    @Published var selection = 0
    private var items: [NavigationItem] = []
    private var scanRequest: NavigationScanRequest?

    enum Status { case loading, permission, noApplication, ready }

    var query = "" { didSet { if oldValue != query { filter() } } }
    var selected: NavigationItem? { results.indices.contains(selection) ? results[selection] : nil }

    func load(_ mode: NavigationMode, target: NSRunningApplication?) {
        scanRequest?.cancel()
        scanRequest = nil
        items = []
        results = []
        selection = 0
        incomplete = false
        targetName = mode == .menus ? target?.localizedName : nil
        guard AXIsProcessTrusted() else { status = .permission; return }
        if mode == .menus && (target == nil || target?.isTerminated == true) {
            status = .noApplication
            return
        }
        status = .loading
        scanRequest = SystemNavigation.shared.scan(mode, target: target) { [weak self] scan in
            guard let self else { return }
            self.scanRequest = nil
            self.items = scan.items
            self.incomplete = scan.incomplete
            self.filter()
            self.status = .ready
        }
    }

    func stop() {
        scanRequest?.cancel()
        scanRequest = nil
        items = []
        if !results.isEmpty { results = [] }
    }

    func move(_ delta: Int) {
        selection = NavigationBounds.move(selection, by: delta, count: results.count)
    }

    func perform(_ item: NavigationItem, mode: NavigationMode, completion: @escaping (String?) -> Void) {
        guard !performing else { return }
        performing = true
        SystemNavigation.shared.perform(item, mode: mode) { [weak self] message in
            self?.performing = false
            completion(message)
        }
    }

    private func filter() {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty {
            results = items
        } else {
            results = items.compactMap { item -> (NavigationItem, Int)? in
                let title = SearchRanker.score(item.title, query: needle)
                let path = SearchRanker.score(item.detail, query: needle).map { $0 - 250 }
                let combined = SearchRanker.score(item.detail + " " + item.title, query: needle).map { $0 - 300 }
                let shortcut = item.keys.joined() == needle ? 1100 : nil
                guard let score = [title, path, combined, shortcut].compactMap({ $0 }).max() else { return nil }
                return (item, score)
            }.sorted { $0.1 > $1.1 }.map(\.0)
        }
        selection = 0
    }
}

struct NavigationPage: View {
    @ObservedObject var controller: NavigationController
    let mode: NavigationMode
    let requestAccess: () -> Void
    let reload: () -> Void
    let activate: (NavigationItem) -> Void

    var body: some View {
        SelectableResultList(selection: controller.selected?.id, query: controller.query,
                             firstResult: controller.results.first?.id) {
            if controller.results.isEmpty {
                emptyState.padding(.top, 65).frame(maxWidth: .infinity)
            } else {
                Text(controller.targetName ?? NavigationText.label("最近使用的窗口", "Recent Windows"))
                    .font(VisualStyle.sectionText).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .accessibilityAddTraits(.isHeader)
                if controller.incomplete {
                    Text(NavigationText.label("部分结果暂不可用，可通过操作菜单刷新。", "Some results are unavailable. Refresh from Actions."))
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 8)
                }
                ForEach(Array(controller.results.enumerated()), id: \.element.id) { index, item in
                    Button {
                        controller.selection = index
                        activate(item)
                    } label: {
                        row(item, selected: controller.selection == index)
                    }
                    .buttonStyle(.plain)
                    .disabled(controller.performing)
                    .id(item.id)
                }
            }
        }
    }

    private func row(_ item: NavigationItem, selected: Bool) -> some View {
        ResultListRow(selected: selected) {
            if mode == .windows, let icon = item.application.icon {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: mode == .windows ? "macwindow" : "list.bullet.indent")
                    .foregroundStyle(.secondary)
            }
        } content: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(VisualStyle.rowText).lineLimit(1).truncationMode(.middle)
                    if !item.detail.isEmpty {
                        Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 4)
                if item.minimized {
                    Text(NavigationText.label("已最小化", "Minimized")).foregroundStyle(.secondary)
                } else if !item.enabled {
                    Text(NavigationText.label("不可用", "Unavailable")).foregroundStyle(.secondary)
                }
                if !item.keys.isEmpty { Keycaps(keys: item.keys) }
            }.font(.system(size: 11))
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch controller.status {
        case .loading:
            ProgressView(NavigationText.label("正在读取…", "Loading…"))
        case .permission:
            ContentUnavailableView {
                Label(NavigationText.label("需要辅助功能权限", "Accessibility Access Required"), systemImage: "accessibility")
            } description: {
                Text(NavigationText.label("允许 Keylane 读取和操作其他应用的窗口与菜单。", "Allow Keylane to read and control other apps’ windows and menus."))
            } actions: {
                Button(NavigationText.label("打开系统授权", "Request Access"), action: requestAccess)
                Button(NavigationText.label("重新检查", "Check Again"), action: reload)
            }
        case .noApplication:
            ContentUnavailableView(NavigationText.label("找不到之前的应用", "Previous App Unavailable"),
                                   systemImage: mode.symbol,
                                   description: Text(NavigationText.label("请从要搜索菜单的应用中重新唤起 Keylane。", "Reopen Keylane from the app whose menu you want to search.")))
        case .ready:
            let title = controller.incomplete
                ? NavigationText.label("部分结果暂不可用", "Some Results Unavailable")
                : NavigationText.label("没有匹配结果", "No Matching Results")
            ContentUnavailableView(title, systemImage: mode.symbol)
        }
    }
}
