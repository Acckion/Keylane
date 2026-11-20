import XCTest
@testable import KeylaneCore

final class FocusTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func testDomainNormalizationAndBoundaryMatching() throws {
        XCTAssertEqual(FocusWebsite.host("https://WWW.Baidu.com/search?q=hi"), "baidu.com")
        XCTAssertEqual(FocusWebsite.host("example.com."), "example.com")
        for input in [".", ".com", "https://.", "hello world.com", "javascript:alert(1)", "file:///tmp/a", "https://user:pass@example.com", "foo..com", "-a.com"] {
            XCTAssertNil(FocusWebsite.host(input), input)
        }
        XCTAssertEqual(FocusWebsite.host("gemini"), "gemini")
        XCTAssertTrue(FocusWebsite.matches("gemini.google.com", rule: "gemini"))
        XCTAssertFalse(FocusWebsite.matches("notgemini.com", rule: "gemini"))
        XCTAssertTrue(FocusWebsite.matches("NEWS.EXAMPLE.COM.", rule: "example.com"))
        XCTAssertTrue(FocusWebsite.matches("news.example.com", rule: "example.com"))
        XCTAssertFalse(FocusWebsite.matches("notexample.com", rule: "example.com"))
        XCTAssertFalse(FocusWebsite.matches("example.com.evil.com", rule: "example.com"))
    }
    func testAllowModeAndAllowAllWebsitesOnlyWithoutExplicitRules() {
        var config = FocusConfiguration(); config.mode = .allow
        config.applications = [.init(id: "com.example.Work", name: "Work")]
        XCTAssertFalse(config.blocks(application: "com.example.work"))
        XCTAssertTrue(config.blocks(application: "com.example.Play"))
        XCTAssertTrue(config.blocks(website: URL(string: "https://example.com")!, allowAllWebsites: false))
        XCTAssertFalse(config.blocks(website: URL(string: "https://example.com")!, allowAllWebsites: true))
        config.websites = ["work.example.com"]
        XCTAssertTrue(config.blocks(website: URL(string: "https://example.com")!, allowAllWebsites: true))
        XCTAssertFalse(config.blocks(website: URL(string: "https://docs.work.example.com")!, allowAllWebsites: false))
        XCTAssertFalse(config.blocks(website: URL(string: "file:///tmp/block.html")!, allowAllWebsites: false))
    }
    func testBlockModeAndWebsiteScope() {
        var config = FocusConfiguration(); config.websites = ["example.com"]
        XCTAssertTrue(config.blocks(website: URL(string: "https://www.example.com")!, allowAllWebsites: true))
        XCTAssertFalse(config.blocks(website: URL(string: "https://example.com.evil.org")!, allowAllWebsites: false))
        XCTAssertFalse(config.blocks(application: "com.example.work"))
    }
    func testPauseResumeAndSleepDoNotConsumeTime() {
        var config = FocusConfiguration(); config.duration = 600
        var session = FocusSession(configuration: config, now: start)
        session.pause(at: start.addingTimeInterval(120), breakDuration: 180)
        XCTAssertEqual(session.remaining(at: start.addingTimeInterval(900)), 480)
        XCTAssertEqual(session.breakEnds, start.addingTimeInterval(300))
        session.pause(at: start.addingTimeInterval(900))
        XCTAssertEqual(session.elapsed(at: start.addingTimeInterval(900)), 120)
        session.resume(at: start.addingTimeInterval(900))
        session.resume(at: start.addingTimeInterval(920))
        XCTAssertEqual(session.remaining(at: start.addingTimeInterval(960)), 420)
        XCTAssertNil(session.breakEnds)
        XCTAssertEqual(session.remaining(at: start.addingTimeInterval(2000)), 0)
    }
    func testSnoozeInAllowModeIncludesUnlistedTargetsAndExpires() {
        var config = FocusConfiguration(); config.mode = .allow
        var session = FocusSession(configuration: config, now: start)
        session.snooze("news.example.com", at: start, duration: 180)
        session.snooze("com.example.Chat", at: start, duration: 60)
        XCTAssertEqual(Set(session.snoozeKeys(at: start)), ["news.example.com", "com.example.Chat"])
        XCTAssertTrue(session.snoozed("news.example.com", at: start.addingTimeInterval(179)))
        XCTAssertFalse(session.snoozed("news.example.com", at: start.addingTimeInterval(180)))
        session.expireSnoozes(at: start.addingTimeInterval(61))
        XCTAssertEqual(session.snoozeKeys(at: start.addingTimeInterval(61)), ["news.example.com"])
    }
    func testDurationFormsAndInvalidInputs() throws {
        for (input, seconds) in [("45 min", 2700.0), ("1:30", 5400), ("15分钟", 900), ("1.5h", 5400), ("1 hour 30 minutes", 5400), ("1小时30分钟", 5400), ("24h", 86400), ("30", 1800)] {
            XCTAssertEqual(try FocusDuration.parse(input), seconds, input)
        }
        XCTAssertNil(try FocusDuration.parse("No Limit"))
        for invalid in ["-1", "0", "1:60", "nan", "inf", "25h", "45 garbage"] { XCTAssertThrowsError(try FocusDuration.parse(invalid), invalid) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 10))!
        XCTAssertEqual(try FocusDuration.parse("until 6pm", now: morning, calendar: calendar), 8 * 3600)
        XCTAssertEqual(try FocusDuration.parse("直到 18:00", now: morning, calendar: calendar), 8 * 3600)
    }
    func testCategoryRoundTripNormalizesAndRejectsWholeInvalidImport() throws {
        let id = UUID()
        let category = FocusCategory(id: id, name: " Study ", applications: [.init(id: "com.example.Work", name: "Work"), .init(id: "com.example.work", name: "Duplicate")], websites: ["www.example.com", "https://example.com/a"])
        let imported = try FocusStore.decodeCategories(FocusStore.encodeCategories([category]))
        XCTAssertEqual(imported.count, 1); XCTAssertEqual(imported[0].id, id)
        XCTAssertEqual(imported[0].name, "Study"); XCTAssertEqual(imported[0].applications.count, 1)
        XCTAssertEqual(imported[0].websites, ["example.com"])
        XCTAssertThrowsError(try FocusStore.decodeCategories(FocusStore.encodeCategories([category, category])))
        XCTAssertThrowsError(try FocusStore.decodeCategories(Data("{\"version\":99,\"categories\":[]}".utf8)))
        XCTAssertThrowsError(try FocusStore.decodeCategories(Data(repeating: 32, count: 2_000_001)))
    }
    func testCompletionAndCancellationHaveDifferentHistoryRecords() throws {
        let session = FocusSession(configuration: FocusConfiguration(), now: start)
        let completed = FocusRecord(session: session, ended: start.addingTimeInterval(300), completed: true)
        let canceled = FocusRecord(session: session, ended: start.addingTimeInterval(120), completed: false)
        XCTAssertTrue(completed.completed); XCTAssertFalse(canceled.completed)
        XCTAssertTrue(completed.session.paused)
        XCTAssertEqual(completed.session.elapsed(at: start.addingTimeInterval(1000)), 300)
        let legacy = try JSONDecoder().decode(FocusArchive.self, from: Data("{}".utf8))
        XCTAssertTrue(legacy.history.isEmpty); XCTAssertTrue(legacy.terminatedApplications.isEmpty)
    }
    func testStatePersistsAcrossRestartAndFailedReadPreservesSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let store = FocusStore(url: url)
        XCTAssertTrue(try store.load().categories.isEmpty)
        var archive = FocusArchive(); archive.categories = [FocusCategory(name: "Study")]
        archive.session = FocusSession(configuration: FocusConfiguration(), now: start)
        archive.session?.snooze("example.com", at: start, duration: 180)
        try store.save(archive)
        XCTAssertEqual(try FocusStore(url: url).load(), archive)
        let invalid = Data("bad-data".utf8); try invalid.write(to: url)
        XCTAssertThrowsError(try store.load()); XCTAssertEqual(try Data(contentsOf: url), invalid)
    }
}
