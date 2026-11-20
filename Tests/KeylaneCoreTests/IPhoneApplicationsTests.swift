import XCTest
@testable import KeylaneCore

final class IPhoneApplicationsTests: XCTestCase {
    func testPayloadValidationAndSeparateIdentity() throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: ["bundleID": "com.example.same"], requiringSecureCoding: false)
        XCTAssertEqual(IPhoneApplicationCatalog.bundleID(data), "com.example.same")
        XCTAssertEqual(IPhoneApplication(bundleID: "com.example.same", name: "Same").id, "iphone:com.example.same")
        XCTAssertNil(IPhoneApplicationCatalog.bundleID(Data("broken".utf8)))
        for id in ["--bad", "com.example;open", "com.example app", "com.example/../app", ""] {
            XCTAssertFalse(IPhoneApplication.validIdentifier(id))
        }
    }
    func testCacheDiscoverySurvivesVersionAndUUIDChangesAndSkipsMacPlaceholders() throws {
        let library = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: library) }
        func write(_ value: [String: Any], _ path: URL) throws {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0).write(to: path)
        }
        XCTAssertTrue(IPhoneApplicationCatalog.scan(library: library).isEmpty)
        let container = library.appendingPathComponent("Daemon Containers/" + UUID().uuidString)
        try write(["MCMMetadataIdentifier": "com.apple.appplaceholdersyncd"], container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
        let cache = container.appendingPathComponent("Data/Library/Caches/Placeholders-v999.noindex")
        let payload = try NSKeyedArchiver.archivedData(withRootObject: ["bundleID": "com.example.same"], requiringSecureCoding: false)
        for name in ["One", "Duplicate"] {
            try write(["CFBundleIdentifier": "com.example.same", "CFBundleName": "Same", "NSiPhoneMirroringLaunchPayload": payload], cache.appendingPathComponent(name + ".app/Contents/Info.plist"))
        }
        try write(["NSiPhoneMirroringLaunchPayload": Data("broken".utf8)], cache.appendingPathComponent("Bad.app/Contents/Info.plist"))
        XCTAssertEqual(IPhoneApplicationCatalog.scan(library: library).map(\.bundleID), ["com.example.same"])
        XCTAssertTrue(ApplicationCatalog.scan(roots: [cache.path], excluded: []).isEmpty)
        try FileManager.default.removeItem(at: cache)
        XCTAssertTrue(IPhoneApplicationCatalog.scan(library: library).isEmpty)
    }
    func testNewAndLegacyDeviceSchemaAndSelection() throws {
        let id = UUID().uuidString
        func parse(_ device: [String: Any]) throws -> [IPhoneDevice] {
            try IPhoneDevice.parse(JSONSerialization.data(withJSONObject: ["info": ["outcome": "success"], "result": ["devices": [device]]]))
        }
        let hardware = ["deviceType": "iPhone", "reality": "physical"]
        let modern = try parse(["identifier": id, "properties": ["hardware": hardware, "state": ["name": "Phone"], "connection": ["pairingState": "paired", "state": "connected"]]])
        let legacy = try parse(["identifier": id, "hardwareProperties": hardware, "deviceProperties": ["name": "Phone"], "connectionProperties": ["pairingState": "paired", "tunnelState": "connected"]])
        XCTAssertEqual(modern, legacy)
        XCTAssertTrue(try IPhoneDevice.select(modern, preferred: "").available)
        XCTAssertThrowsError(try IPhoneDevice.select(modern + modern, preferred: ""))
        XCTAssertThrowsError(try IPhoneDevice.select(modern, preferred: UUID().uuidString))
        XCTAssertThrowsError(try IPhoneDevice.select([], preferred: ""))
        XCTAssertEqual(try IPhoneDevice.select(modern, preferred: id).id, id)
        XCTAssertTrue(try parse(["identifier": id, "hardwareProperties": ["deviceType": "Watch", "reality": "physical"], "connectionProperties": ["pairingState": "paired"]]).isEmpty)
        XCTAssertThrowsError(try IPhoneDevice.parse(Data("{}".utf8)))
    }
}
