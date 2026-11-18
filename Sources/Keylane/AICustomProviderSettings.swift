import AppKit
import CryptoKit
import KeylaneProviderConfig
import SwiftUI

struct AICustomProviderSettings: View {
    @ObservedObject var configuration: AIConfiguration
    @State private var status = ""
    @State private var loadedDigest: SHA256.Digest?
    @State private var loading: Task<Void, Never>?
    private var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/keylane/ai")
    }

    var body: some View {
        SettingsGroup("自定义提供商") {
            SettingsRow("Providers Config", detail: status.isEmpty
                        ? "编辑 providers.yaml 后返回设置页，自动刷新模型配置。API Key 会写入本机钥匙串。" : status) {
                Button("打开配置文件", action: reveal)
            }
            Divider()
            SettingsRow("刷新配置") {
                if loading != nil { ProgressView().controlSize(.small) }
                else { Button("重新载入", action: load) }
            }
        }
        .task { load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in load() }
    }

    private func reveal() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let template = folder.appendingPathComponent("providers.template.yaml")
            if !FileManager.default.fileExists(atPath: template.path) {
                try Self.template.write(to: template, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: template.path)
            }
            let file = folder.appendingPathComponent("providers.yaml")
            if !FileManager.default.fileExists(atPath: file.path) {
                try "providers: []\n".write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            NSWorkspace.shared.activateFileViewerSelecting([file, template])
        } catch { status = "无法创建配置文件。" }
    }

    private func load() {
        guard loading == nil else { return }
        let file = folder.appendingPathComponent("providers.yaml")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        loading = Task { @MainActor in
            do {
                let (imported, digest) = try await Task.detached(priority: .utility) { try Self.read(file) }.value
                guard digest != loadedDigest else { loading = nil; return }
                try await configuration.applyCustomProviders(imported)
                loadedDigest = digest
                status = "已载入 \(imported.count) 个模型。YAML 的 tools 配置尚未接入。"
            } catch {
                // Decoder descriptions can contain source lines, including credentials.
                status = (error as? CustomProviderDocument.Failure)?.localizedDescription
                    ?? "配置无法解析，请检查 YAML 结构。之前的有效配置继续可用。"
            }
            loading = nil
        }
    }

    private static func read(_ file: URL) throws -> ([(AIConnection, String?)], SHA256.Digest) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        let digest = SHA256.hash(data: data)
        let document = try CustomProviderDocument.decode(data)
        var imported = [(AIConnection, String?)]()
        for provider in document.providers {
            for model in provider.models {
                let sourceID = CustomProviderDocument.modelIdentity(providerID: provider.id, modelID: model.id)
                let digest = SHA256.hash(data: Data(("keylane.custom." + sourceID).utf8))
                let id = UUID(uuid: Array(digest).withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) })
                var connection = AIConnection(id: id, name: model.name ?? model.id, endpoint: provider.base_url, model: model.id)
                connection.contextTokens = model.context
                connection.supportsImages = model.abilities?["vision"]?.supported
                connection.supportsTools = model.abilities?["tools"]?.supported
                connection.customConfigID = sourceID
                connection.additionalParametersJSON = try provider.additional_parameters?.json()
                let key = model.provider.flatMap { provider.api_keys?[$0] } ?? provider.api_keys?.values.first
                imported.append((connection, key))
            }
        }
        return (imported, digest)
    }

    private static let template = """
    # OpenAI-compatible providers. Keep this file private when it contains API keys.
    providers:
      - id: example
        name: My Provider
        base_url: https://api.example.com/v1
        api_keys:
          main: REPLACE_WITH_YOUR_KEY
        additional_parameters:
          temperature: 0.7
        models:
          - id: model-id
            name: My Model
            provider: main
            context: 128000
            abilities:
              vision:
                supported: false
              tools:
                supported: false

    """
}
