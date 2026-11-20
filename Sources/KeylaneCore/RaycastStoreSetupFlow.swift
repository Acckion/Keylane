import Foundation

/// UI choices are not enrollment evidence. The app-owned provider owns one
/// immutable scope, obtains the opaque approval, and verifies native readiness.
@MainActor
package struct RaycastStoreSetupProvider {
    package let enrollment: RaycastStoreReceiptEnrollment
    package let status: () -> RaycastStoreProtectedReceiptState.Recovery
    package let approveEmptyProfile: (RaycastStoreReceiptEnrollment.Scope) async throws -> Data
    package let openVerified: (RaycastStoreReceiptEnrollment.Scope) async throws -> RaycastStoreAppCapability

    package init(enrollment: RaycastStoreReceiptEnrollment,
                 status: @escaping () -> RaycastStoreProtectedReceiptState.Recovery,
                 approveEmptyProfile: @escaping (RaycastStoreReceiptEnrollment.Scope) async throws -> Data,
                 openVerified: @escaping (RaycastStoreReceiptEnrollment.Scope) async throws -> RaycastStoreAppCapability) {
        self.enrollment = enrollment; self.status = status
        self.approveEmptyProfile = approveEmptyProfile; self.openVerified = openVerified
    }
}

package struct RaycastStoreSetupFlow {
    package enum State: Equatable {
        case browseOnly, fresh, ready, busy, review, active
    }

    package enum Action: Equatable { case createEmpty, activate }
    package private(set) var state: State
    private var pending: Action?
    package init(active: Bool = false) { state = active ? .active : .browseOnly }

    package var action: Action? {
        switch state {
        case .fresh: .createEmpty
        case .ready: .activate
        default: nil
        }
    }

    package mutating func observe(_ status: RaycastStoreProtectedReceiptState.Recovery?,
                                  fresh: RaycastStoreReceiptEnrollment.Observation?) {
        guard state != .review, state != .active, state != .busy else { return }
        switch status {
        case nil: state = .browseOnly
        case .setupRequired where fresh == .independentlyVerifiedFresh: state = .fresh
        case .ready: state = .ready
        default: state = .review
        }
    }

    package mutating func begin(_ requested: Action) -> Bool {
        guard action == requested else { return false }
        state = .busy
        pending = requested
        return true
    }

    package mutating func finishCreate(_ outcome: RaycastStoreProtectedReceiptState.Recovery) {
        guard state == .busy, pending == .createEmpty else { return }
        pending = nil
        // Explicitly separate enrollment from activating the Store backend.
        state = outcome == .ready ? .ready : .review
    }

    package mutating func finishActivate(_ activated: Bool) {
        guard state == .busy, pending == .activate else { return }
        pending = nil
        state = activated ? .active : .review
    }

    package mutating func rejectCreateBeforeCommit() {
        guard state == .busy, pending == .createEmpty else { return }
        pending = nil
        state = .browseOnly
    }
}
