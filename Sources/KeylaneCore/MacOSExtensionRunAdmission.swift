import Foundation
import os

/// The driver owns one isolated process and returns only after it has exited,
/// including on cancellation. It consumes the ticket before starting the process.
package protocol MacOSExtensionNoViewDriver: Sendable {
    func run(bytes: Data, ticket: StoreGuestRunTicket) async throws
}

/// M2 admission for a single host. The composition root must give registry
/// mutations and the dispatcher this same instance.
package final class MacOSExtensionRunAdmission: Sendable {
    package enum Failure: Error, Equatable { case busy, retired, unsupportedCommand, preferencesRequired }

    private final class Lease: Sendable {
        let current = OSAllocatedUnfairLock(initialState: true)
        func retire() { current.withLock { $0 = false } }
    }

    private struct Run: Sendable {
        let ticket: StoreGuestRunTicket
        let lease: Lease
        let task: Task<Void, Error>

        func wait() async throws {
            try await withTaskCancellationHandler {
                try await task.value
                try Task.checkCancellation()
            } onCancel: {
                lease.retire()
                task.cancel()
            }
        }
    }

    private struct Active: Sendable {
        let installationID: UUID
        let generation: UInt64
        let lease: Lease
        let run: Run
    }

    private let active = OSAllocatedUnfairLock<Active?>(initialState: nil)

    /// Revalidates the anchored registry snapshot and opens the sealed command
    /// before admitting work. Admission is serialized with registry quarantine.
    package func start(_ context: RaycastStoreInstallCoordinator.RunContext,
                       profileID: UUID, seal: RaycastStoreArtifactSeal,
                       driver: any MacOSExtensionNoViewDriver) async throws {
        try Task.checkCancellation()
        let run = try await context.registry.withCurrentRun(context) { installation, trusted, snapshot in
            try Task.checkCancellation()
            guard Self.supports(commandID: context.commandID, trusted: trusted) else { throw Failure.unsupportedCommand }
            let launchContext = try Self.launchContext(commandID: context.commandID, trusted: trusted, snapshot: snapshot, arguments: context.arguments)
            let artifact = try seal.open(context.artifact, installation: installation, commandID: context.commandID)
            return try self.admit(profileID: profileID, installationID: installation.id,
                                  generation: installation.generation, commandID: context.commandID,
                                  receipt: artifact.receipt, capabilities: trusted.requiredCapabilities,
                                  launchContext: launchContext) { ticket in
                try await driver.run(bytes: artifact.bytes, ticket: ticket)
            }
        }
        try await run.wait()
    }

    static func supports(commandID: String, trusted: RaycastStoreTrustedDescription) -> Bool {
        guard let command = trusted.manifest.commands.first(where: { $0.id == commandID }) else { return false }
        return supports(command: command, manifest: trusted.manifest, capabilities: trusted.requiredCapabilities)
    }

    static func supports(command: RaycastExtensionManifest.Command, manifest: RaycastExtensionManifest,
                         capabilities: Set<String>) -> Bool {
        guard command.mode == .noView, command.arguments.isEmpty || MacOSReviewedRaycastCommand.entry(forCommandID: command.id)?.argument != nil,
              command.backgroundIntervalSeconds == nil,
              !command.disabledByDefault, capabilities.isSubset(of: MacOSNoViewCapabilities.supported),
              let schema = try? RaycastStorePreferenceSchema(manifest: manifest, commandID: command.id) else { return false }
        return schema.entries.isEmpty || (capabilities.contains(MacOSNoViewCapabilities.preferences)
            && schema.entries.allSatisfy { ["checkbox", "dropdown", "textfield"].contains($0.field.type) })
    }

    static func launchContext(commandID: String, trusted: RaycastStoreTrustedDescription,
                              snapshot: RaycastStorePreferenceSnapshot, arguments: [String: String]? = nil) throws -> StoreGuestLaunchContext {
        let valuesToSend = arguments ?? [:]
        if let arguments {
            if let entry = MacOSReviewedRaycastCommand.entry(forCommandID: commandID), !entry.argumentNames.isEmpty {
                let validValues = Set(arguments.keys) == Set(entry.argumentNames) && arguments.values.allSatisfy {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 256
                }
                guard (entry.argumentIsOptional && arguments.isEmpty) || validValues else {
                    throw Failure.unsupportedCommand
                }
            } else if !arguments.isEmpty {
                throw Failure.unsupportedCommand
            }
        }
        let schema = try RaycastStorePreferenceSchema(manifest: trusted.manifest, commandID: commandID)
        if schema.entries.isEmpty { return .init(arguments: valuesToSend) }
        var values: [String: StoreGuestLaunchContext.OrdinaryPreference] = [:]
        for entry in schema.entries {
            values.removeValue(forKey: entry.id.name)
            guard let value = schema.value(for: entry, snapshot: snapshot), entry.field.accepts(value) else {
                if entry.field.required == true { throw Failure.preferencesRequired }
                continue
            }
            switch value {
            case .string(let text): values[entry.id.name] = .text(text)
            case .bool(let toggle): values[entry.id.name] = .toggle(toggle)
            case .application: throw Failure.unsupportedCommand
            }
        }
        let context = StoreGuestLaunchContext(arguments: valuesToSend, ordinaryPreferences: values)
        _ = try context.preferencesReply()
        return context
    }

    private func admit(profileID: UUID, installationID: UUID, generation: UInt64, commandID: String,
               receipt: StoreRuntimeBridge.Receipt, capabilities: Set<String>, launchContext: StoreGuestLaunchContext,
               operation: @escaping @Sendable (StoreGuestRunTicket) async throws -> Void) throws -> Run {
        try active.withLock { slot in
            guard slot == nil else { throw Failure.busy }
            let lease = Lease()
            let ticket = StoreGuestRunTicket(
                id: UUID(), profileID: profileID, installation: .init(id: installationID.uuidString, generation: generation),
                receipt: receipt, commandID: commandID, capabilities: capabilities, launchContext: launchContext,
                macOSLease: lease.current,
                liveLease: { lease.current.withLock { $0 } }
            )
            let task = Task {
                defer {
                    lease.retire()
                    self.active.withLock { slot in
                        if slot?.run.ticket.id == ticket.id { slot = nil }
                    }
                }
                try Task.checkCancellation()
                guard ticket.isCurrent() else { throw Failure.retired }
                try await withTaskCancellationHandler {
                    try await operation(ticket)
                } onCancel: {
                    lease.retire()
                }
                try Task.checkCancellation()
                guard ticket.isCurrent() else { throw Failure.retired }
            }
            let run = Run(ticket: ticket, lease: lease, task: task)
            slot = .init(installationID: installationID, generation: generation, lease: lease, run: run)
            return run
        }
    }

    package func quarantine(installationID: UUID, before generation: UInt64) {
        retire(installationID: installationID, before: generation)?.cancel()
    }

    package func revoke(installationID: UUID, before generation: UInt64) async {
        guard let task = retire(installationID: installationID, before: generation) else { return }
        task.cancel()
        _ = await task.result
    }

    private func retire(installationID: UUID, before generation: UInt64) -> Task<Void, Error>? {
        active.withLock { slot in
            guard let slot, slot.installationID == installationID, slot.generation < generation else { return nil }
            slot.lease.retire()
            return slot.run.task
        }
    }
}
