import AppKit
import Foundation

/// Produces real AppKit font/link attributes for rich-text paste targets.
/// No HTML renderer or remote resources are involved.
enum AIResponseFormatting {
    static func attributed(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        var fenced = false
        let lines = markdown.components(separatedBy: .newlines)
        for (index, raw) in lines.enumerated() {
            var line = raw
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fenced.toggle(); continue }
            var size: CGFloat = 13
            var bold = false
            if !fenced {
                let hashes = line.prefix { $0 == "#" }.count
                if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
                    line = String(line.dropFirst(hashes + 1)); size = CGFloat(23 - hashes * 2); bold = true
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") { line = "• " + line.dropFirst(2) }
            }
            let base = fenced ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                : NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            if fenced { result.append(NSAttributedString(string: line, attributes: [.font: base])) }
            else if let text = try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                for run in text.runs {
                    var font = base
                    var attributes: [NSAttributedString.Key: Any] = [:]
                    if let intent = run.inlinePresentationIntent {
                        if intent.contains(.code) { font = .monospacedSystemFont(ofSize: size, weight: .regular) }
                        if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                        if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                        if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    }
                    if let link = run.link, ["https", "http"].contains(link.scheme?.lowercased() ?? "") { attributes[.link] = link }
                    attributes[.font] = font
                    result.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
                }
            } else { result.append(NSAttributedString(string: line, attributes: [.font: base])) }
            if index < lines.count - 1 { result.append(NSAttributedString(string: "\n", attributes: [.font: base])) }
        }
        return result
    }

    static func rtf(_ markdown: String) -> Data? {
        let text = attributed(markdown)
        return try? text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }
}
