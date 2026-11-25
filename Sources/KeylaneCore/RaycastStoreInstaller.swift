import Foundation

/// Serializes mutations for each catalogue identity. The backend owns the durable
/// transaction and session revocation. This actor never calls a host shell and never
/// treats a prepared artifact as an installed extension.
public actor RaycastStoreInstaller {
    public enum Failure: String, Error, LocalizedError, Sendable {
        case unavailable, busy, preparationFailed, buildFailed, unsupportedBuild, noRunnableCommands, invalidArtifact, cancelled, existingDifferentRevision, reconciliationFailed
        case installationOutcomeUnknown, invalidReceipt, notInstalled, operationOutcomeUnknown, preferencesRequired, launchBlocked
        public var errorDescription: String? {
            switch self {
            case .preferencesRequired: return "请先填写此命令所需的扩展配置。"
            case .launchBlocked: return "运行环境或所需能力尚未就绪，命令未执行。"
            case .existingDifferentRevision: return "此扩展已安装其他版本；请先核对现有安装，不能将安装操作当作无提示更新。"
            case .reconciliationFailed: return "无法读取现有安装记录；为避免重复安装，已停止操作。"
            case .unavailable: return "隔离安装服务尚未接入；尚未安装扩展。"
            case .busy: return "此扩展已有操作正在进行，请等待完成。"
            case .noRunnableCommands: return "此扩展没有当前预览版可运行的命令，尚未安装。"
            case .unsupportedBuild: return "当前隔离运行环境不支持此扩展的平台、依赖或接口版本；仍可在商店中浏览。"
            case .buildFailed: return "隔离编译未生成有效制品，未进入安装步骤。请检查扩展的依赖与 API 导入。"
            case .preparationFailed: return "源码获取、依赖准备或隔离构建失败；未进入安装步骤。"
            case .invalidArtifact: return "构建制品与所选来源或完整性摘要不匹配；已阻止安装。"
            case .cancelled: return "准备已取消；未进入安装步骤。"
            case .installationOutcomeUnknown: return "安装结果尚未确认；请先核对安装记录，不要重复安装。"
            case .invalidReceipt: return "安装回执与所选扩展不匹配；需要核对安装记录。"
            case .notInstalled: return "没有可验证的已安装记录。"
            case .operationOutcomeUnknown: return "操作结果尚未确认；需要重新读取安装记录。"
            }
        }
    }
    public enum State: Sendable {
        case idle, preparing, installing
        case installed(RaycastStoreInstallation)
        case failed(Failure)
    }

    private let backend: (any RaycastStoreBackend)?
    private var states: [String: State] = [:]
    private var active: Set<String> = []
    private var refreshingInventory = false
    private var installations: [String: RaycastStoreInstallation] = [:]
    /// Ambiguous mutations require authoritative reconciliation, not blind retries.
    private var unresolved: Set<String> = []

    public init(backend: (any RaycastStoreBackend)? = nil) { self.backend = backend }
    public func state(for slug: String) -> State { states[slug] ?? .idle }

    public func installedList() -> [RaycastStoreInstallation] {
        installations.values.sorted { $0.source.slug < $1.source.slug }
    }

    public func refreshInstalled() async throws -> [RaycastStoreInstallation] {
        guard !refreshingInventory, active.isEmpty else { throw Failure.busy }
        guard let backend else { throw Failure.unavailable }
        refreshingInventory = true
        defer { refreshingInventory = false }
        let records: [RaycastStoreInstallation]
        do { records = try await backend.installations() }
        catch RaycastStoreDiskRegistry.Failure.protectedStateRecovery(let recovery) {
            throw RaycastStoreDiskRegistry.Failure.protectedStateRecovery(recovery)
        }
        catch { throw Failure.reconciliationFailed }
        guard records.count <= 10_000, Set(records.map(\.id)).count == records.count,
              Set(records.map { $0.source.slug }).count == records.count else { throw Failure.invalidReceipt }
        // Replace only after a complete successful read. A network/storage error
        // must never erase the last visible confirmed inventory.
        installations = Dictionary(uniqueKeysWithValues: records.map { ($0.source.slug, $0) })
        states = Dictionary(uniqueKeysWithValues: records.map { ($0.source.slug, .installed($0)) })
        unresolved.removeAll()
        return installedList()
    }

    public func launchReadiness(slug: String, commandID: String) async throws -> RaycastStoreLaunchReadiness {
        guard let backend, let installed = installations[slug], installed.enabled,
              !refreshingInventory, !active.contains(slug), !unresolved.contains(slug),
              installed.manifest.commands.contains(where: { $0.id == commandID }) else { return .runtimeUnavailable }
        return try await backend.launchReadiness(installationID: installed.id, commandID: commandID)
    }

    public func prepareAndInstall(_ source: RaycastStoreSource) async throws -> RaycastStoreInstallation {
        try await prepareAndCommit(source, replacing: nil)
    }
    /// Called after explicit update confirmation for this exact current receipt.
    public func prepareAndUpdate(_ source: RaycastStoreSource, replacing expected: RaycastStoreInstallation) async throws -> RaycastStoreInstallation {
        try await prepareAndCommit(source, replacing: expected)
    }
    private func prepareAndCommit(_ source: RaycastStoreSource, replacing expected: RaycastStoreInstallation?) async throws -> RaycastStoreInstallation {
        guard !refreshingInventory, !active.contains(source.slug) else { throw Failure.busy }
        guard !unresolved.contains(source.slug) else { throw Failure.installationOutcomeUnknown }
        guard let backend else { states[source.slug] = .failed(.unavailable); throw Failure.unavailable }
        active.insert(source.slug)
        defer { active.remove(source.slug) }
        let existing: RaycastStoreInstallation?
        do { existing = try await backend.installation(for: source.slug) }
        catch { states[source.slug] = .failed(.reconciliationFailed); throw Failure.reconciliationFailed }
        if let existing {
            guard existing.source.slug == source.slug else {
                unresolved.insert(source.slug)
                states[source.slug] = .failed(.invalidReceipt)
                throw Failure.invalidReceipt
            }
            installations[source.slug] = existing
            states[source.slug] = .installed(existing)
            if let expected {
                guard existing.id == expected.id, existing.source == expected.source,
                      existing.generation == expected.generation, existing.enabled == expected.enabled,
                      existing.pendingOperation == expected.pendingOperation else { throw Failure.invalidReceipt }
                if existing.source == source { return existing }
            } else {
                guard existing.source == source else { throw Failure.existingDifferentRevision }; return existing
            }
        } else if expected != nil {
            throw Failure.notInstalled
        }
        states[source.slug] = .preparing
        let artifact: RaycastStorePreparedArtifact
        do {
            try Task.checkCancellation()
            if let expected { artifact = try await backend.prepareUpdate(source, replacing: expected) }
            else { artifact = try await backend.prepare(source) }
            try Task.checkCancellation()
        } catch RaycastStoreDiskRegistry.Failure.protectedStateRecovery(.protectedWriteIndeterminate) {
            markUnresolved(source.slug)
            throw Failure.operationOutcomeUnknown
        } catch {
            let failure: Failure
            switch error {
            case is CancellationError: failure = .cancelled
            case Failure.buildFailed: failure = .buildFailed
            case Failure.noRunnableCommands: failure = .noRunnableCommands
            case RaycastStoreSourcePackage.Failure.unsupportedPlatform,
                 RaycastStoreBuildDependencies.Failure.unsupportedRuntimeAPI,
                 RaycastStoreBuildDependencies.Failure.unsupportedPackage: failure = .unsupportedBuild
            default: failure = .preparationFailed
            }
            states[source.slug] = .failed(failure)
            throw failure
        }
        guard artifact.source == source, artifact.contentDigest.utf8.count == 64,
              artifact.contentDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            states[source.slug] = .failed(.invalidArtifact)
            throw Failure.invalidArtifact
        }
        states[source.slug] = .installing
        let installed: RaycastStoreInstallation
        do { installed = try await backend.install(artifact) }
        catch {
            unresolved.insert(source.slug)
            states[source.slug] = .failed(.installationOutcomeUnknown)
            throw Failure.installationOutcomeUnknown
        }
        // Once a commit receipt is returned, cancellation must not hide the fact that
        // the backend installed something. Never change this to checkCancellation().
        guard installed.source == source,
              expected == nil || (installed.id == expected!.id && (installed.generation > expected!.generation || (expected!.pendingOperation && installed.generation == expected!.generation))) else {
            unresolved.insert(source.slug)
            states[source.slug] = .failed(.invalidReceipt)
            throw Failure.invalidReceipt
        }
        installations[source.slug] = installed
        states[source.slug] = .installed(installed)
        return installed
    }

    public func launch(slug: String, commandID: String) async throws {
        guard let backend, let installed = installations[slug], installed.enabled,
              !refreshingInventory, !active.contains(slug), !unresolved.contains(slug),
              installed.manifest.commands.contains(where: { $0.id == commandID }) else { throw Failure.notInstalled }
        let readiness = try await backend.launchReadiness(installationID: installed.id, commandID: commandID)
        guard readiness == .ready else {
            throw readiness == .preferencesRequired ? Failure.preferencesRequired : Failure.launchBlocked
        }
        try await backend.launch(installationID: installed.id, commandID: commandID)
    }

    public func setEnabled(slug: String, enabled: Bool) async throws {
        let (backend, installed) = try beginMutation(slug)
        defer { active.remove(slug) }
        let updated: RaycastStoreInstallation
        do { updated = try await backend.setEnabled(installationID: installed.id, enabled: enabled) }
        catch { markUnresolved(slug); throw Failure.operationOutcomeUnknown }
        guard updated.id == installed.id, updated.source == installed.source, updated.enabled == enabled,
              updated.generation >= installed.generation else {
            markUnresolved(slug); throw Failure.invalidReceipt
        }
        installations[slug] = updated
        states[slug] = .installed(updated)
    }

    public func uninstall(slug: String) async throws {
        let (backend, installed) = try beginMutation(slug)
        defer { active.remove(slug) }
        do { try await backend.uninstall(installationID: installed.id) }
        catch { markUnresolved(slug); throw Failure.operationOutcomeUnknown }
        installations.removeValue(forKey: slug)
        states[slug] = .idle
    }

    public func reconcile(slug: String) async throws {
        guard !refreshingInventory, !active.contains(slug) else { throw Failure.busy }
        guard let backend else { throw Failure.unavailable }
        active.insert(slug)
        defer { active.remove(slug) }
        try await backend.recoverInterruptedMutation()
        let receipt = try await backend.installation(for: slug)
        guard receipt == nil || receipt?.source.slug == slug else { throw Failure.invalidReceipt }
        installations[slug] = receipt
        unresolved.remove(slug)
        states[slug] = receipt.map(State.installed) ?? .idle
    }

    private func beginMutation(_ slug: String) throws -> (any RaycastStoreBackend, RaycastStoreInstallation) {
        guard !refreshingInventory, !active.contains(slug) else { throw Failure.busy }
        guard !unresolved.contains(slug) else { throw Failure.operationOutcomeUnknown }
        guard let backend, let installed = installations[slug] else { throw Failure.notInstalled }
        active.insert(slug)
        return (backend, installed)
    }

    private func markUnresolved(_ slug: String) {
        unresolved.insert(slug)
        states[slug] = .failed(.operationOutcomeUnknown)
    }
}
