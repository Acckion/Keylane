import AppKit
import Combine
import ImageIO
import KeylaneCore
import SwiftUI

final class ExtensionStoreController: ObservableObject {
    private static let pageID = PageID(rawValue: "ExtensionStore")
    private static let symbol = "storefront"

    private let catalog = RaycastPublicCatalog()
    #if DEBUG
    private let offlineFixture: RaycastStoreAppCapability.OfflineFixture?
    #endif
    @Published private var index: RaycastPublicCatalog.Index?
    @Published private(set) var metadata: [String: RaycastPublicCatalog.Details] = [:]
    @Published private(set) var selected: String?
    @Published private(set) var detail: String?
    private var detailSource: RaycastStoreSource?
    @Published private(set) var query = ""
    @Published private(set) var category = "all"
    @Published private(set) var status: String?
    @Published private(set) var refresh = 0
    @Published private(set) var unavailableDetails: Set<String> = []
    private var loadedDirectory = false
    private var installationObservations: Set<AnyCancellable> = []
    private var installer: RaycastStoreInstaller
    var backendReady: Bool { setupFlow.state == .active }
    @Published private(set) var setupFlow: RaycastStoreSetupFlow
    private let setupProvider: RaycastStoreSetupProvider?
    private var preferencePersistence: (any RaycastStorePreferencePersistence)?
    @Published private var pendingInstallations: Set<String> = []
    @Published private(set) var inventoryStatus: String?
    @Published private var protectedRecovery: RaycastStoreProtectedReceiptState.Recovery?
    @Published private var presentation = RaycastStorePresentationState()
    var readinessMessages: [String: String] { presentation.readinessMessages }
    @Published private var installed: [String: RaycastStoreInstallation] = [:]

    init(capability: RaycastStoreAppCapability? = nil, setup: RaycastStoreSetupProvider? = nil) {
        setupProvider = setup
        setupFlow = .init(active: capability != nil)
        #if DEBUG
        offlineFixture = capability?.offlineFixture
        #endif
        preferencePersistence = capability?.coordinator
        installer = RaycastStoreInstaller(backend: capability?.coordinator)
    }

    @MainActor func refreshSetup() {
        guard !backendReady, let setupProvider else { return }
        let status = setupProvider.status()
        setupFlow.observe(status, fresh: status == .setupRequired ? setupProvider.enrollment.probe() : nil)
    }

    @MainActor func performSetup(_ action: RaycastStoreSetupFlow.Action) async {
        refreshSetup()
        guard let setupProvider, setupFlow.begin(action) else { return }
        switch action {
        case .createEmpty:
            let approval: Data
            do { approval = try await setupProvider.approveEmptyProfile(setupProvider.enrollment.scope) }
            catch {
                setupFlow.rejectCreateBeforeCommit()
                refreshSetup()
                return
            }
            guard setupProvider.status() == .setupRequired,
                  setupProvider.enrollment.probe() == .independentlyVerifiedFresh else {
                setupFlow.finishCreate(.unreadable)
                return
            }
            do {
                try setupProvider.enrollment.enrollNewProfile(approval: approval)
                setupFlow.finishCreate(setupProvider.status())
            } catch {
                // Do not retry after the provider may have committed.
                setupFlow.finishCreate(.protectedWriteIndeterminate)
            }
        case .activate:
            do {
                let scope = setupProvider.enrollment.scope
                let capability = try await setupProvider.openVerified(scope)
                guard capability.enrollmentScope == scope else {
                    setupFlow.finishActivate(false)
                    return
                }
                preferencePersistence = capability.coordinator
                installer = RaycastStoreInstaller(backend: capability.coordinator)
                setupFlow.finishActivate(true)
                await restoreInstalled()
            } catch {
                setupFlow.finishActivate(false)
            }
        }
    }

    func preferencesView(_ slug: String) -> AnyView? {
        guard protectedRecovery == nil, let receipt = installed[slug] else { return nil }
        let manifest = receipt.manifest
        guard !manifest.preferences.isEmpty || manifest.commands.contains(where: { !$0.preferences.isEmpty }) else { return nil }
        guard let persistence = preferencePersistence else {
            return AnyView(Text("扩展包含配置项，但安全偏好存储尚未接入；需要配置的命令不可运行。")
                .font(.caption).foregroundStyle(.secondary))
        }
        let callback = { Task { @MainActor in await self.refreshReadiness(slug) }; return () }
        return AnyView(VStack(alignment: .leading, spacing: 12) {
            if !manifest.preferences.isEmpty {
                if let schema = try? RaycastStorePreferenceSchema(manifest: manifest) {
                    DisclosureGroup("扩展通用配置") {
                        ExtensionStorePreferencesView(installationID: receipt.id, generation: receipt.generation,
                            schema: schema, persistence: persistence, onSaved: callback)
                            .id(receipt.id.uuidString + "/" + String(receipt.generation) + "/global")
                    }
                } else { Text("扩展配置结构无效，无法编辑。") }
            }
            ForEach(manifest.commands.filter { !$0.preferences.isEmpty }, id: \.id) { command in
                if let schema = try? RaycastStorePreferenceSchema(manifest: manifest, commandID: command.id) {
                    DisclosureGroup("配置：" + command.title) {
                        ExtensionStorePreferencesView(installationID: receipt.id, generation: receipt.generation,
                            schema: schema, persistence: persistence, onSaved: callback)
                            .id(receipt.id.uuidString + "/" + String(receipt.generation) + "/" + command.id)
                    }
                } else { Text("命令配置结构无效，无法编辑。") }
            }
        })
    }

    func installationStatus(_ slug: String) -> String? {
        if let message = presentation.installationMessages[slug] { return message }
        if let receipt = installed[slug] { return receipt.enabled ? "已安装并启用" : "已安装，已停用" }
        if metadata[slug]?.supportsMacOS == false { return "此扩展不支持 macOS" }
        return nil
    }

    func installationActions(_ slug: String) -> [LauncherAction] {
        guard let source = source(slug) else { return [] }
        let available = backendReady && protectedRecovery == nil && !pendingInstallations.contains(slug)
        if presentation.needsReconciliation.contains(slug) {
            return [.init(id: "store-reconcile", title: "核对安装记录", icon: "arrow.clockwise", enabled: available) {
                Task { @MainActor in await self.mutate(source, operation: .reconcile) }
            }]
        }
        if let receipt = installed[slug] {
            let commands: [LauncherAction] = receipt.manifest.commands.map { command in
                .init(id: "store-run-" + command.name, title: "运行：" + command.title, icon: "play",
                      enabled: available && receipt.enabled && presentation.launchReady.contains(receipt.id.uuidString + "/" + command.id)) {
                    Task { @MainActor in
                        guard self.protectedRecovery == nil else { return }
                        do { try await self.installer.launch(slug: slug, commandID: command.id) }
                        catch { self.presentation.installationMessages[slug] = (error as? RaycastStoreInstaller.Failure)?.errorDescription ?? "命令未能运行，请检查配置、权限或兼容性。" }
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
        guard protectedRecovery == nil, pendingInstallations.insert(source.slug).inserted else { return }
        defer { pendingInstallations.remove(source.slug) }
        presentation.invalidateReadiness(installationID: installed[source.slug]?.id, slug: source.slug)
        presentation.installationMessages[source.slug] = "正在处理；尚未确认完成…"
        do {
            switch operation {
            case .install: _ = try await installer.prepareAndInstall(source)
            case .toggle(let enabled): try await installer.setEnabled(slug: source.slug, enabled: enabled)
            case .uninstall: try await installer.uninstall(slug: source.slug)
            case .reconcile: try await installer.reconcile(slug: source.slug)
            }
            if case .installed(let receipt) = await installer.state(for: source.slug) { installed[source.slug] = receipt }
            else { installed.removeValue(forKey: source.slug) }
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
        .init(declaration: .init(id: .init(rawValue: "keylane-extension-store"), title: "Store",
                                 detail: "Keylane 工具 · 扩展商店", symbol: Self.symbol,
                                 keywords: ["扩展商店", "商店", "Raycast Store", "Extension Store"],
                                 destination: .page(Self.pageID)))
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
            primaryTitle: { self.detail == nil ? "查看详情" : "查看源码" },
            primaryEnabled: { self.detail != nil || self.selection != nil },
            actions: { self.actions() },
            updates: objectWillChange.eraseToAnyPublisher(),
            enter: { _ in
                self.detail = nil
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
        guard backendReady else { return }
        presentation.launchReady.removeAll()
        do {
            let receipts = try await installer.refreshInstalled()
            for receipt in receipts where source(receipt.source.slug)?.revision != receipt.source.revision {
                metadata.removeValue(forKey: receipt.source.slug)
                unavailableDetails.remove(receipt.source.slug)
            }
            installed = Dictionary(uniqueKeysWithValues: receipts.map { ($0.source.slug, $0) })
            presentation.inventoryRestored()
            protectedRecovery = nil
            inventoryStatus = nil
            if let detail { await refreshReadiness(detail) }
        } catch RaycastStoreDiskRegistry.Failure.protectedStateRecovery(let recovery) {
            protectedRecovery = recovery
            inventoryStatus = recovery.reviewMessage ?? "无法验证安装记录，安装及运行入口暂不可用。"
        } catch {
            if protectedRecovery == nil {
                inventoryStatus = "无法刷新安装记录；保留上次已确认列表，运行入口暂不可用。"
            }
        }
    }

    @MainActor func refreshReadiness(_ slug: String) async {
        guard protectedRecovery == nil, let receipt = installed[slug], receipt.enabled else { return }
        var unavailable: [String] = []
        for command in receipt.manifest.commands {
            let key = receipt.id.uuidString + "/" + command.id
            presentation.launchReady.remove(key)
            let state = try? await installer.launchReadiness(slug: slug, commandID: command.id)
            if state == .ready, protectedRecovery == nil, installed[slug]?.id == receipt.id, installed[slug]?.generation == receipt.generation, installed[slug]?.enabled == true { presentation.launchReady.insert(key) }
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

    func observeInstallation(_ updates: AnyPublisher<Void, Never>) {
        updates.sink { [weak self] in self?.objectWillChange.send() }.store(in: &installationObservations)
    }

    private var categories: [ResultFilterOption] {
        let names = Set(metadata.values.flatMap { $0.categories ?? [] })
        return [.init(id: "all", title: "全部分类", symbol: "list.bullet.rectangle"),
                .init(id: "__installed", title: "已安装", symbol: "checkmark.circle")] +
            names.sorted().map { .init(id: $0, title: $0, symbol: "tag") }
    }

    var results: [String] {
        let names = category == "__installed" ? installed.keys.sorted() : Array(Set((index?.slugs ?? []) + installed.keys)).sorted()
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
        RaycastStorePresentationState.source(slug: slug, installed: installed[slug]?.source,
                                             detail: detailSource, catalog: index)
    }

    func revision(_ slug: String) -> String {
        source(slug)?.revision ?? ""
    }

    func showDetails(_ slug: String) {
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
        if let pinned = detailSource, pinned.revision != index?.revision { metadata.removeValue(forKey: pinned.slug) }
        detail = nil
        detailSource = nil
    }

    private func setQuery(_ value: String) {
        query = value.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private var usesPublicCatalog: Bool {
        #if DEBUG
        return offlineFixture == nil
        #else
        return true
        #endif
    }

    private func openSource(_ slug: String) {
        guard usesPublicCatalog, let pinned = source(slug) else { return }
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
            if usesPublicCatalog {
                actions.append(.init(id: "source", title: "查看上游源码", icon: "arrow.up.right.square",
                                     perform: { self.openSource(slug) }))
            }
        }
        actions.append(.init(id: "refresh", title: "刷新目录", icon: "arrow.clockwise", perform: {
            self.loadedDirectory = false
            self.unavailableDetails.removeAll()
            self.refresh += 1
        }))
        return actions
    }

    private func catalogIndex() async throws -> RaycastPublicCatalog.Index {
        #if DEBUG
        if let offlineFixture { return offlineFixture.index }
        #endif
        return try await catalog.loadIndex()
    }

    private func catalogDetails(_ slug: String, revision: String) async throws -> RaycastPublicCatalog.Details {
        #if DEBUG
        if let offlineFixture { return try offlineFixture.details(slug: slug, revision: revision) }
        #endif
        return try await catalog.loadDetails(slug: slug, revision: revision)
    }

    @MainActor func loadDirectory() async {
        guard !loadedDirectory else { return }
        status = nil
        do {
            let next = try await catalogIndex()
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
            let info = try await catalogDetails(slug, revision: revision)
            guard !Task.isCancelled, self.revision(slug) == revision, metadata[slug] == nil else { return }
            unavailableDetails.remove(slug)
            metadata[slug] = info
        } catch {
            guard !Task.isCancelled, self.revision(slug) == revision, metadata[slug] == nil else { return }
            unavailableDetails.insert(slug)
        }
    }

    func icon(_ name: String, slug: String, revision: String) async -> NSImage? {
        #if DEBUG
        if offlineFixture != nil { return nil }
        #endif
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

    var body: some View {
        Group {
            if let slug = store.detail { details(slug) }
            else { directory }
        }
        .task(id: store.refresh) {
            await store.loadDirectory()
            store.refreshSetup()
            await store.restoreInstalled()
        }
    }

    @ViewBuilder private var setupStatus: some View {
        if !store.backendReady {
            VStack(alignment: .leading, spacing: 5) {
                switch store.setupFlow.state {
                case .browseOnly:
                    Text("商店可浏览。此版本未提供可验证的安装设置。")
                case .fresh:
                    Text("可新建空白扩展配置。这不会恢复旧扩展或旧配置。")
                case .ready:
                    Text("已验证安装配置。启用后才可安装或运行兼容扩展。")
                case .busy:
                    Text("正在核对安装配置。商店仍可浏览。")
                case .review:
                    Text("无法确认安装配置。不会覆盖、重置或恢复旧数据；请先核对原有配置。")
                case .active: EmptyView()
                }
                if let action = store.setupFlow.action {
                    Button(action == .createEmpty ? "新建空白扩展配置" : "启用扩展安装") {
                        Task { await store.performSetup(action) }
                    }
                }
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 9)
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
            setupStatus
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
                if !store.backendReady, case .unavailable(let reason) = RaycastStoreBackendAvailability.current {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                if let readiness = store.readinessMessages[slug] {
                    Text(readiness).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(store.installationActions(slug)) { action in
                    Button(action.title, systemImage: action.icon, action: action.perform).disabled(!action.enabled)
                }
                if let preferences = store.preferencesView(slug) { preferences }
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
