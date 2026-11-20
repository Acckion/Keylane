import AppKit
import AVFoundation
import Combine
import KeylaneCore
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
}
