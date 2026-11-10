import SwiftUI
import AppKit
import KeylaneCore

struct ClipboardHistoryView: View {
    @ObservedObject var controller: ClipboardController
    let query: String
    var body: some View {
        ResultDetailLayout {
            results
        } detail: {
            VStack(alignment: .leading, spacing: 10) {
                if let detail = controller.detail {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if detail.item.kind == .text { Text(detail.text).font(.system(size: 14)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            else if detail.item.kind == .image {
                                if let image = controller.thumbnail { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 220) }
                                else { Label("图片附件丢失或无法预览", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                                Button("识别图片文字", systemImage: "text.viewfinder") { controller.recognizeSelected() }.buttonStyle(.glass)
                                if !detail.ocrText.isEmpty { Divider(); Text(detail.ocrText).textSelection(.enabled) }
                            } else {
                                ForEach(detail.files, id: \.path) { file in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Label(URL(fileURLWithPath: file.path).lastPathComponent, systemImage: "doc")
                                        Text(file.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                        if !FileManager.default.fileExists(atPath: file.path) { Text("原文件已移走或删除").font(.caption).foregroundStyle(.orange) }
                                        else { HStack { Button("快速查看") { FilePreview.shared.show(URL(fileURLWithPath: file.path)) }; Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)]) } }.buttonStyle(.glass) }
                                    }.padding(.bottom, 8)
                                }
                            }
                            if detail.item.kind != .text, let text = detail.snapshot?.plainText, !text.isEmpty {
                                Divider(); Text("附加文字").font(VisualStyle.sectionText).foregroundStyle(.secondary); Text(text).textSelection(.enabled)
                            }
                            if let snapshot = detail.snapshot {
                                LabeledContent("项目",value:String(snapshot.items.count))
                                LabeledContent("包含格式",value:snapshot.formats.map(formatTitle).joined(separator:"、"))
                            }
                            Divider()
                            LabeledContent("来源", value: detail.item.source)
                            LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: Int64(detail.item.byteCount), countStyle: .file))
                            LabeledContent("复制次数", value: String(detail.item.copyCount))
                            HStack { Text("最近复制"); Spacer(); Text(detail.item.copiedAt, format: .dateTime) }
                        }.font(.system(size: 12)).padding(16)
                    }
                    HStack {
                        Button("复制",systemImage:"doc.on.doc") { controller.copySelected() }.disabled(controller.searching || controller.loadingDetail)
                        Button("粘贴",systemImage:"doc.on.clipboard") { (NSApp.delegate as? Delegate)?.pasteClipboard() }.disabled(controller.searching || controller.loadingDetail)
                        Button { controller.pinSelected() } label: { Label(detail.item.pinned ? "取消置顶" : "置顶", systemImage: detail.item.pinned ? "pin.slash" : "pin") }
                        Spacer()
                        Button("删除记录", systemImage: "trash", role: .destructive) { controller.removeSelected() }
                    }.buttonStyle(.glass).padding(.horizontal, 16)
                } else {
                    Spacer()
                    ContentUnavailableView(controller.items.isEmpty ? "暂无匹配记录" : "正在加载", systemImage: "clipboard", description: Text(controller.captureEnabled ? "复制文字、图片或文件后，会自动保存到这台 Mac。" : "采集已关闭。可在剪贴板设置中开启本地历史。"))
                    Button("剪贴板设置…") { (NSApp.delegate as? Delegate)?.model.openSettings(page: "clipboard") }.buttonStyle(.glass).frame(maxWidth: .infinity)
                    Spacer()
                }
                if !controller.accessMessage.isEmpty { Text(controller.accessMessage).font(.caption).foregroundStyle(.orange).padding(.horizontal,16) }
                if !controller.status.isEmpty { Text(controller.status).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.top,61).padding(.bottom,52)
        }.onAppear { controller.reload() }
    }
    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment:.leading,spacing:0) {
                    HStack {
                        Image(systemName:controller.captureEnabled ? "circle.fill" : "pause.circle")
                            .font(.system(size:9)).foregroundStyle(controller.captureEnabled ? Color.green : Color.secondary)
                            .help(controller.captureEnabled ? "正在记录" : "采集已暂停")
                        Picker("类型",selection:$controller.kind) { Text("全部类型").tag("all"); Text("文字").tag("text"); Text("图片").tag("image"); Text("文件").tag("files") }.labelsHidden().pickerStyle(.menu).buttonStyle(.borderless)
                        Spacer()
                        Toggle(isOn:$controller.pinnedOnly) { Image(systemName:"pin") }.toggleStyle(.button).buttonStyle(.glass).help("仅置顶")
                    }.padding(.horizontal,10).padding(.vertical,6)
                    Text("\(controller.items.count)项 · 共\(controller.total)项").font(VisualStyle.sectionText).foregroundStyle(.secondary).padding(.horizontal,14).frame(height:26)
                    if controller.items.isEmpty {
                        VStack(spacing:10) {
                            Image(systemName:"list.clipboard").font(.system(size:26))
                            Text(controller.captureEnabled ? "没有匹配记录" : "采集已暂停")
                            Text(controller.captureEnabled ? "复制文字、图片或文件后，会保存到这台Mac。" : "在剪贴板设置中开启本地历史。").font(.caption)
                            Button("剪贴板设置…") { (NSApp.delegate as? Delegate)?.model.openSettings(page:"clipboard") }.buttonStyle(.glass)
                        }.foregroundStyle(.secondary).frame(maxWidth:.infinity).padding(.horizontal,14).padding(.top,55)
                    }
                    ForEach(controller.items) { item in
                        Button { controller.select(item.id) } label: {
                            HStack(spacing:10) {
                                Image(systemName:item.kind == .text ? "text.alignleft" : item.kind == .image ? "photo" : "doc.on.doc")
                                    .font(.system(size:20)).foregroundStyle(.secondary).frame(width:26,height:26)
                                VStack(alignment:.leading,spacing:3) {
                                    HighlightedResultText(text:item.preview.replacingOccurrences(of:"\n",with:" "),query:query)
                                        .font(VisualStyle.rowText).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading)
                                    HStack(spacing:5) { if item.pinned { Image(systemName:"pin.fill") }; Text(item.source); Spacer(minLength:0); Text(item.copiedAt,style:.time) }
                                        .font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.padding(.horizontal,10).frame(height:48)
                                .background(item.id == controller.selectedID ? Color.primary.opacity(0.10) : .clear,in:RoundedRectangle(cornerRadius:9))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).id(item.id)
                    }
                }.padding(.horizontal,8).padding(.bottom,6)
            }.scrollIndicators(.visible,axes:.vertical)
                .contentMargins(.top,61,for:.scrollContent).contentMargins(.bottom,52,for:.scrollContent)
                .contentMargins(.top,61,for:.scrollIndicators).contentMargins(.bottom,52,for:.scrollIndicators)
                .scrollEdgeEffectStyle(.soft,for:[.top,.bottom])
                .onChange(of:controller.selectedID) { _, id in if let id { proxy.scrollTo(id) } }
                .onChange(of:query) { _, _ in if let first = controller.items.first { proxy.scrollTo(first.id,anchor:.top) } }
        }
    }
    private func formatTitle(_ type: String) -> String {
        switch type {
        case "public.utf8-plain-text","public.utf16-plain-text": return "文字"
        case "public.rtf","com.apple.flat-rtfd": return "富文本"
        case "public.html": return "HTML"
        case "public.file-url": return "文件"
        case "public.url": return "链接"
        case "com.adobe.pdf": return "PDF"
        default: return type == "com.compuserve.gif" ? "GIF" : type.split(separator:".").last?.uppercased() ?? "图片"
        }
    }
}

struct ClipboardPreferences: View {
    @ObservedObject var controller: ClipboardController
    @ObservedObject var model: Model
    @State private var confirmsClear = false
    @State private var clearAll = false
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View { VStack(alignment: .leading, spacing: 12, content: content).frame(maxWidth: .infinity, alignment: .leading).padding(18).modifier(SettingsSurface()) }
    var body: some View {
        VStack(spacing: 16) {
            card {
                Toggle("记录剪贴板历史", isOn: $controller.captureEnabled)
                Text("开启后，将之后复制的文字、图片和文件引用保存在这台 Mac，退出和重启后仍可查找。默认跳过带有敏感、临时标记的内容及密码管理器。保留文字、富文本、HTML、图片及多个项目的标准格式，可另行复制为纯文本。").foregroundStyle(.secondary)
                Text("本地资料未加密，不会上云。关闭采集会保留已保存的历史；可在下方单独清理。").font(.caption).foregroundStyle(.secondary)
                Toggle("自动识别新图片中的文字", isOn: $controller.automaticOCR)
                Text("使用本机 Vision，识别结果可搜索；也可在预览中手动识别。").font(.caption).foregroundStyle(.secondary)
            }.id("capture")
            card {
                LabeledContent("剪贴板快捷键") { ShortcutRecorder(shortcut:model.bindings["clipboard"]) { model.setShortcut("clipboard",value:$0) } }
                SettingsPicker("回车动作",selection:$controller.primaryAction) { Text("仅复制").tag("copy"); Text("粘贴到上个应用").tag("paste") }
                Text("自动粘贴需要辅助功能权限；只在目标应用成功获得焦点后发送粘贴按键。").font(.caption).foregroundStyle(.secondary)
                Button("允许辅助功能…") { model.requestKeyboardAccess() }.buttonStyle(.glass)
                if !controller.accessMessage.isEmpty { Text(controller.accessMessage).font(.caption).foregroundStyle(.orange); Button("打开系统设置") { NSWorkspace.shared.open(URL(fileURLWithPath:"/System/Applications/System Settings.app")) }.buttonStyle(.glass) }
            }
            card {
                SettingsPicker("保留时间", selection: $controller.retentionDays) { Text("7天").tag(7); Text("30天").tag(30); Text("90天").tag(90); Text("1年").tag(365) }
                SettingsPicker("记录上限", selection: $controller.maxItems) { Text("100项").tag(100); Text("500项").tag(500); Text("1000项").tag(1000) }
                Text("内容总量上限256MB。置顶记录不参与自动清理（最多100项）。单条文字1MB、图片16MB/2000万像素、文件引用128项；同一次复制所有格式合计32MB。列表一次显示最多200项，可搜索缩小范围。").font(.caption).foregroundStyle(.secondary)
                Text("文件仅保存位置引用，清理历史不会删除原文件；移走后的文件可能无法复制。").font(.caption).foregroundStyle(.secondary)
            }
            card {
                HStack { Text("不记录这些应用").font(.headline); Spacer(); Button("添加应用…", systemImage: "plus") { controller.addExcludedApplication() }.buttonStyle(.glass) }
                ForEach(controller.excludedApps.sorted(), id: \.self) { id in
                    HStack {
                        Text(NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path) } ?? id).font(.caption)
                        Spacer()
                        if !ClipboardPolicy.defaultExcluded.contains(id) { Button("移除") { controller.excludedApps.remove(id) }.buttonStyle(.plain) }
                    }
                }
            }
            card {
                LabeledContent("已保存", value: "\(controller.total)项")
                if controller.migrationBackupCount > 0 { Text("保留了\(controller.migrationBackupCount)份升级前备份，包含旧历史与自有图片。清理全部历史时会一并删除；清理未置顶历史时保留备份。").font(.caption).foregroundStyle(.secondary) }
                HStack { Button("清理未置顶历史…", role: .destructive) { clearAll = false; confirmsClear = true }; Button("清理全部历史…", role: .destructive) { clearAll = true; confirmsClear = true } }.buttonStyle(.glass)
                if !controller.status.isEmpty { Text(controller.status).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .confirmationDialog("清理剪贴板历史？", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button(clearAll ? "删除全部记录、历史图片及升级备份" : "删除未置顶记录及历史图片", role: .destructive) { controller.clear(includePinned: clearAll) }
            Button("取消", role: .cancel) {}
        } message: { Text("此操作无法撤销。原文件和当前剪贴板内容不会被删除。") }
    }
}
