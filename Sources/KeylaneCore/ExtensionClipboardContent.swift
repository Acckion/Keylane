import AppKit

/// A reviewed extension result can write one pasteboard item with alternate representations.
public struct ExtensionClipboardContent: Decodable {
    public let text: String?
    public let html: String?
    public let file: String?

    public init(text: String) {
        self.text = text
        html = nil
        file = nil
    }

    public func write(to board: NSPasteboard, concealed: Bool = false) -> Bool {
        guard (text?.utf8.count ?? 0) <= 4_096, (html?.utf8.count ?? 0) <= 4_096 else { return false }
        let item = NSPasteboardItem()
        if let file {
            guard text == nil, html == nil, file.hasPrefix("/"), !file.hasPrefix("//"), file.utf8.count <= 2_048,
                  !file.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
                  !file.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return false }
            let url = URL(fileURLWithPath: file).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path),
                  item.setString(url.absoluteString, forType: .fileURL) else { return false }
        } else {
            guard text != nil || html != nil else { return false }
            if let text, !item.setString(text, forType: .string) { return false }
            if let html, !item.setString(html, forType: .html) { return false }
        }
        if concealed, !item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType")) { return false }
        board.clearContents()
        return board.writeObjects([item])
    }
}
