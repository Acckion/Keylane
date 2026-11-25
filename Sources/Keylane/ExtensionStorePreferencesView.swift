import AppKit
import KeylaneCore
import UniformTypeIdentifiers
import SwiftUI

/// Preferences UI shared by installed extensions; no concrete storage is selected here.
struct ExtensionStorePreferencesView: View {
    let installationID: UUID
    let generation: UInt64
    let schema: RaycastStorePreferenceSchema
    let persistence: any RaycastStorePreferencePersistence
    let onSaved: () -> Void

    init(installationID: UUID, generation: UInt64, schema: RaycastStorePreferenceSchema,
         persistence: any RaycastStorePreferencePersistence, onSaved: @escaping () -> Void = {}) {
        self.installationID = installationID
        self.generation = generation
        self.schema = schema
        self.persistence = persistence
        self.onSaved = onSaved
    }

    private struct Context: Equatable {
        let installationID: UUID
        let generation: UInt64
    }

    @State private var snapshot: RaycastStorePreferenceSnapshot?
    @State private var changes = RaycastStorePreferenceChanges()
    @State private var failure: String?
    @State private var saving = false

    private var context: Context { .init(installationID: installationID, generation: generation) }

    var body: some View {
        SettingsPageSections {
            if let snapshot {
                let issues = schema.validate(snapshot: snapshot, changes: changes)
                SettingsGroup {
                    ForEach(schema.entries) { entry in
                        SettingsRow(entry.field.title ?? entry.field.name, detail: entry.field.description) {
                            editor(entry, snapshot: snapshot)
                        }
                    }
                }
                if !issues.isEmpty {
                    Text("请补齐必填设置，或更新无效、未支持的设置。").font(.caption)
                }
                Button("保存设置") { Task { await save() } }
                    .disabled(saving || !issues.isEmpty || (changes.values.isEmpty && changes.secrets.isEmpty))
            } else if failure == nil {
                ProgressView()
            } else {
                Button("重试") { Task { await load() } }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        }
        .disabled(saving)
        .task(id: context) { await load() }
        .onDisappear { changes = .init() }
    }

    @ViewBuilder
    private func editor(_ entry: RaycastStorePreferenceSchema.Entry, snapshot: RaycastStorePreferenceSnapshot) -> some View {
        let key = entry.id
        switch entry.field.type {
        case "password":
            SecureField(snapshot.storedSecretKeys.contains(key) ? "已保存，输入以替换" : "输入密码", text: Binding(
                get: { if case .set(let value) = changes.secrets[key] { return value }; return "" },
                set: { changes.secrets[key] = $0.isEmpty ? nil : .set($0) }
            ))
            if snapshot.storedSecretKeys.contains(key) && entry.field.required != true {
                Button("移除") { changes.secrets[key] = .remove }
            }
        case "checkbox":
            Toggle(entry.field.title ?? key.name, isOn: Binding(
                get: { if case .bool(let value) = schema.value(for: entry, snapshot: snapshot, changes: changes) { return value }; return false },
                set: { changes.values[key] = .set(.bool($0)) }
            )).labelsHidden()
            if schema.value(for: entry, snapshot: snapshot, changes: changes) == nil && entry.field.required == true {
                Button("设为关闭") { changes.values[key] = .set(.bool(false)) }
            }
        case "dropdown":
            Picker(entry.field.title ?? key.name, selection: Binding<String?>(
                get: { if case .string(let value) = schema.value(for: entry, snapshot: snapshot, changes: changes) { return value }; return nil },
                set: { changes.values[key] = $0.map { .set(.string($0)) } ?? .reset }
            )) {
                Text("未选择").tag(nil as String?)
                ForEach(Array((entry.field.options ?? []).enumerated()), id: \.offset) { _, option in
                    Text(option.title).tag(Optional(option.value))
                }
            }.labelsHidden()
        case "textfield":
            TextField(entry.field.placeholder ?? "", text: Binding(
                get: { if case .string(let value) = schema.value(for: entry, snapshot: snapshot, changes: changes) { return value }; return "" },
                set: { changes.values[key] = .set(.string($0)) }
            ))
        case "file", "directory", "appPicker":
            let label: String = {
                switch schema.value(for: entry, snapshot: snapshot, changes: changes) {
                case .application(let app): return app.localizedName ?? app.name
                case .string(let path): return URL(fileURLWithPath: path).lastPathComponent
                default: return "未选择"
                }
            }()
            Text(label).lineLimit(1)
            Button("选择…") { Task { @MainActor in await choose(entry) } }
            if entry.field.required != true {
                Button("清除") { changes.values[key] = .reset }
            }
        default:
            Text("此设置类型暂不支持编辑").foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func choose(_ entry: RaycastStorePreferenceSchema.Entry) async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = entry.field.type == "directory"
        panel.canChooseFiles = entry.field.type != "directory"
        if entry.field.type == "appPicker" { panel.allowedContentTypes = [.application] }
        guard await panel.begin() == .OK, let url = panel.url else { return }
        let value: RaycastExtensionManifest.PreferenceValue
        if entry.field.type == "appPicker" {
            guard let application = RaycastApplicationValue(url: url) else { return }
            value = .application(application)
        } else {
            value = .string(url.standardizedFileURL.path)
        }
        if entry.field.accepts(value) { changes.values[entry.id] = .set(value) }
    }

    @MainActor
    private func load() async {
        snapshot = nil
        changes = .init()
        failure = nil
        do {
            let loaded = try await persistence.load(installationID: installationID, generation: generation)
            try Task.checkCancellation()
            snapshot = loaded
        } catch {
            guard !Task.isCancelled else { return }
            failure = "无法读取扩展设置。"
        }
    }

    @MainActor
    private func save() async {
        guard !saving, let snapshot, schema.validate(snapshot: snapshot, changes: changes).isEmpty else { return }
        saving = true
        failure = nil
        defer { saving = false }
        let payload = changes
        // Drop the plaintext draft before the asynchronous call and do not restore it on failure.
        changes.secrets.removeAll()
        do {
            try await persistence.save(installationID: installationID, generation: generation, changes: payload)
        } catch {
            failure = "无法保存扩展设置，请重试。"
            return
        }
        onSaved()
        await load()
    }
}
