import AppKit
import SwiftUI

struct AIChatProjectEditor: View {
    @ObservedObject var controller: QuickAIController
    @State var project: AIChatProject
    let completed: (AIChatProject) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var folderError = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("项目", systemImage: project.symbol).font(.headline)
            HStack {
                TextField("项目名称", text: $project.name).textFieldStyle(.roundedBorder)
                Picker("图标", selection: $project.symbol) {
                    Label("文件夹", systemImage: "folder").tag("folder")
                    Label("工作", systemImage: "briefcase").tag("briefcase")
                    Label("学习", systemImage: "book").tag("book")
                    Label("代码", systemImage: "chevron.left.forwardslash.chevron.right").tag("chevron.left.forwardslash.chevron.right")
                }.labelsHidden().frame(width: 105)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("项目指令").font(.subheadline)
                TextEditor(text: $project.instructions).font(.system(size: 13)).frame(height: 110)
                    .padding(8).scrollContentBackground(.hidden)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                Text("应用于项目中会话的后续消息；不会自动读取其他会话或文件。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("默认附件目录").font(.subheadline)
                    Text(project.directory?.path ?? "未设置").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("选择目录…", action: chooseDirectory)
                if project.directory != nil {
                    Button("移除", systemImage: "xmark") { project.directory = nil; project.directoryBookmark = nil }
                        .labelStyle(.iconOnly)
                }
            }
            Text("工具运行目录、跨会话记忆将在对应基础服务接入后提供。")
                .font(.caption).foregroundStyle(.secondary)
            if !folderError.isEmpty { Text(folderError).font(.caption).foregroundStyle(.secondary) }
            if !controller.projectError.isEmpty { Text(controller.projectError).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(saving ? "保存中…" : "保存项目") {
                    saving = true
                    project.name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    controller.saveProject(project) { saved in
                        saving = false
                        if saved { completed(project); dismiss() }
                    }
                }.keyboardShortcut(.defaultAction)
                    .disabled(saving || project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || project.name.count > 120 || project.instructions.utf8.count > 32_000)
            }
        }.padding(24).frame(width: 520)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = project.directoryURL
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                project.directoryBookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                project.directory = url
                folderError = ""
            } catch { folderError = "无法保存所选目录的访问授权。" }
        }
    }
}
