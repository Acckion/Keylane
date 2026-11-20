import Foundation


/// The modal may reenter the main actor. Reserve the same-slug mutation before
/// showing it and keep the lease through actual dispatch.
@MainActor package enum RaycastStoreInstallConsent {
    package enum Outcome: Equatable { case alreadyPending, cancelled, selectionChanged, dispatched }

    package struct Snapshot {
        package let source: RaycastStoreSource?
        package let metadataSource: RaycastStoreSource?
        package let metadataCompatible: Bool
        package let available: Bool

        package init(source: RaycastStoreSource?, metadataSource: RaycastStoreSource?,
                     metadataCompatible: Bool, available: Bool) {
            self.source = source
            self.metadataSource = metadataSource
            self.metadataCompatible = metadataCompatible
            self.available = available
        }

        fileprivate func allows(_ request: RaycastStoreSource) -> Bool {
            available && metadataCompatible && source == request && source?.sourceURL == request.sourceURL &&
                metadataSource == request && metadataSource?.sourceURL == request.sourceURL
        }
    }

    package static func run(_ request: RaycastStoreSource,
                            reserve: () -> Bool, release: () -> Void,
                            snapshot: () -> Snapshot,
                            prompt: () async -> Bool,
                            dispatch: () async -> Void) async -> Outcome {
        guard reserve() else { return .alreadyPending }
        defer { release() }
        guard snapshot().allows(request) else { return .selectionChanged }
        guard await prompt(), !Task.isCancelled else { return .cancelled }
        guard snapshot().allows(request) else { return .selectionChanged }
        await dispatch()
        return .dispatched
    }
}
