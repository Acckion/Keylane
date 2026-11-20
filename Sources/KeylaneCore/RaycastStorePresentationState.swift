import Foundation

/// Value state used by the Store controller. Keeping these transitions together
/// prevents one extension's operation from invalidating unrelated command rows.
public struct RaycastStorePresentationState: Sendable {
    public var launchReady: Set<String> = []
    public var installationMessages: [String: String] = [:]
    public var needsReconciliation: Set<String> = []
    public var readinessMessages: [String: String] = [:]
    public init() {}

    public mutating func invalidateReadiness(installationID: UUID?, slug: String) {
        if let installationID {
            let prefix = installationID.uuidString + "/"
            launchReady = launchReady.filter { !$0.hasPrefix(prefix) }
        }
        readinessMessages.removeValue(forKey: slug)
    }

    /// Call only after an authoritative inventory read succeeds. Errors must leave
    /// reconciliation feedback intact so a failed read is never presented as repair.
    public mutating func inventoryRestored() {
        launchReady.removeAll()
        installationMessages.removeAll()
        needsReconciliation.removeAll()
        readinessMessages.removeAll()
    }

    public static func source(slug: String, installed: RaycastStoreSource?,
                              detail: RaycastStoreSource?, catalog: RaycastPublicCatalog.Index?) -> RaycastStoreSource? {
        // Installed provenance must never silently advance with the public catalog.
        if let installed, installed.slug == slug { return installed }
        if let detail, detail.slug == slug { return detail }
        guard let catalog else { return nil }
        return try? RaycastStoreSource(slug: slug, catalog: catalog)
    }
}
