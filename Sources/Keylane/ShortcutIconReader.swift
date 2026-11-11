import AppKit
import Carbon
import ImageIO

/// Reads the icon property exposed by Shortcuts' scripting dictionary.
enum ShortcutIconReader {
    static let bundleIdentifier = "com.apple.shortcuts"

    static func permission(prompt: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, code("core"), code("getd"), prompt)
    }

    static func image(id: String) throws -> CGImage? {
        guard UUID(uuidString: id) != nil else { return nil }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        let shortcut = specifier(class: "srct", form: "ID  ", key: NSAppleEventDescriptor(string: id),
                                 container: .null())
        let icon = specifier(class: "prop", form: "prop", key: .init(typeCode: code("sico")),
                             container: shortcut)
        let event = NSAppleEventDescriptor(eventClass: code("core"), eventID: code("getd"),
                                           targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(icon, forKeyword: code("----"))
        let reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 3)
        if let error = reply.paramDescriptor(forKeyword: code("errn")), error.int32Value != 0 {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(error.int32Value))
        }
        guard let iconData = reply.paramDescriptor(forKeyword: code("----"))?.data else { return nil }
        return decode(iconData)
    }

    static func decode(_ data: Data) -> CGImage? {
        guard data.count <= 4 * 1024 * 1024,
              let image = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(image, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 96
        ] as CFDictionary)
    }

    private static func specifier(class desiredClass: String, form: String, key: NSAppleEventDescriptor,
                                  container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(.init(typeCode: code(desiredClass)), forKeyword: code("want"))
        record.setDescriptor(.init(enumCode: code(form)), forKeyword: code("form"))
        record.setDescriptor(key, forKeyword: code("seld"))
        record.setDescriptor(container, forKeyword: code("from"))
        return record.coerce(toDescriptorType: code("obj ")) ?? record
    }

    private static func code(_ value: String) -> OSType {
        value.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }
}
