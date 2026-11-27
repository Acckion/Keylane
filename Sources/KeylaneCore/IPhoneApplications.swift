import Foundation

public struct IPhoneApplication: Equatable, Identifiable {
    public let bundleID: String
    public let name: String
    public var id: String { "iphone:" + bundleID }
    public init(bundleID: String, name: String) { self.bundleID = bundleID; self.name = name }
    public static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value.contains(".") &&
        value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) } &&
        value.first != "-"
    }
}

/// Only reads metadata; placeholder bundles are never executed or handed to NSWorkspace.
public enum IPhoneApplicationCatalog {
    public static func scan(library: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")) -> [IPhoneApplication] {
        let fm = FileManager.default
        var found: [String: IPhoneApplication] = [:]
        for directory in ["Daemon Containers", "Containers"] {
            let root = library.appendingPathComponent(directory)
            for container in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                guard let metadata = plist(container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")),
                      metadata["MCMMetadataIdentifier"] as? String == "com.apple.appplaceholdersyncd" else { continue }
                for relative in ["Data/Library/Caches", "Library/Caches"] {
                    let caches = container.appendingPathComponent(relative)
                    for cache in ((try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.path < $1.path })
                        where cache.lastPathComponent.hasPrefix("Placeholders") && cache.pathExtension == "noindex" {
                        guard let enumerator = fm.enumerator(at: cache, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
                        while let url = enumerator.nextObject() as? URL {
                            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { enumerator.skipDescendants(); continue }
                            guard url.pathExtension == "app" else { continue }
                            enumerator.skipDescendants()
                            guard let info = plist(url.appendingPathComponent("Contents/Info.plist")) ?? plist(url.appendingPathComponent("Info.plist")),
                                  let payload = info["NSiPhoneMirroringLaunchPayload"] as? Data,
                                  let bundleID = bundleID(payload) else { continue }
                            let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent
                            found[bundleID] = IPhoneApplication(bundleID: bundleID, name: name)
                        }
                    }
                }
            }
        }
        return found.values.sorted { $0.name == $1.name ? $0.bundleID < $1.bundleID : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func bundleID(_ payload: Data) -> String? {
        // Secure class allowlist; never instantiate arbitrary classes from the system cache.
        guard payload.count <= 65_536,
              let value = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSDictionary.self, NSString.self], from: payload) as? [String: String],
              let id = value["bundleID"], IPhoneApplication.validIdentifier(id) else { return nil }
        return id
    }

    private static func plist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), data.count <= 1_048_576 else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}

public struct IPhoneDevice: Equatable, Identifiable {
    public let id: String
    public let name: String
    public let available: Bool
    public static func parse(_ data: Data) throws -> [IPhoneDevice] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = root["info"] as? [String: Any], info["outcome"] as? String == "success",
              let result = root["result"] as? [String: Any], let devices = result["devices"] as? [[String: Any]] else { throw IPhoneLaunchError.invalidResponse }
        return devices.compactMap { device in
            let properties = device["properties"] as? [String: Any] ?? [:]
            let hardware = properties["hardware"] as? [String: Any] ?? device["hardwareProperties"] as? [String: Any] ?? [:]
            let connection = properties["connection"] as? [String: Any] ?? device["connectionProperties"] as? [String: Any] ?? [:]
            let state = properties["state"] as? [String: Any] ?? device["deviceProperties"] as? [String: Any] ?? [:]
            guard hardware["deviceType"] as? String == "iPhone", hardware["reality"] as? String == "physical",
                  connection["pairingState"] as? String == "paired", let id = device["identifier"] as? String, UUID(uuidString: id) != nil else { return nil }
            let status = connection["state"] as? String ?? connection["tunnelState"] as? String
            return IPhoneDevice(id: id, name: state["name"] as? String ?? "iPhone", available: status == "connected")
        }.sorted { $0.id < $1.id }
    }
    public static func select(_ devices: [IPhoneDevice], preferred: String) throws -> IPhoneDevice {
        if !preferred.isEmpty {
            guard let device = devices.first(where: { $0.id == preferred }) else { throw IPhoneLaunchError.missingDevice }
            return device
        }
        guard devices.count == 1 else { throw devices.isEmpty ? IPhoneLaunchError.missingDevice : IPhoneLaunchError.ambiguousDevice }
        return devices[0]
    }
}

public enum IPhoneLaunchError: LocalizedError, Equatable {
    case invalidResponse, missingDevice, ambiguousDevice, timeout, unavailable, failed
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "无法解析 Xcode 设备信息。请确认当前 Xcode 支持此设备。"
        case .missingDevice: return "未找到所选的已配对 iPhone。请连接设备并刷新，或重新选择设备。"
        case .ambiguousDevice: return "有多台已配对 iPhone，请先在应用程序设置中选择启动目标。"
        case .timeout: return "iPhone 请求超时。请检查设备连接和 iPhone 镜像后重试。"
        case .unavailable: return "iPhone 当前不可用。请先连接设备；如手机已锁定，请手动连接 iPhone 镜像。"
        case .failed: return "无法启动 iPhone 应用。请检查 Xcode、配对、开发者模式与设备锁定状态，确认目标手机已安装此应用；锁定时请先手动连接 iPhone 镜像。"
        }
    }
}
