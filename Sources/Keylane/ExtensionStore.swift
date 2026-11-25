import AppKit
import Combine
import ImageIO
import KeylaneCore
import SwiftUI

final class ExtensionStoreController: ObservableObject {
    private static let pageID = PageID(rawValue: "ExtensionStore")
    private static let symbol = "storefront"

    private let catalog = RaycastPublicCatalog()
    @Published private var index: RaycastPublicCatalog.Index?
    @Published private(set) var metadata: [String: RaycastPublicCatalog.Details] = [:]
    @Published private(set) var selected: String?
    @Published private(set) var detail: String?
    @Published private(set) var focusedPreferences: String?
    private var pendingPreferencesEntry = false
    private var detailSource: RaycastStoreSource?
    @Published var uuidArgument = ""
    @Published var typeIDPrefix = ""
    @Published private(set) var query = ""
    @Published private(set) var category = "all"
    @Published private(set) var status: String?
    @Published private(set) var refresh = 0
    @Published private(set) var unavailableDetails: Set<String> = []
    private var loadedDirectory = false
    private var installer = RaycastStoreInstaller()
    private(set) var backend: RaycastStoreInstallCoordinator?
    var backendReady: Bool { backend != nil }
    @Published var configuring = false
    @Published var configurationError: String?
    @Published var canReplaceIncompatibleProfile = false
    private let runtimeConfiguration = Bundle.main.url(
        forResource: "ExtensionBuild", withExtension: "json"
    ).flatMap { try? Data(contentsOf: $0) }.flatMap {
        try? JSONDecoder().decode(MacOSBuildProfile.Configuration.self, from: $0)
    }
    var profilePreferenceKey: String {
        runtimeConfiguration?.storage == "legacy-login-keychain-preview-v1"
            ? "extensionStore.activeMacOSPreviewProfile"
            : "extensionStore.activeMacOSProfile"
    }
    var canConfigure: Bool { runtimeConfiguration?.runHelperSHA256 != nil && !configuring && !backendReady }
    @Published private var pendingInstallations: Set<String> = []
    @Published private(set) var inventoryStatus: String?
    @Published private var presentation = RaycastStorePresentationState()
    var readinessMessages: [String: String] { presentation.readinessMessages }
    @Published private var installed: [String: RaycastStoreInstallation] = [:]
    @Published private var diagnosticsByInstallation: [UUID: [MacOSNoViewCapabilities.Diagnostic]] = [:]

    @MainActor func recordDiagnostics(installationID: String, generation: UInt64,
                                     samples: [MacOSNoViewCapabilities.Diagnostic]) {
        guard let id = UUID(uuidString: installationID), let receipt = installed.values.first(where: { $0.id == id }),
              receipt.enabled, receipt.generation == generation else { return }
        diagnosticsByInstallation[id] = Array((diagnosticsByInstallation[id, default: []] + samples).suffix(16))
    }

    func diagnostics(_ slug: String) -> [MacOSNoViewCapabilities.Diagnostic] {
        installed[slug].flatMap { diagnosticsByInstallation[$0.id] } ?? []
    }

    var launcherModules: [UUID: (generation: UInt64, installed: Bool)] = [:]

    @MainActor func attach(_ backend: RaycastStoreInstallCoordinator) {
        self.backend = backend
        installer = RaycastStoreInstaller(backend: backend)
        configurationError = nil
        canReplaceIncompatibleProfile = false
    }

    @MainActor func showPreferences(installationID: String, generation: UInt64, commandID: String?, model: Model) {
        guard let receipt = installed.values.first(where: {
            $0.id.uuidString == installationID && $0.generation == generation && $0.enabled
        }) else { return }
        if let commandID, !receipt.manifest.commands.contains(where: { $0.id == commandID }) { return }
        showDetails(receipt.source.slug)
        guard detailSource == receipt.source else { return }
        query = ""
        focusedPreferences = commandID ?? ""
        pendingPreferencesEntry = model.pageID != Self.pageID
        model.openPage(Self.pageID, origin: .menu)
    }

    func preferencesView(_ slug: String) -> AnyView? {
        guard let receipt = installed[slug] else { return nil }
        let manifest = receipt.manifest
        guard !manifest.preferences.isEmpty || manifest.commands.contains(where: { !$0.preferences.isEmpty }) else { return nil }
        guard let persistence = backend else {
            return AnyView(Text("扩展包含配置项，但安全偏好存储尚未接入；需要配置的命令不可运行。")
                .font(.caption).foregroundStyle(.secondary))
        }
        let callback = { Task { @MainActor in await self.refreshReadiness(slug) }; return () }
        return AnyView(VStack(alignment: .leading, spacing: 12) {
            if !manifest.preferences.isEmpty, focusedPreferences == nil || focusedPreferences == "" {
                if let schema = try? RaycastStorePreferenceSchema(manifest: manifest) {
                    let form = ExtensionStorePreferencesView(installationID: receipt.id, generation: receipt.generation,
                        schema: schema, persistence: persistence, onSaved: callback)
                        .id(receipt.id.uuidString + "/" + String(receipt.generation) + "/global")
                    if focusedPreferences == "" { form }
                    else { DisclosureGroup("扩展通用配置") { form } }
                } else { Text("扩展配置结构无效，无法编辑。") }
            }
            ForEach(manifest.commands.filter {
                focusedPreferences == nil ? !$0.preferences.isEmpty : focusedPreferences == $0.id
            }, id: \.id) { command in
                if let schema = try? RaycastStorePreferenceSchema(manifest: manifest, commandID: command.id) {
                    let form = ExtensionStorePreferencesView(installationID: receipt.id, generation: receipt.generation,
                        schema: schema, persistence: persistence, onSaved: callback)
                        .id(receipt.id.uuidString + "/" + String(receipt.generation) + "/" + command.id)
                    if self.focusedPreferences == command.id { form }
                    else { DisclosureGroup("配置：" + command.title) { form } }
                } else { Text("命令配置结构无效，无法编辑。") }
            }
        })
    }

    func isInstalled(_ slug: String) -> Bool { installed[slug] != nil }

    func installationStatus(_ slug: String) -> String? {
        if let message = presentation.installationMessages[slug] { return message }
        if let receipt = installed[slug] { return receipt.enabled ? "已安装并启用" : "已安装，已停用" }
        if metadata[slug]?.supportsMacOS == false { return "此扩展不支持 macOS" }
        return nil
    }

    func installationActions(_ slug: String) -> [LauncherAction] {
        guard let source = source(slug) else { return [] }
        let available = backendReady && !configuring && !pendingInstallations.contains(slug)
        if presentation.needsReconciliation.contains(slug) {
            return [.init(id: "store-reconcile", title: "核对安装记录", icon: "arrow.clockwise", enabled: available) {
                Task { @MainActor in await self.mutate(source, operation: .reconcile) }
            }]
        }
        if let receipt = installed[slug] {
            let commands: [LauncherAction] = receipt.manifest.commands.map { command in
                let uuid = uuidArgument.trimmingCharacters(in: .whitespacesAndNewlines)
                let reviewed = MacOSReviewedRaycastCommand.entry(forCommandID: command.id)
                let inputs = reviewed?.argumentNames ?? []
                let prefix = typeIDPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
                let values = inputs.count == 2 ? [prefix, uuid] : [uuid]
                let hasValues = !inputs.isEmpty && values.allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 }
                return .init(id: "store-run-" + command.name, title: "运行：" + command.title, icon: "play",
                      enabled: available && receipt.enabled && (inputs.isEmpty || hasValues || (uuid.isEmpty && reviewed?.argumentIsOptional == true))
                        && presentation.launchReady.contains(receipt.id.uuidString + "/" + command.id)) {
                    if command.mode == .view {
                        let model = (NSApp.delegate as? Delegate)?.model
                        if model?.runCommand(.init(rawValue: command.id), origin: .menu) != true {
                            self.presentation.installationMessages[slug] = "扩展页面未能打开，请检查安装状态。"
                        }
                        return
                    }
                    Task { @MainActor in
                        do {
                            if !inputs.isEmpty, let backend = self.backend {
                                try await withMacOSExtensionPresentation(NSApp.delegate as? Delegate) {
                                    try await backend.launch(receipt, commandID: command.id, arguments: hasValues ? Dictionary(uniqueKeysWithValues: zip(inputs, values)) : [:])
                                }
                            } else {
                                try await withMacOSExtensionPresentation(NSApp.delegate as? Delegate) {
                                    try await self.installer.launch(slug: slug, commandID: command.id)
                                }
                                if MacOSReviewedRaycastCommand.entry(forCommandID: command.id) == nil {
                                    (NSApp.delegate as? Delegate)?.showLauncherFeedback("扩展命令已完成。", style: .success)
                                }
                            }
                            self.presentation.installationMessages[slug] = nil
                        } catch { self.presentation.installationMessages[slug] = (error as? RaycastStoreInstaller.Failure)?.errorDescription ?? "命令未能运行，请检查配置、权限或兼容性。" }
                    }
                }
            }
            return commands + [
                .init(id: "store-toggle", title: receipt.enabled ? "停用扩展" : "启用扩展", icon: "power", enabled: available) {
                    Task { @MainActor in await self.mutate(source, operation: .toggle(!receipt.enabled)) }
                },
                .init(id: "store-uninstall", title: "卸载扩展", icon: "trash", enabled: available, destructive: true) {
                    Task { @MainActor in await self.mutate(source, operation: .uninstall) }
                }
            ]
        }
        return [.init(id: "store-install", title: "安装扩展", icon: "arrow.down.circle", enabled: available && metadata[slug]?.supportsMacOS != false) {
            Task { @MainActor in await self.mutate(source, operation: .install) }
        }]
    }

    private enum Mutation { case install, toggle(Bool), uninstall, reconcile }

    @MainActor private func mutate(_ source: RaycastStoreSource, operation: Mutation) async {
        guard pendingInstallations.insert(source.slug).inserted else { return }
        defer { pendingInstallations.remove(source.slug) }
        let previousID = installed[source.slug]?.id
        presentation.invalidateReadiness(installationID: previousID, slug: source.slug)
        presentation.installationMessages[source.slug] = "正在处理；尚未确认完成…"
        do {
            switch operation {
            case .install: _ = try await installer.prepareAndInstall(source)
            case .toggle(let enabled): try await installer.setEnabled(slug: source.slug, enabled: enabled)
            case .uninstall: try await installer.uninstall(slug: source.slug)
            case .reconcile: try await installer.reconcile(slug: source.slug)
            }
            if case .installed(let receipt) = await installer.state(for: source.slug) { installed[source.slug] = receipt }
            else {
                installed.removeValue(forKey: source.slug)
                if let previousID { diagnosticsByInstallation.removeValue(forKey: previousID) }
            }
            await (NSApp.delegate as? Delegate)?.updateMacOSExtensionModule(installed[source.slug], replacing: previousID)
            presentation.needsReconciliation.remove(source.slug)
            presentation.installationMessages.removeValue(forKey: source.slug)
            await refreshReadiness(source.slug)
        } catch {
            if let failure = error as? RaycastStoreInstaller.Failure,
               [.installationOutcomeUnknown, .operationOutcomeUnknown, .invalidReceipt, .existingDifferentRevision, .reconciliationFailed].contains(failure) {
                presentation.needsReconciliation.insert(source.slug)
            }
            // Do not display arbitrary build output, which may contain user secrets.
            presentation.installationMessages[source.slug] = (error as? RaycastStoreInstaller.Failure)?.errorDescription
                ?? "操作未确认完成，请检查安装服务。"
        }
    }

    var command: LauncherModule.Command {
        .init(declaration: .init(id: .init(rawValue: "keylane-extension-store"), title: "扩展商店",
                                 detail: "Keylane 工具 · 扩展商店", symbol: Self.symbol,
                                 keywords: ["扩展商店", "商店", "Raycast Store", "Extension Store"],
                                 destination: .page(Self.pageID), settingsPage: AppUtilitiesModule.settingsID))
    }

    func page(model: Model) -> LauncherPage {
        let width: CGFloat = 170
        return LauncherPage(
            id: Self.pageID, placeholder: "搜索商店扩展…", badge: ("Store", Self.symbol),
            contentPlacement: .underChrome, content: { AnyView(ExtensionStoreView(store: self)) },
            queryChanged: { self.setQuery($0) },
            back: { [weak model] in
                if self.detail != nil { self.closeDetail() }
                else { model?.pageID = .root }
            },
            move: { self.move($0) }, submit: { self.submit() },
            returnBindings: .init(primary: .plain),
            primaryTitle: { self.detail == nil ? "查看详情" : "查看源码" },
            primaryEnabled: { self.detail != nil || self.selection != nil },
            actions: { self.actions() },
            updates: objectWillChange.eraseToAnyPublisher(),
            enter: { _ in
                if self.pendingPreferencesEntry {
                    self.pendingPreferencesEntry = false
                    return ""
                }
                self.closeDetail()
                self.selected = nil
                self.category = "all"
                self.setQuery("")
                return ""
            },
            typeFilterWidth: width,
            typeFilter: { [weak model] open in
                AnyView(ResultTypeFilter(
                    selection: Binding(get: { self.category }, set: { self.setCategory($0) }),
                    options: self.categories, open: open, navigation: model?.navigation ?? "arrows",
                    width: width, searchPlaceholder: "搜索分类…"))
            }
        )
    }

    @MainActor func restoreInstalled() async {
        guard backendReady, pendingInstallations.isEmpty else { return }
        presentation.launchReady.removeAll()
        do {
            let receipts = try await installer.refreshInstalled()
            guard pendingInstallations.isEmpty, !Task.isCancelled else { return }
            for receipt in receipts where source(receipt.source.slug)?.revision != receipt.source.revision {
                metadata.removeValue(forKey: receipt.source.slug)
                unavailableDetails.remove(receipt.source.slug)
            }
            installed = Dictionary(uniqueKeysWithValues: receipts.map { ($0.source.slug, $0) })
            presentation.inventoryRestored()
            inventoryStatus = nil
            if let detail { await refreshReadiness(detail) }
        } catch {
            inventoryStatus = "无法刷新安装记录；保留上次已确认列表，运行入口暂不可用。"
        }
    }

    @MainActor func refreshReadiness(_ slug: String) async {
        guard let receipt = installed[slug], receipt.enabled else { return }
        var unavailable: [String] = []
        for command in receipt.manifest.commands {
            let key = receipt.id.uuidString + "/" + command.id
            presentation.launchReady.remove(key)
            let state = try? await installer.launchReadiness(slug: slug, commandID: command.id)
            if state == .ready, installed[slug]?.id == receipt.id, installed[slug]?.generation == receipt.generation, installed[slug]?.enabled == true { presentation.launchReady.insert(key) }
            else {
                let reason: String
                switch state {
                case .preferencesRequired: reason = "需要填写配置"
                case .capabilityDenied: reason = "所需能力尚未获准"
                default: reason = "运行服务尚未就绪或无法确认"
                }
                unavailable.append(command.title + "：" + reason)
            }
        }
        if installed[slug]?.id == receipt.id && installed[slug]?.generation == receipt.generation {
            presentation.readinessMessages[slug] = unavailable.isEmpty ? nil : unavailable.joined(separator: "\n")
        }
    }

    private var categories: [ResultFilterOption] {
        let names = Set(metadata.values.flatMap { $0.categories ?? [] })
        return [.init(id: "all", title: "全部分类", symbol: "list.bullet.rectangle"),
                .init(id: "__installed", title: "已安装", symbol: "checkmark.circle")] +
            names.sorted().map { .init(id: $0, title: $0, symbol: "tag") }
    }

    var results: [String] {
        let reviewed = runtimeConfiguration?.runHelperSHA256 == nil ? [] : MacOSReviewedRaycastCommand.entries.map(\.slug)
        let names = category == "__installed" ? installed.keys.sorted()
            : Set((index?.slugs ?? []) + installed.keys + reviewed).sorted()
        return names.filter { slug in
            let info = metadata[slug]
            if category != "all" && category != "__installed", info?.categories?.contains(category) != true { return false }
            guard !query.isEmpty else { return true }
            return ([slug, title(slug)] + [info?.description, info?.author].compactMap { $0 } + (info?.keywords ?? []))
                .contains { $0.localizedStandardContains(query) }
        }
    }

    var selection: String? {
        selection(in: results)
    }

    func selection(in results: [String]) -> String? {
        if let selected, results.contains(selected) { return selected }
        return results.first
    }

    func title(_ slug: String) -> String {
        installed[slug]?.manifest.title ?? metadata[slug]?.title ?? slug.replacingOccurrences(of: "-", with: " ").capitalized
    }

    func source(_ slug: String) -> RaycastStoreSource? {
        if let reviewed = MacOSReviewedRaycastCommand.entry(forSlug: slug), runtimeConfiguration?.runHelperSHA256 != nil, installed[slug] == nil {
            return try? RaycastStoreSource(slug: slug, catalog: .init(revision: reviewed.revision, slugs: [slug]))
        }
        return RaycastStorePresentationState.source(slug: slug, installed: installed[slug]?.source,
                                             detail: detailSource, catalog: index)
    }

    func revision(_ slug: String) -> String {
        source(slug)?.revision ?? ""
    }

    func showDetails(_ slug: String) {
        focusedPreferences = nil
        guard let pinned = source(slug) else { return }
        selected = slug
        detailSource = pinned
        detail = slug
        Task { @MainActor in await self.refreshReadiness(slug) }
    }

    private func move(_ delta: Int) {
        guard detail == nil else { return }
        let results = results
        guard let current = selection(in: results), let offset = results.firstIndex(of: current) else { return }
        selected = results[NavigationBounds.move(offset, by: delta, count: results.count)]
    }

    private func closeDetail() {
        focusedPreferences = nil
        if let pinned = detailSource, pinned.revision != index?.revision { metadata.removeValue(forKey: pinned.slug) }
        detail = nil
        detailSource = nil
        uuidArgument = ""
        typeIDPrefix = ""
    }

    private func setQuery(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != query else { return }
        query = normalized
        selected = nil
        closeDetail()
    }

    private func setCategory(_ value: String) {
        category = value
        selected = nil
        closeDetail()
    }

    private func submit() {
        if let detail { openSource(detail) }
        else if let selection { showDetails(selection) }
    }

    private func openSource(_ slug: String) {
        guard let pinned = source(slug) else { return }
        let base = URL(string: "https://github.com/raycast/extensions/tree")!
        NSWorkspace.shared.open(base.appendingPathComponent(pinned.revision).appendingPathComponent("extensions")
            .appendingPathComponent(slug))
    }

    private func actions() -> [LauncherAction] {
        var actions: [LauncherAction] = []
        if let slug = detail ?? selection {
            if detail == nil {
                actions.append(.init(id: "details", title: "查看详情", icon: "info.circle",
                                     perform: { self.showDetails(slug) }))
            }
            actions += installationActions(slug)
            actions.append(.init(id: "source", title: "查看上游源码", icon: "arrow.up.right.square",
                                 perform: { self.openSource(slug) }))
        }
        actions.append(.init(id: "refresh", title: "刷新目录", icon: "arrow.clockwise", perform: {
            self.loadedDirectory = false
            self.unavailableDetails.removeAll()
            self.refresh += 1
        }))
        return actions
    }

    @MainActor func loadDirectory() async {
        guard !loadedDirectory else { return }
        status = nil
        do {
            let next = try await catalog.loadIndex()
            try Task.checkCancellation()
            if next.revision != index?.revision {
                metadata = metadata.filter { $0.key == detailSource?.slug }
                unavailableDetails.removeAll()
                if category != "__installed" { category = "all" }
            }
            index = next
            loadedDirectory = true
        } catch {
            guard !Task.isCancelled else { return }
            status = index == nil ? "无法读取完整目录，请刷新重试。" : "刷新失败，正在显示上次完整目录。"
        }
    }

    @MainActor func loadDetails(_ slug: String) async {
        let revision = revision(slug)
        guard metadata[slug] == nil, !unavailableDetails.contains(slug) else { return }
        do {
            let info = try await catalog.loadDetails(slug: slug, revision: revision)
            guard !Task.isCancelled, self.revision(slug) == revision, metadata[slug] == nil else { return }
            unavailableDetails.remove(slug)
            metadata[slug] = info
        } catch {
            guard !Task.isCancelled, self.revision(slug) == revision, metadata[slug] == nil else { return }
            unavailableDetails.insert(slug)
        }
    }

    func icon(_ name: String, slug: String, revision: String) async -> NSImage? {
        guard let data = try? await catalog.loadIcon(slug: slug, revision: revision, name: name),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) == "public.png" as CFString,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, (1...2048).contains(width),
              let height = properties[kCGImagePropertyPixelHeight] as? Int, (1...2048).contains(height),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 128
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: thumbnail, size: .zero)
    }
}

private struct ExtensionStoreView: View {
    @ObservedObject var store: ExtensionStoreController
    @State private var confirmsSetup = false

    var body: some View {
        Group {
            if let slug = store.detail { details(slug) }
            else { directory }
        }
        .task(id: store.refresh) { await store.restoreInstalled(); await store.loadDirectory() }
        .alert(store.canReplaceIncompatibleProfile ? "重新配置扩展运行？" : "启用扩展运行？",
               isPresented: $confirmsSetup) {
            Button("取消", role: .cancel) {}
            Button(store.canReplaceIncompatibleProfile ? "创建新配置" : "启用") {
                (NSApp.delegate as? Delegate)?.connectInstalledMacOSExtensions(
                    createIfMissing: true, replaceIncompatibleProfile: store.canReplaceIncompatibleProfile)
            }
        } message: {
            Text(store.canReplaceIncompatibleProfile
                 ? "旧配置和已安装扩展数据会保留。新配置起初为空，需要重新安装要用的扩展。"
                 : "Keylane 将在此 Mac 创建扩展运行配置。安装扩展时会下载并构建所选版本。")
        }
    }

    @ViewBuilder private var runtimeSetup: some View {
        if !store.backendReady {
            if let error = store.configurationError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            if store.configuring {
                ProgressView("正在打开扩展运行配置…")
            } else if store.canConfigure {
                Button(store.canReplaceIncompatibleProfile ? "重新配置扩展运行" : "配置扩展运行",
                       systemImage: "puzzlepiece.extension") { confirmsSetup = true }
            } else {
                Text("此安装包仅提供目录浏览。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var directory: some View {
        let results = store.results
        let selection = store.selection(in: results)
        return SelectableResultList(selection: selection, query: store.query, firstResult: results.first,
                                    revealInitialSelection: true) {
            Text(store.category == "all" ? "全部扩展（名称全量；详情关键词限已读取项目）" : store.category)
                .font(VisualStyle.sectionText).foregroundStyle(.secondary)
                .padding(.horizontal, 9).padding(.top, 8).padding(.bottom, 7)
                .accessibilityAddTraits(.isHeader)
            runtimeSetup.padding(.horizontal, 9)
            if let status = store.inventoryStatus {
                Text(status).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 9)
            }
            if let status = store.status {
                Text(status).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 9).padding(.bottom, 7)
            }
            if store.category != "all" && store.category != "__installed" {
                Text("显示已读取分类的扩展").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 9).padding(.bottom, 7)
            }
            if results.isEmpty {
                Text(store.category == "__installed" ? "暂无匹配的已安装扩展" : (store.results.isEmpty && store.query.isEmpty ? "目录加载中或暂不可用" : "没有匹配的扩展")).foregroundStyle(.secondary).padding(9)
            }
            ForEach(results, id: \.self) { slug in
                row(slug, selected: slug == selection)
            }
        }
    }

    private func row(_ slug: String, selected: Bool) -> some View {
        let info = store.metadata[slug]
        return ResultListButton(id: slug, action: { store.showDetails(slug) }) {
            ResultListRow(selected: selected, height: 58) {
                ExtensionStoreIcon(store: store, slug: slug, name: info?.icon, revision: store.revision(slug))
            } content: {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.title(slug)).font(VisualStyle.rowText.weight(.medium)).lineLimit(1)
                        if let description = info?.description {
                            Text(description).font(VisualStyle.rowText).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if let label = store.installationStatus(slug) ?? info?.author {
                        Label(label, systemImage: info?.supportsMacOS == false ? "exclamationmark.circle" : (store.installationStatus(slug) == nil ? "person.crop.circle" : "checkmark.seal"))
                            .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .task(id: store.revision(slug) + "/\(store.refresh)") { await store.loadDetails(slug) }
    }

    private func details(_ slug: String) -> some View {
        let info = store.metadata[slug]
        return ResultListScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ExtensionStoreIcon(store: store, slug: slug, name: info?.icon, revision: store.revision(slug))
                        .frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.title(slug)).font(.title2.weight(.semibold))
                        if let author = info?.author { Text(author).foregroundStyle(.secondary) }
                    }
                }
                Text(store.installationStatus(slug) ?? "兼容性尚未验证；目录收录不代表已安装或可运行。")
                    .font(.callout).foregroundStyle(.secondary)
                if store.focusedPreferences != nil, let preferences = store.preferencesView(slug) { preferences }
                runtimeSetup
                if let readiness = store.readinessMessages[slug] {
                    Text(readiness).font(.caption).foregroundStyle(.secondary)
                }
                if let reviewed = MacOSReviewedRaycastCommand.entry(forSlug: slug) {
                    if store.isInstalled(slug), let argument = MacOSReviewedRaycastCommand.entries.first(where: { $0.slug == slug && $0.argument != nil })?.argument {
                        TextField(argument == MacOSReviewedRaycastCommand.argument ? "输入 UUID 或 TypeID" : (argument == "text" ? "输入要转换的文本" : "生成数量（可选）"),
                                  text: $store.uuidArgument)
                            .textFieldStyle(.roundedBorder)
                    }
                    if slug == MacOSReviewedRaycastCommand.slug {
                        if store.isInstalled(slug) {
                            TextField("打包 TypeID 时使用的前缀", text: $store.typeIDPrefix)
                                .textFieldStyle(.roundedBorder)
                        }
                        Text("支持格式化 UUID，以及在 UUID 和 TypeID 之间转换。结果将复制到剪贴板。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(store.installationActions(slug)) { action in
                    Button(action.title, systemImage: action.icon, action: action.perform).disabled(!action.enabled)
                }
                if store.focusedPreferences == nil, let preferences = store.preferencesView(slug) { preferences }
                let samples = store.diagnostics(slug)
                if !samples.isEmpty {
                    DisclosureGroup("本机运行诊断") {
                        ForEach(samples.indices, id: \.self) { index in
                            let sample = samples[index]
                            if let category = sample.exceptionCategory {
                                Text("异常类别：\(category.rawValue)")
                            } else if let bytes = sample.peakResidentBytes {
                                let peak = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
                                if let current = sample.residentBytes {
                                    let resident = ByteCountFormatter.string(fromByteCount: Int64(current), countStyle: .memory)
                                    Text("进程常驻内存 \(resident) · 峰值 \(peak)")
                                } else {
                                    Text("进程峰值内存 \(peak)")
                                }
                            }
                        }
                    }.font(.caption)
                }
                if let info {
                    if let description = info.description { Text(description).textSelection(.enabled) }
                    let properties = (info.categories ?? []) + [info.license].compactMap { $0 }
                    if !properties.isEmpty { Text(properties.joined(separator: " · ")).foregroundStyle(.secondary) }
                    if !info.commands.isEmpty {
                        Text("命令").font(.headline)
                        ForEach(info.commands, id: \.name) { command in
                            HStack {
                                Text(command.title)
                                Spacer()
                                Text(command.mode).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else if store.unavailableDetails.contains(slug) {
                    Text("暂时无法读取扩展详情。").foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: store.revision(slug) + "/\(store.refresh)") { await store.loadDetails(slug) }
    }
}

private struct ExtensionStoreIcon: View {
    let store: ExtensionStoreController
    let slug: String
    let name: String?
    let revision: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else {
                Image(systemName: "puzzlepiece.extension.fill")
                    .resizable().scaledToFit().padding(5)
                    .foregroundStyle(.secondary)
                    .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
        .task(id: revision + "/" + (name ?? "")) {
            image = nil
            guard let name else { return }
            let loaded = await store.icon(name, slug: slug, revision: revision)
            if !Task.isCancelled { image = loaded }
        }
    }
}
