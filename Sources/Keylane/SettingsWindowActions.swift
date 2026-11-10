import SwiftUI

/// Hosted in a native trailing titlebar accessory, independent of toolbar item priorities.
struct SettingsWindowActions: View {
    @ObservedObject var model: Model
    @State private var showingInfo = false
    var body: some View {
        HStack(spacing: 10) {
            Button { showingInfo.toggle() } label: { Image(systemName: "info.circle").font(.system(size: 16)).frame(width: 18, height: 20) }
                .buttonStyle(.glass).buttonBorderShape(.circle).help("页面说明")
                .popover(isPresented: $showingInfo) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Keylane 设置").font(.headline)
                        if model.settingsPage == "applications" {
                            Text(model.scanStatus)
                            Text("关闭模块会停用应用搜索和应用快捷键，已保存的配置保留。自动退出和卸载命令尚未实现。")
                        } else { Text("在侧栏选择模块，或搜索设置项后跳转。") }
                    }.foregroundStyle(.primary).padding(20).frame(width: 280)
                }
            if model.settingsPage == "files" {
                Toggle("启用文件搜索", isOn: Binding(get: { model.fileSearch.options.enabled }, set: { model.fileSearch.options.enabled = $0 })).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            if model.settingsPage == "applications" {
                Toggle("启用应用程序", isOn: $model.applicationsEnabled).toggleStyle(.switch).labelsHidden().controlSize(.small).help("启用应用搜索和应用快捷键")
            }
        }.padding(.trailing, 12).frame(width: 106, height: 44, alignment: .trailing).preferredColorScheme(model.colorScheme)
    }
}
