import CryptoKit
import Foundation

/// The only normal-host ingress for installed Store profiles. No environment
/// flags, defaults or fallback assets select authority. Until the app has
/// independently provisioned native inputs it supplies no ingress.
@MainActor package struct RaycastStoreProductIngress {
    package enum Readiness: Equatable {
        case runtimeUnavailable, noVerifiedProfile, authorityReview
        package var message: String {
            switch self {
            case .runtimeUnavailable: "商店可浏览。此版本尚未提供通过验证的扩展运行环境。"
            case .noVerifiedProfile: "商店可浏览。尚未找到已验证并启用的扩展配置。"
            case .authorityReview: "无法验证扩展配置或运行环境。商店保持仅浏览，原有记录不会被更改。"
            }
        }
    }

    package enum Result {
        case blocked(Readiness)
        case ready(RaycastStoreAppCapability)
    }

    private let application: Bundle
    private let team: String
    private let recipe: RaycastStoreArtifactSeal.Recipe
    private let key: P256.Signing.PublicKey
    private let grants: Set<String>
    private let reader: RaycastStoreSelectedProfileReader
    private let openStorage: (RaycastStoreSelectedProfileReader.Capability) throws -> RaycastStoreSerializedReceiptStorage
    private let sign: @Sendable @MainActor (Data) throws -> P256.Signing.ECDSASignature
    private let sink: (StoreGuestRunTicket, String, String) throws -> String

    package init(application: Bundle, team: String, recipe: RaycastStoreArtifactSeal.Recipe,
                 key: P256.Signing.PublicKey, grants: Set<String>, reader: RaycastStoreSelectedProfileReader,
                 openStorage: @escaping (RaycastStoreSelectedProfileReader.Capability) throws -> RaycastStoreSerializedReceiptStorage,
                 sign: @escaping @Sendable @MainActor (Data) throws -> P256.Signing.ECDSASignature,
                 sink: @escaping (StoreGuestRunTicket, String, String) throws -> String) {
        self.application = application
        self.team = team
        self.recipe = recipe
        self.key = key
        self.grants = grants
        self.reader = reader
        self.openStorage = openStorage
        self.sign = sign
        self.sink = sink
    }

    /// Composition for the narrow Store UI capability. Packaged authority may
    /// disallow toast; replacing its presentation sink does not add any grant.
    package func withToastFeedback(_ feedback: @escaping (StoreGuestRunTicket, String) throws -> String) -> Self {
        Self(application: application, team: team, recipe: recipe, key: key,
             grants: grants.intersection(["feedback.toast"]), reader: reader,
             openStorage: openStorage, sign: sign) { ticket, capability, payload in
            guard capability == "feedback.toast" else { throw RaycastStoreToastState.Failure.denied }
            return try feedback(ticket, payload)
        }
    }

    package func open() async -> Result {
        // A synthetic no-SDK recipe is not a qualified public runtime.
        guard !team.isEmpty, !recipe.qualifiedAPIVersions.isEmpty else { return .blocked(.runtimeUnavailable) }
        // The selected reader validates independently pinned signed runtime,
        // owners, locks and receipts; it never creates a missing profile.
        guard let selection = reader.selected() else { return .blocked(.noVerifiedProfile) }
        do {
            let capability = try await RaycastStoreAppCapability.verifySelected(selection, application: application,
                expectedTeam: team, recipe: recipe, storage: openStorage(selection), publicKey: key,
                grants: grants, sign: sign, sink: sink)
            guard capability.enrollmentScope == selection.scope else { return .blocked(.authorityReview) }
            return .ready(capability)
        } catch {
            return .blocked(.authorityReview)
        }
    }
}
