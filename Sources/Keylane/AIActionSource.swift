import Foundation
import KeylaneCore

/// A module owns the resolver and its source-version check. No business switch in the AI host.
struct AIActionSource {
    let moduleID: ModuleID
    let load: () async throws -> AIActionContext
    let isCurrent: (AIActionContext) async throws -> Bool
}

