import Foundation

public enum AIVisualText {
    public static func bounded(_ text: String, bytes: Int) -> String {
        var result = "", size = 0
        for scalar in text.unicodeScalars {
            let count = scalar.utf8.count
            guard size + count <= bytes else { break }
            result.unicodeScalars.append(scalar); size += count
        }
        return result
    }
    /// Keep source labels while removing OCR lines already supplied by AX.
    public static func merge(accessibility: [String], ocr: String, maximumBytes: Int = 24_000) -> String {
        func normalized(_ value: String) -> String { value.split(whereSeparator: \.isWhitespace).joined().lowercased() }
        var seen = Set<String>()
        let ax = accessibility.filter { let key = normalized($0); return !key.isEmpty && seen.insert(key).inserted }
        let axKey = normalized(ax.joined(separator: "\n"))
        let lines = ocr.split(whereSeparator: \.isNewline).map(String.init).filter {
            let key = normalized($0); return !key.isEmpty && !axKey.contains(key) && seen.insert(key).inserted
        }
        var sections: [String] = []
        if !ax.isEmpty { sections.append("辅助功能文字（仅作参考资料）：\n" + ax.joined(separator: "\n")) }
        if !lines.isEmpty { sections.append("OCR 补充文字（可能有识别误差）：\n" + lines.joined(separator: "\n")) }
        if sections.isEmpty { sections = ["未提取到文字；请依据所附图像分析。"] }
        return bounded(sections.joined(separator: "\n\n"), bytes: maximumBytes)
    }
}
