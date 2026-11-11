import KeylaneCore
import SwiftUI

struct ScriptCreationPage: View {
    @ObservedObject var controller: ScriptCommandsController
    let back: () -> Void
    @FocusState private var focus: String?

    var body: some View {
        LauncherCreationForm(back: back, spacing: 16) { EmptyView() } fields: {
            LauncherCreationField("模板") {
                LauncherCreationControl {
                    Picker("模板", selection: $controller.template) {
                        ForEach(ScriptTemplate.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().pickerStyle(.menu)
                }
            }
            LauncherCreationField("模式") {
                LauncherCreationControl {
                    Picker("模式", selection: $controller.draft.mode) {
                        Text("静默 · Silent").tag(ScriptMetadata.Mode.silent)
                        Text("精简 · Compact").tag(ScriptMetadata.Mode.compact)
                        Text("完整输出 · Full Output").tag(ScriptMetadata.Mode.fullOutput)
                        Text("行内 · Inline").tag(ScriptMetadata.Mode.inline)
                    }.labelsHidden().pickerStyle(.menu)
                }
            }
            field("标题", "命令标题", $controller.draft.title)
            field("描述", "命令用途", $controller.draft.description)
            field("包名称", "例如：开发工具", $controller.draft.packageName)
            LauncherCreationField("") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("运行前确认", isOn: $controller.draft.needsConfirmation)
                    Toggle("带参数", isOn: $controller.includeArgument)
                        .disabled(controller.draft.mode == .inline)
                }
                .toggleStyle(.checkbox)
            }
            if controller.draft.mode == .inline {
                field("刷新间隔", "例如：1m", $controller.draft.refreshTime, detail: "至少 10 秒。首次手动运行后才会自动刷新。")
            } else if controller.includeArgument {
                ForEach(controller.draft.arguments.indices, id: \.self) { index in
                    let argument = $controller.draft.arguments[index]
                    LauncherCreationField("参数 \(index + 1)") {
                        VStack(alignment: .leading, spacing: 8) {
                            LauncherCreationControl {
                                TextField("占位提示", text: argument.placeholder).textFieldStyle(.plain)
                            }
                            Picker("类型", selection: argument.type) {
                                Text("文字").tag(ScriptMetadata.Argument.Kind.text)
                                Text("密码").tag(ScriptMetadata.Argument.Kind.password)
                                Text("下拉菜单").tag(ScriptMetadata.Argument.Kind.dropdown)
                            }
                            Toggle("可选参数", isOn: Binding(get: { argument.wrappedValue.optional == true }, set: { argument.wrappedValue.optional = $0 }))
                            Toggle("百分号编码", isOn: Binding(get: { argument.wrappedValue.percentEncoded == true }, set: { argument.wrappedValue.percentEncoded = $0 }))
                            if argument.wrappedValue.type == .dropdown {
                                LauncherCreationControl {
                                    TextField("选项，用英文逗号分隔", text: $controller.draftChoiceText[index])
                                        .textFieldStyle(.plain)
                                }
                            }
                            Button("移除此参数", role: .destructive) {
                                controller.removeDraftArgument(at: index)
                            }.buttonStyle(.plain)
                        }.toggleStyle(.checkbox)
                    }
                }
                if controller.draft.arguments.count < 3 {
                    LauncherCreationField("") {
                        Button("添加参数", systemImage: "plus") {
                            controller.addDraftArgument()
                        }.buttonStyle(.bordered)
                    }
                }
            }
            Divider()
            field("作者", "作者名称", $controller.draft.author)
            field("作者链接", "网站或联系地址", $controller.draft.authorURL)
            field("图标", "Emoji、图片路径或 HTTPS 链接", $controller.draft.icon)
            field("深色图标", "可选", $controller.draft.iconDark)
            field("工作目录", "默认使用脚本所在目录", $controller.draft.currentDirectoryPath)
            if !controller.creationError.isEmpty {
                LauncherCreationField("") {
                    Text(controller.creationError).foregroundStyle(.red)
                }
            }
        }
        .task { focus = "标题" }
        .onChange(of: controller.includeArgument) { _, enabled in
            if enabled, controller.draft.arguments.isEmpty { controller.addDraftArgument() }
        }
        .onChange(of: controller.draft.mode) { _, mode in
            if mode == .inline { controller.includeArgument = false }
        }
        .onExitCommand(perform: back)
    }

    private func field(_ title: String, _ prompt: String, _ text: Binding<String>, detail: String? = nil) -> some View {
        LauncherCreationField(title, detail: detail) {
            LauncherCreationControl(focused: focus == title) {
                TextField(prompt, text: text).textFieldStyle(.plain).focused($focus, equals: title)
            }
        }
    }
}

struct ScriptArtwork: View {
    let script: ScriptCommand
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let metadata = script.metadata
        let value = colorScheme == .dark && metadata?.iconDark.isEmpty == false ? metadata?.iconDark : metadata?.icon
        if let value, let url = URL(string: value), url.scheme?.lowercased() == "https" {
            AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { fallback }
        } else if let value, !value.isEmpty {
            let path = (value as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: path, relativeTo: script.url.deletingLastPathComponent())
            if ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit()
            } else if value.count <= 4, value.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }) {
                Text(value).font(.system(size: 19))
            } else {
                fallback
            }
        } else {
            fallback
        }
    }

    private var fallback: some View { Image(systemName: "terminal").foregroundStyle(.secondary) }
}
