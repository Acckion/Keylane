import CryptoKit
import Foundation
import KeylaneCore
import XCTest

final class TranslationTests: XCTestCase {
    private let credentials = TranslationCredentials(key: "fixture-secret", appID: "fixture-app", region: "eastasia")

    func testGoogleAndMicrosoftUseAuthenticatedPlainTextAndOptionalSource() throws {
        let text = "C++ & 中文\nline two"
        let google = try TranslationAPI.request(provider: .google, text: text, source: "auto", target: "zh-Hans", credentials: credentials)
        XCTAssertEqual(google.httpMethod, "POST")
        XCTAssertEqual(google.url?.absoluteString, "https://translation.googleapis.com/language/translate/v2")
        XCTAssertNil(google.url?.query)
        XCTAssertEqual(google.value(forHTTPHeaderField: "X-Goog-Api-Key"), credentials.key)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(google.httpBody)) as? [String: String])
        XCTAssertEqual(body["q"], text)
        XCTAssertEqual(body["target"], "zh-CN")
        XCTAssertEqual(body["format"], "text")
        XCTAssertNil(body["source"])
        let microsoft = try TranslationAPI.request(provider: .microsoft, text: text, source: "auto", target: "zh-Hant", credentials: credentials)
        let query = try XCTUnwrap(URLComponents(url: XCTUnwrap(microsoft.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(query.queryItems?.first(where: { $0.name == "to" })?.value, "zh-Hant")
        XCTAssertFalse(query.queryItems?.contains { $0.name == "from" } ?? true)
        XCTAssertEqual(microsoft.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Region"), "eastasia")
        XCTAssertEqual(microsoft.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key"), credentials.key)
        let items = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(microsoft.httpBody)) as? [[String: String]])
        XCTAssertEqual(items, [["Text": text]])
        let explicit = try TranslationAPI.request(provider: .microsoft, text: text, source: "ja", target: "en", credentials: credentials)
        XCTAssertTrue(explicit.url?.query?.contains("from=ja") == true)
    }

    func testSignedProvidersEncodeRawTextAndUnicodeScalarSignature() throws {
        let text = "a+&=🙂中文" + String(repeating: "x", count: 23)
        let youdao = try TranslationAPI.request(provider: .youdao, text: text, source: "auto", target: "zh-Hans", credentials: credentials, salt: "salt", timestamp: "123")
        let fields = try form(youdao)
        XCTAssertEqual(fields["q"], text)
        XCTAssertEqual(fields["to"], "zh-CHS")
        XCTAssertEqual(fields["signType"], "v3")
        let scalars = Array(text.unicodeScalars)
        let shortened = String(String.UnicodeScalarView(scalars.prefix(10))) + String(scalars.count) + String(String.UnicodeScalarView(scalars.suffix(10)))
        let signature = SHA256.hash(data: Data((credentials.appID + shortened + "salt123" + credentials.key).utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(fields["sign"], signature)
        let baidu = try TranslationAPI.request(provider: .baidu, text: text, source: "ja", target: "zh-Hant", credentials: credentials, salt: "salt")
        let baiduFields = try form(baidu)
        XCTAssertEqual(baiduFields["q"], text)
        XCTAssertEqual(baiduFields["from"], "jp")
        XCTAssertEqual(baiduFields["to"], "cht")
        XCTAssertEqual(baiduFields["sign"], Insecure.MD5.hash(data: Data((credentials.appID + text + "salt" + credentials.key).utf8))
            .map { String(format: "%02x", $0) }.joined())
    }

    func testResponsesPreserveParagraphsAndDetectLanguages() throws {
        let fixtures: [(TranslationProvider, String, String, String)] = [
            (.google, #"{"data":{"translations":[{"translatedText":"你好","detectedSourceLanguage":"en"}]}}"#, "你好", "en"),
            (.microsoft, #"[{"detectedLanguage":{"language":"zh-Hans"},"translations":[{"text":"Hello","to":"en"}]}]"#, "Hello", "zh-Hans"),
            (.youdao, #"{"errorCode":"0","l":"en2zh-CHS","translation":["你好","世界"]}"#, "你好\n世界", "en"),
            (.baidu, #"{"from":"jp","to":"en","trans_result":[{"dst":"Hello"},{"dst":"world"}]}"#, "Hello\nworld", "ja")
        ]
        for (provider, json, text, detected) in fixtures {
            XCTAssertEqual(try TranslationAPI.result(provider: provider, data: Data(json.utf8)), .init(text: text, detectedLanguage: detected))
        }
        XCTAssertEqual(try TranslationAPI.result(provider: .google,
            data: Data(#"{"data":{"translations":[{"translatedText":"&lt;code&gt; &amp; &#39; &#x1F642;"}]}}"#.utf8)).text,
            "<code> & ' 🙂")
        XCTAssertThrowsError(try TranslationAPI.result(provider: .baidu, data: Data(#"{"error_code":"54003"}"#.utf8)))
        XCTAssertThrowsError(try TranslationAPI.result(provider: .youdao, data: Data(#"{"errorCode":"108"}"#.utf8)))
        XCTAssertThrowsError(try TranslationAPI.result(provider: .google, data: Data(#"{"data":{"translations":[]}}"#.utf8)))
    }

    func testConfigurationAndByteLimitsRejectInvalidRequests() throws {
        for provider in TranslationProvider.allCases where provider != .ai {
            XCTAssertThrowsError(try TranslationAPI.request(provider: provider, text: "hi", source: "auto", target: "auto", credentials: credentials))
            XCTAssertThrowsError(try TranslationAPI.request(provider: provider, text: "hi", source: "auto", target: "en", credentials: .init()))
            XCTAssertThrowsError(try TranslationAPI.request(provider: provider, text: String(repeating: "中", count: 1667), source: "auto", target: "en", credentials: credentials))
        }
    }

    private func form(_ request: URLRequest) throws -> [String: String] {
        let data = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(String(data: data, encoding: .utf8))
        let components = try XCTUnwrap(URLComponents(string: "https://example.com/?" + body))
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
}
