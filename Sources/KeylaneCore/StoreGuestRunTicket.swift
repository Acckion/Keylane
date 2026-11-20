import Foundation
import os


/// App-issued proof for exactly one launch. Guest inputs cannot create one.
/// The underlying broker lease is checked independently of one-time consumption.
public final class StoreGuestRunTicket: Sendable {
    public let id: UUID
    public let profileID: UUID
    public let installation: StoreRuntimeBridge.Installation
    public let receipt: StoreRuntimeBridge.Receipt
    public let commandID: String
    public let capabilities: Set<String>
    public let launchContext: StoreGuestLaunchContext

    private let liveLease: @Sendable () -> Bool
    private let claim = OSAllocatedUnfairLock(initialState: false)

    init(id: UUID, profileID: UUID, installation: StoreRuntimeBridge.Installation, receipt: StoreRuntimeBridge.Receipt,
         commandID: String, capabilities: Set<String>, launchContext: StoreGuestLaunchContext,
         liveLease: @escaping @Sendable () -> Bool) {
        self.id = id; self.profileID = profileID; self.installation = installation; self.receipt = receipt
        self.commandID = commandID; self.capabilities = capabilities; self.launchContext = launchContext
        self.liveLease = liveLease
    }

    /// Both before and just after claiming, check the live lease. Only the
    /// driver consumes; the broker also checks the live lease on every effect.
    @discardableResult public func consumeForStart() -> Bool {
        guard liveLease() else { return false }
        let acquired = claim.withLock { used in
            guard !used else { return false }
            used = true
            return true
        }
        return acquired && liveLease()
    }

    public func allowsEffect(_ capability: String) -> Bool {
        claim.withLock { $0 } && capabilities.contains(capability) && liveLease()
    }

    public func isCurrent() -> Bool { liveLease() }
}
