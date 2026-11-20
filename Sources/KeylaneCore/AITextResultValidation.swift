import Foundation

/// Snippet transformations must not resolve or alter executable template placeholders.
public enum AITextResultValidation {
    public static func preservingPlaceholders(source: String, result: String) throws -> String {
        let names = DynamicTemplate.Kind.allCases.map { NSRegularExpression.escapedPattern(for: $0.rawValue) }.joined(separator: "|")
        let pattern = "\\{(?:" + names + ")\\b[^{}]*\\}"
        let expression = try NSRegularExpression(pattern: pattern)
        func tokens(_ value: String) -> [String: Int] {
            var counts: [String: Int] = [:]
            for match in expression.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
                if let range = Range(match.range, in: value) { counts[String(value[range]), default: 0] += 1 }
            }
            return counts
        }
        guard tokens(source) == tokens(result) else { throw AIActionError.invalidResult }
        return result
    }
}

public enum EmojiAIResult {
    public static func glyphs(_ result: String, allowed: Set<String>) throws -> [String] {
        guard result.utf8.count <= 8_192, let data = result.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data), values.count <= 24 else { throw AIActionError.invalidResult }
        var seen = Set<String>()
        let valid = values.filter { allowed.contains($0) && seen.insert($0).inserted }.prefix(12)
        guard !valid.isEmpty else { throw AIActionError.invalidResult }
        return Array(valid)
    }
    public static func normalized(_ result: String, allowed: Set<String>) throws -> String {
        String(decoding: try JSONEncoder().encode(glyphs(result, allowed: allowed)), as: UTF8.self)
    }
}
