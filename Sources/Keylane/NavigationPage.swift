import SwiftUI

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
                    ResultListButton(id: item.id, disabled: controller.performing, action: {
                        if controller.select(item) { activate(item) }
                    }) {
                        row(item, selected: controller.selection == index)
                    }
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
            Text(NavigationText.label("正在读取…", "Loading…")).foregroundStyle(.secondary)
        case .permission:
            ContentUnavailableView {
                Label(NavigationText.label("需要辅助功能权限", "Accessibility Access Required"), systemImage: "accessibility")
            } description: {
                Text(NavigationText.label("允许 Keylane 读取和操作其他应用的窗口与菜单。", "Allow Keylane to read and control other apps’ windows and menus."))
            } actions: {
                Button(NavigationText.label("窗口与菜单设置…", "Window & Menu Settings…"), action: requestAccess)
                Button(NavigationText.label("重新检查", "Check Again"), action: reload)
            }.buttonStyle(ContentActionButtonStyle())
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
