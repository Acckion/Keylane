import CryptoKit
import Foundation

/// Ciphertext stays in the anchored registry transaction. The derived key is
/// held by the host and is available only to a protected macOS build profile.
package struct MacOSReviewedPreferenceVault: Sendable {
    struct Secret: Codable {
        let command: String?
        let name: String
        let value: String

        init(key: RaycastStorePreferenceKey, value: String) {
            if case .command(let command) = key.scope { self.command = command }
            else { command = nil }
            name = key.name
            self.value = value
        }

        var key: RaycastStorePreferenceKey {
            .init(scope: command.map { .command($0) } ?? .extensionWide, name: name)
        }
    }

    private let key: SymmetricKey

    init(profileKey: Data, profileID: UUID) {
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: profileKey),
                                    salt: Data(profileID.uuidString.utf8),
                                    info: Data("org.keylane.extension.preferences.v1".utf8), outputByteCount: 32)
    }

    package func open(_ bytes: Data?, installationID: UUID) throws -> [RaycastStorePreferenceKey: String] {
        guard let bytes else { return [:] }
        guard bytes.count <= 32 * 1024 else { throw RaycastStoreDiskRegistry.Failure.preference }
        let data = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key,
                                    authenticating: Data(installationID.uuidString.utf8))
        let secrets = try JSONDecoder().decode([Secret].self, from: data)
        guard secrets.count <= 32 else { throw RaycastStoreDiskRegistry.Failure.preference }
        var result: [RaycastStorePreferenceKey: String] = [:]
        for value in secrets {
            guard !value.value.isEmpty, value.value.utf8.count <= 1024,
                  result.updateValue(value.value, forKey: value.key) == nil else {
                throw RaycastStoreDiskRegistry.Failure.preference
            }
        }
        return result
    }

    package func seal(_ secrets: [RaycastStorePreferenceKey: String], installationID: UUID) throws -> Data? {
        guard !secrets.isEmpty else { return nil }
        guard secrets.count <= 32 else { throw RaycastStoreDiskRegistry.Failure.preference }
        let data = try JSONEncoder().encode(secrets.map { Secret(key: $0.key, value: $0.value) })
        guard data.count <= 32 * 1024 - 28,
              let result = try AES.GCM.seal(data, using: key,
                  authenticating: Data(installationID.uuidString.utf8)).combined else {
            throw RaycastStoreDiskRegistry.Failure.preference
        }
        return result
    }
}
