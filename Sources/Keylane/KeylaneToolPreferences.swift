import SwiftUI
import KeylaneCore

struct KeylaneToolPreferences: View {
    let model: Model
    @ObservedObject var camera: CameraPreview
    let commands: [LauncherModule.Command]
    @StateObject private var observation: ViewObservation
    @State private var expanded: Set<String> = []
    @State private var copyCapture = KeylaneToolActions.copiesCapture
    @State private var revealCapture = KeylaneToolActions.revealsCapture

    init(model: Model, camera: CameraPreview, commands: [LauncherModule.Command]) {
        self.model = model
        self.camera = camera
        self.commands = commands
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.$aliases), ViewObservation.changes(model.$bindings),
            ViewObservation.changes(model.$disabledCommands)
        ] + commands.compactMap { $0.permission?.settingsUpdates }))
    }

    var body: some View {
        let order = [
            "capture-keylane-window", "view-release-notes", "check-extension-updates", "check-for-updates",
            "copy-keylane-logs", "copy-keylane-version", "export-settings", "import-settings", "show-camera",
            "open-keylane-website", "open-keylane-github", "quit-keylane", "reveal-keylane-logs",
            "send-keylane-feedback", "settings", "share-keylane", "show-onboarding", "keylane-extension-store", "screenshot"
        ]
        let rows = order.compactMap { rawID in
            commands.first { $0.declaration.id.rawValue == rawID }
                ?? model.launcherModules?.declaration(.init(rawValue: rawID)).map { LauncherModule.Command(declaration: $0) }
        }
        SettingsPageSections {
            SettingsCard(anchor: .keylaneTools) {
                Button("导出 Keylane 设置与数据", systemImage: "square.and.arrow.up", action: ConfigurationTransfer.export)
                    .buttonStyle(.plain)
            }
            SettingsSectionTitle(title: "命令")
            CommandSettingsList(items: rows, id: \.declaration.id, disclosure: disclosure) { command in
                let declaration = command.declaration
                let id = declaration.id
                let available = command.available()
                var entry = CommandSettingsEntry(title: declaration.title, model: model, commandID: id,
                    isEnabled: available ? (command.settingsEnabled ?? enabled(id)) : .constant(false),
                    help: available ? nil : "即将推出") {
                        SettingsIcon(symbol: declaration.symbol, artwork: ModuleArtwork.command(id, settingsPage: AppUtilitiesModule.settingsID))
                    }
                entry.available = available
                entry.permission = command.permission
                return entry
            }
        }
    }

    private func enabled(_ id: CommandID) -> Binding<Bool> {
        Binding(get: { !model.disabledCommands.contains(id.rawValue) }, set: { enabled in
            if enabled { model.disabledCommands.remove(id.rawValue) }
            else { model.disabledCommands.insert(id.rawValue) }
        })
    }

    private func disclosure(_ command: LauncherModule.Command) -> CommandSettingsDisclosure? {
        let id = command.declaration.id.rawValue
        guard id == "capture-keylane-window" || id == "show-camera" else { return nil }
        return CommandSettingsDisclosure(isExpanded: Binding(get: { expanded.contains(id) }, set: { value in
            if value { expanded.insert(id) } else { expanded.remove(id) }
        }), revealItem: id == "capture-keylane-window" ? .keylaneWindowCapture : .keylaneCamera) {
            AnyView(VStack(alignment: .leading, spacing: 10) {
                if id == "capture-keylane-window" {
                    Toggle("复制到剪贴板", isOn: $copyCapture)
                    Divider()
                    Toggle(isOn: $revealCapture) {
                        SettingsCaption(title: "在 Finder 中显示", detail: "将窗口图像存到桌面，并在 Finder 中选中。")
                    }
                } else {
                    SettingsPicker("主要操作", selection: $camera.primaryDestination) {
                        ForEach(CameraPreview.PhotoDestination.allCases, id: \.self) { destination in
                            Text(destination.title).tag(destination)
                        }
                    }
                    Divider()
                    Toggle("播放快门声", isOn: Binding(get: { camera.shutterEnabled }, set: {
                        if $0 != camera.shutterEnabled { camera.toggleShutter() }
                    }))
                    Divider()
                    Toggle("记住上次使用的摄像头", isOn: $camera.remembersCamera)
                }
            }.onChange(of: copyCapture) { _, value in KeylaneToolActions.copiesCapture = value }
             .onChange(of: revealCapture) { _, value in KeylaneToolActions.revealsCapture = value })
        }
    }
}
