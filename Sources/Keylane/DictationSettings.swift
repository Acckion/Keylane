import AppKit
import AVFoundation
import Combine
import KeylaneCore
import Security
import SwiftUI

final class DictationSettings: ObservableObject {
    @Published var options: DictationOptions {
        didSet { if let data = try? JSONEncoder().encode(options) { defaults.set(data, forKey: Self.key) } }
    }
    let permission: PermissionFeature
    private let defaults: UserDefaults
    private static let key = "dictation.options.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        options = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(DictationOptions.self, from: $0) } ?? .init()
        permission = PermissionFeature("dictation.enabled", authorization: .init(check: {
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }, request: { complete in
            AVCaptureDevice.requestAccess(for: .audio) { granted in DispatchQueue.main.async { complete(granted) } }
        }, guidance: "请在系统设置中允许 Keylane 使用麦克风。", privacyPane: "Microphone"), defaults: defaults, observeImmediately: false)
    }
    func binding<Value>(_ path: WritableKeyPath<DictationOptions, Value>) -> Binding<Value> {
        Binding(get: { self.options[keyPath: path] }, set: { self.options[keyPath: path] = $0 })
    }
    func chooseProvider(_ provider: DictationCloudProvider) {
        guard options.provider != provider else { return }
        options.provider = provider
        switch provider {
        case .openAI: options.endpoint = "https://api.openai.com/v1"; options.model = "gpt-transcribe"
        case .elevenLabs: options.endpoint = "https://api.elevenlabs.io/v1"; options.model = "scribe_v2"
        case .compatible: options.endpoint = ""; options.model = ""
        }
    }
}

enum DictationCredentials {
    private static func query(_ options: DictationOptions) throws -> [String: Any] {
        guard let account = options.credentialAccount else { throw DictationError.configuration }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.keylane.dictation",
                kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    static func read(_ options: DictationOptions) throws -> String? {
        var query = try query(options)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw AIConfiguration.CredentialError.unavailable }
        return value
    }
    static func save(_ value: String, options: DictationOptions) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 8192, value.rangeOfCharacter(from: .controlCharacters) == nil else { throw DictationError.missingKey }
        var query = try query(options)
        let attributes = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = Data(value.utf8)
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AIConfiguration.CredentialError.unavailable }
    }
    static func remove(_ options: DictationOptions) throws {
        let status = SecItemDelete(try query(options) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AIConfiguration.CredentialError.unavailable }
    }
}
