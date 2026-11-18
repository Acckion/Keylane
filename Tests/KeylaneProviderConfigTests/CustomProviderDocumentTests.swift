import Foundation
import KeylaneProviderConfig
import XCTest

final class CustomProviderDocumentTests: XCTestCase {
    func testCompositeModelIdentityIsUnambiguous() throws {
        let first = CustomProviderDocument.modelIdentity(providerID: "a::b", modelID: "c")
        let second = CustomProviderDocument.modelIdentity(providerID: "a", modelID: "b::c")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first, CustomProviderDocument.modelIdentity(providerID: "a::b", modelID: "c"))
        let unicode = CustomProviderDocument.modelIdentity(providerID: "提供商", modelID: "模型::a")
        XCTAssertNotEqual(unicode, CustomProviderDocument.modelIdentity(providerID: "提供商::模型", modelID: "a"))
    }

    func testProviderMappingAndAdditionalParameters() throws {
        let yaml = """
        providers:
          - id: proxy
            name: Proxy
            base_url: https://example.com/v1
            api_keys: {primary: fixture-key}
            additional_parameters:
              provider: {sort: throughput}
            models:
              - id: vendor/model
                provider: primary
                context: 128000
                abilities:
                  vision: {supported: true}
        """
        let parsed = try CustomProviderDocument.decode(Data(yaml.utf8))
        XCTAssertEqual(parsed.providers.first?.models.first?.id, "vendor/model")
        XCTAssertEqual(parsed.providers.first?.models.first?.abilities?["vision"]?.supported, true)
        XCTAssertEqual(try parsed.providers.first?.additional_parameters?.json(), #"{"provider":{"sort":"throughput"}}"#)
        XCTAssertThrowsError(try CustomProviderDocument.decode(Data(yaml.replacingOccurrences(of: "https://example.com", with: "http://example.com").utf8)))
        XCTAssertThrowsError(try CustomProviderDocument.decode(Data(yaml.replacingOccurrences(of: "provider: primary", with: "provider: missing").utf8)))
        XCTAssertThrowsError(try CustomProviderDocument.decode(Data(yaml.replacingOccurrences(of: "provider: {sort: throughput}", with: "messages: []").utf8)))
    }

    func testAnonymousLocalProviderAndInvalidModelSets() throws {
        let yaml = """
        providers:
          - id: local
            name: Local
            base_url: http://localhost:4000
            models:
              - id: sample
                name: Sample
                context: 128000
        """
        let provider = try XCTUnwrap(CustomProviderDocument.decode(Data(yaml.utf8)).providers.first)
        XCTAssertNil(provider.api_keys)
        XCTAssertThrowsError(try CustomProviderDocument.decode(Data(yaml.replacingOccurrences(of: "context: 128000", with: "context: -1").utf8)))
        XCTAssertThrowsError(try CustomProviderDocument.decode(Data(yaml.replacingOccurrences(of: "context: 128000", with: "context: 128000\n      - id: sample").utf8)))
        XCTAssertThrowsError(try CustomProviderDocument.decode(Data(repeating: 32, count: 1_048_577)))
    }
}
