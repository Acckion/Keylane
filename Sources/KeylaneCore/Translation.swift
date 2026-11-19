import Foundation
import CryptoKit

public enum TranslationProvider: String, Codable, CaseIterable, Sendable {
    case ai, google, microsoft, youdao, baidu
    public var title: String {
        switch self {
        case .ai: "AI 模型"
        case .google: "Google Cloud Translation"
        case .microsoft: "Microsoft Translator"
        case .youdao: "有道翻译"
        case .baidu: "百度翻译"
        }
    }
}

public struct TranslationLanguage: Identifiable, Hashable, Sendable {
    public let id: String
    public let english: String
    public let chinese: String
    public var title: String { Locale.current.language.languageCode?.identifier == "zh" ? chinese : english }
    public static let detect = Self(id: "auto", english: "Detect Language", chinese: "自动检测")
    public static let all: [Self] = [
        .init(id: "zh-Hans", english: "Chinese (Simplified)", chinese: "简体中文"),
        .init(id: "zh-Hant", english: "Chinese (Traditional)", chinese: "繁体中文"),
        .init(id: "en", english: "English", chinese: "英语"), .init(id: "ja", english: "Japanese", chinese: "日语"),
        .init(id: "ko", english: "Korean", chinese: "韩语"), .init(id: "fr", english: "French", chinese: "法语"),
        .init(id: "de", english: "German", chinese: "德语"), .init(id: "es", english: "Spanish", chinese: "西班牙语"),
        .init(id: "pt", english: "Portuguese", chinese: "葡萄牙语"), .init(id: "it", english: "Italian", chinese: "意大利语"),
        .init(id: "ru", english: "Russian", chinese: "俄语"), .init(id: "ar", english: "Arabic", chinese: "阿拉伯语"),
        .init(id: "th", english: "Thai", chinese: "泰语"), .init(id: "vi", english: "Vietnamese", chinese: "越南语"),
        .init(id: "id", english: "Indonesian", chinese: "印度尼西亚语"), .init(id: "ms", english: "Malay", chinese: "马来语"),
        .init(id: "hi", english: "Hindi", chinese: "印地语"), .init(id: "tr", english: "Turkish", chinese: "土耳其语"),
        .init(id: "nl", english: "Dutch", chinese: "荷兰语"), .init(id: "pl", english: "Polish", chinese: "波兰语"),
        .init(id: "sv", english: "Swedish", chinese: "瑞典语"), .init(id: "da", english: "Danish", chinese: "丹麦语"),
        .init(id: "fi", english: "Finnish", chinese: "芬兰语"), .init(id: "el", english: "Greek", chinese: "希腊语"),
        .init(id: "cs", english: "Czech", chinese: "捷克语"), .init(id: "ro", english: "Romanian", chinese: "罗马尼亚语"),
        .init(id: "hu", english: "Hungarian", chinese: "匈牙利语"), .init(id: "uk", english: "Ukrainian", chinese: "乌克兰语")
    ]
    public static func language(_ id: String) -> Self? { id == "auto" ? detect : all.first { $0.id == id } }
    public func code(for provider: TranslationProvider) -> String {
        switch provider {
        case .ai: return id
        case .google: return ["zh-Hans": "zh-CN", "zh-Hant": "zh-TW"][id] ?? id
        case .microsoft: return id == "auto" ? "auto" : id
        case .youdao: return ["zh-Hans": "zh-CHS", "zh-Hant": "zh-CHT"][id] ?? id
        case .baidu:
            return ["zh-Hans": "zh", "zh-Hant": "cht", "ja": "jp", "ko": "kor", "fr": "fra", "es": "spa",
                    "ar": "ara", "vi": "vie", "ms": "may", "sv": "swe", "da": "dan", "fi": "fin",
                    "el": "el", "cs": "cs", "ro": "rom", "hu": "hu", "uk": "ukr"][id] ?? id
        }
    }
    public static func detected(_ code: String, provider: TranslationProvider) -> String? {
        all.first { $0.code(for: provider).lowercased() == code.lowercased() }?.id
    }
}

public struct TranslationCredentials: Codable, Equatable, Sendable {
    public var key: String
    public var appID: String
    public var region: String
    public init(key: String = "", appID: String = "", region: String = "") { self.key = key; self.appID = appID; self.region = region }
}

public struct TranslationResult: Equatable, Sendable {
    public let text: String
    public let detectedLanguage: String?
    public init(text: String, detectedLanguage: String? = nil) { self.text = text; self.detectedLanguage = detectedLanguage }
}

public enum TranslationFailure: LocalizedError {
    case configuration, invalidResponse, inputTooLong, http(Int), provider(String)
    public var errorDescription: String? {
        switch self {
        case .configuration: "请在翻译设置中配置提供商密钥或 AI 模型。"
        case .invalidResponse: "翻译服务返回了无法读取的结果。"
        case .inputTooLong: "一次最多翻译 5,000 个 UTF-8 字节，请缩短原文。"
        case .http(let code): "翻译请求失败（HTTP \(code)），请检查密钥、额度与网络。"
        case .provider(let code): "翻译服务拒绝了请求（\(code)），请检查账户配置与语言支持。"
        }
    }
}

public enum TranslationAPI {
    public static func request(provider: TranslationProvider, text: String, source: String, target: String,
                               credentials: TranslationCredentials, salt: String = UUID().uuidString,
                               timestamp: String = String(Int(Date().timeIntervalSince1970))) throws -> URLRequest {
        guard text.utf8.count <= 5_000 else { throw TranslationFailure.inputTooLong }
        guard !credentials.key.isEmpty, let sourceLanguage = TranslationLanguage.language(source),
              let targetLanguage = TranslationLanguage.language(target), target != "auto" else { throw TranslationFailure.configuration }
        let from = sourceLanguage.code(for: provider), to = targetLanguage.code(for: provider)
        var fields: [String: String] = [:]
        let url: String
        switch provider {
        case .ai: throw TranslationFailure.configuration
        case .google:
            url = "https://translation.googleapis.com/language/translate/v2"
            fields = ["q": text, "target": to, "format": "text"]
            if source != "auto" { fields["source"] = from }
        case .microsoft: url = "https://api.cognitive.microsofttranslator.com/translate"
        case .youdao:
            guard !credentials.appID.isEmpty else { throw TranslationFailure.configuration }
            url = "https://openapi.youdao.com/api"
            let scalars = Array(text.unicodeScalars)
            let input = scalars.count <= 20 ? text : String(String.UnicodeScalarView(scalars.prefix(10))) + String(scalars.count) + String(String.UnicodeScalarView(scalars.suffix(10)))
            let signature = SHA256.hash(data: Data((credentials.appID + input + salt + timestamp + credentials.key).utf8))
            fields = ["q": text, "from": from, "to": to, "appKey": credentials.appID, "salt": salt,
                      "curtime": timestamp, "signType": "v3", "sign": signature.map { String(format: "%02x", $0) }.joined()]
        case .baidu:
            guard !credentials.appID.isEmpty else { throw TranslationFailure.configuration }
            url = "https://fanyi-api.baidu.com/api/trans/vip/translate"
            let signature = Insecure.MD5.hash(data: Data((credentials.appID + text + salt + credentials.key).utf8))
            fields = ["q": text, "from": from, "to": to, "appid": credentials.appID, "salt": salt,
                      "sign": signature.map { String(format: "%02x", $0) }.joined()]
        }
        var components = URLComponents(string: url)!
        if provider == .microsoft {
            components.queryItems = [.init(name: "api-version", value: "3.0"), .init(name: "to", value: to)]
            if source != "auto" { components.queryItems?.append(.init(name: "from", value: from)) }
        }
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if provider == .google {
            request.setValue(credentials.key, forHTTPHeaderField: "X-Goog-Api-Key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        } else if provider == .microsoft {
            request.setValue(credentials.key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
            if !credentials.region.isEmpty { request.setValue(credentials.region, forHTTPHeaderField: "Ocp-Apim-Subscription-Region") }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [["Text": text]])
        } else {
            var form = URLComponents()
            form.queryItems = fields.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
            request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private static func decodeEntities(_ text: String) -> String {
        let pattern = "&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos);"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var output = text
        let names = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'"]
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let tokenRange = Range(match.range(at: 1), in: text), let whole = Range(match.range, in: output) else { continue }
            let token = String(text[tokenRange])
            let replacement: String?
            if token.hasPrefix("#") {
                let hexadecimal = token.hasPrefix("#x")
                let digits = token.dropFirst(hexadecimal ? 2 : 1)
                replacement = UInt32(digits, radix: hexadecimal ? 16 : 10).flatMap(UnicodeScalar.init).map(String.init)
            } else { replacement = names[token] }
            if let replacement { output.replaceSubrange(whole, with: replacement) }
        }
        return output
    }

    public static func result(provider: TranslationProvider, data: Data) throws -> TranslationResult {
        let json = try JSONSerialization.jsonObject(with: data)
        var text: String?
        var detected: String?
        switch provider {
        case .google:
            let root = json as? [String: Any]
            let body = root?["data"] as? [String: Any]
            let translation = (body?["translations"] as? [[String: Any]])?.first
            text = (translation?["translatedText"] as? String).map(decodeEntities)
            detected = translation?["detectedSourceLanguage"] as? String
        case .microsoft:
            let item = (json as? [[String: Any]])?.first
            text = ((item?["translations"] as? [[String: Any]])?.first)?["text"] as? String
            detected = (item?["detectedLanguage"] as? [String: Any])?["language"] as? String
        case .youdao:
            let item = json as? [String: Any]
            if let code = item?["errorCode"] as? String, code != "0" { throw TranslationFailure.provider(code) }
            text = (item?["translation"] as? [String])?.joined(separator: "\n")
            detected = (item?["l"] as? String)?.components(separatedBy: "2").first
        case .baidu:
            let item = json as? [String: Any]
            if let code = item?["error_code"] as? String { throw TranslationFailure.provider(code) }
            text = (item?["trans_result"] as? [[String: String]])?.compactMap { $0["dst"] }.joined(separator: "\n")
            detected = item?["from"] as? String
        case .ai: throw TranslationFailure.invalidResponse
        }
        guard let text, !text.isEmpty else { throw TranslationFailure.invalidResponse }
        return .init(text: text, detectedLanguage: detected.flatMap { TranslationLanguage.detected($0, provider: provider) })
    }
}
