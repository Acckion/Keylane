import AppKit
import ImageIO
import KeylaneCore

struct ClipboardCapture {
    static let imageFormats: [(String,ClipImageFormat)] = [("com.compuserve.gif",.gif),("public.png",.png),("public.jpeg",.jpg),("public.heic",.heic),("org.webmproject.webp",.webp),("public.tiff",.tiff)]
    static func string(_ data: Data, type: String) -> String? {
        String(data:data,encoding:type == "public.utf16-plain-text" ? .utf16 : .utf8)?.trimmingCharacters(in:CharacterSet(charactersIn:"\0"))
    }
    static func plainText(_ item: ClipSnapshotItem) -> String {
        for type in ["public.utf8-plain-text","public.utf16-plain-text","public.url"] {
            if let value = item.representations.first(where: { $0.type == type }), let text = string(value.data,type:type) { return text }
        }
        if let rtf = item.representations.first(where: { $0.type == "public.rtf" }), rtf.data.count <= 2 * 1024 * 1024,
           let value = try? NSAttributedString(data:rtf.data,options:[.documentType:NSAttributedString.DocumentType.rtf],documentAttributes:nil) { return value.string }
        if let html = item.representations.first(where: { $0.type == "public.html" }), let value = String(data:html.data,encoding:.utf8) {
            // Never use the HTML importer/WebKit for history previews: it may fetch
            // external resources. Only derive a bounded, inert text projection.
            var text = String(value.prefix(1_048_576)).replacingOccurrences(of:"(?is)<(script|style)\\b[^>]*>.*?</\\1\\s*>",with:"",options:.regularExpression)
            text = text.replacingOccurrences(of:"(?i)<(?:br\\s*/?|/p|/div|/li)\\s*>",with:"\n",options:.regularExpression).replacingOccurrences(of:"<[^>]+>",with:"",options:.regularExpression)
            for (entity,replacement) in [("&nbsp;"," "),("&lt;","<"),("&gt;",">"),("&quot;","\""),("&#39;","'"),("&amp;","&")] { text = text.replacingOccurrences(of:entity,with:replacement) }
            return text.trimmingCharacters(in:.whitespacesAndNewlines)
        }
        return ""
    }
    static func decode(_ items: [ClipSnapshotItem], fileReferences: [ClipFile]? = nil) throws -> (ClipContent,ClipSnapshot) {
        let text = items.map(plainText).filter { !$0.isEmpty }.joined(separator:"\n")
        let snapshot = ClipSnapshot(items:items,plainText:String(text.prefix(1_048_576)))
        _ = try snapshot.encoded()
        let files = fileReferences ?? items.flatMap(\.representations).filter { $0.type == "public.file-url" }.compactMap { value -> ClipFile? in
            guard let string = string(value.data,type:value.type), let url = URL(string:string), url.isFileURL else { return nil }
            return ClipFile(path:url.path,bookmark:try? url.bookmarkData(options:[.withSecurityScope,.securityScopeAllowOnlyReadAccess],includingResourceValuesForKeys:nil,relativeTo:nil))
        }
        if !files.isEmpty { return (.files(files),snapshot) }
        for item in items {
            for (type,format) in imageFormats {
                if let image = item.representations.first(where: { $0.type == type }) {
                    guard let source = CGImageSourceCreateWithData(image.data as CFData,nil), let props = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                          let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
                          width > 0, height > 0, width <= 12000, height <= 12000, width * height <= 20_000_000 else { throw ClipboardError.oversized }
                    return (.image(image.data,format:format),snapshot)
                }
            }
        }
        if !text.isEmpty { return (.text(text),snapshot) }
        if snapshot.formats.contains("com.adobe.pdf") { return (.text("PDF剪贴板内容"),snapshot) }
        if snapshot.hasRichText { return (.text("富文本内容"),snapshot) }
        throw ClipboardError.oversized
    }
}
