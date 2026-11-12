import XCTest
@testable import KeylaneCore

final class AgendaTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func event(_ id: String, _ start: String, _ end: String, allDay: Bool = false, title: String = "日程", location: String = "") -> AgendaEvent {
        .init(id: id, calendarID: "fixture", calendarTitle: "工作日历", title: title, start: date(start), end: date(end), allDay: allDay, location: location)
    }
    func testDayIncludesOverlappingEventsButExcludesExclusiveEnd() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let events = [event("previous", "2026-11-10T23:00:00Z", "2026-11-11T00:00:00Z"),
                      event("overlap", "2026-11-10T23:00:00Z", "2026-11-11T01:00:00Z"),
                      event("next", "2026-11-12T00:00:00Z", "2026-11-12T01:00:00Z"),
                      event("day", "2026-11-11T00:00:00Z", "2026-11-12T00:00:00Z", allDay: true),
                      event("instant", "2026-11-11T00:00:00Z", "2026-11-11T00:00:00Z")]
        XCTAssertEqual(Set(AgendaPolicy.day(events, date: date("2026-11-11T12:00:00Z"), calendar: calendar).map(\.id)), ["overlap", "day", "instant"])
        XCTAssertEqual(AgendaPolicy.day(events, date: date("2026-11-11T12:00:00Z"), calendar: calendar).first?.id, "day")
    }
    func testDayUsesCalendarArithmeticAcrossDST() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let events = [event("late", "2026-03-09T03:30:00Z", "2026-03-09T03:45:00Z"), event("next", "2026-03-09T04:00:00Z", "2026-03-09T05:00:00Z")]
        XCTAssertEqual(AgendaPolicy.day(events, date: date("2026-03-08T12:00:00Z"), calendar: calendar).map(\.id), ["late"])
    }
    func testNextTimedIgnoresAllDayAndEndedButKeepsOngoing() {
        let events = [event("all", "2026-11-11T00:00:00Z", "2026-11-12T00:00:00Z", allDay: true),
                      event("ended", "2026-11-11T08:00:00Z", "2026-11-11T09:00:00Z"),
                      event("ongoing", "2026-11-11T09:00:00Z", "2026-11-11T11:00:00Z"),
                      event("later", "2026-11-11T12:00:00Z", "2026-11-11T13:00:00Z")]
        XCTAssertEqual(AgendaPolicy.nextTimed(events, now: date("2026-11-11T10:00:00Z"))?.id, "ongoing")
        XCTAssertFalse(AgendaPolicy.upcoming(events, now: date("2026-11-11T09:00:00Z")).contains { $0.id == "ended" })
    }
    func testUnicodeMultiwordSearchAndStableTies() {
        let a = event("a", "2026-11-11T09:00:00Z", "2026-11-11T10:00:00Z", title: "中文项目评审", location: "Room A")
        let b = event("b", "2026-11-11T09:00:00Z", "2026-11-11T10:00:00Z", title: "另外一个事件")
        XCTAssertEqual(AgendaPolicy.matching([a,b], query: "评审 room").map(\.id), ["a"])
        XCTAssertTrue(AgendaPolicy.matching([a,b], query: "评审 不存在").isEmpty)
        XCTAssertEqual(AgendaPolicy.ordered([b,a]).map(\.id), ["a","b"])
    }

    func testFreeIntervalsClipsAndMergesBusyEvents() {
        let work = DateInterval(start: date("2026-11-11T09:00:00Z"), end: date("2026-11-11T18:00:00Z"))
        let busy = [
            event("early", "2026-11-11T08:00:00Z", "2026-11-11T10:00:00Z"),
            event("overlap", "2026-11-11T09:30:00Z", "2026-11-11T11:00:00Z"),
            event("late", "2026-11-11T17:00:00Z", "2026-11-11T19:00:00Z"),
            AgendaEvent(id: "free", calendarID: "fixture", calendarTitle: "日历", title: "空闲",
                        start: date("2026-11-11T13:00:00Z"), end: date("2026-11-11T14:00:00Z"), busy: false)
        ]
        XCTAssertEqual(AgendaPolicy.freeIntervals(in: work, events: busy), [
            DateInterval(start: date("2026-11-11T11:00:00Z"), end: date("2026-11-11T17:00:00Z"))
        ])
    }

    func testMenuEventUsesLeadTimeAndHidesAfterStart() {
        let event = AgendaEvent(id: "meeting", calendarID: "fixture", calendarTitle: "日历", title: "会议",
                                start: date("2026-11-11T10:00:00Z"), end: date("2026-11-11T11:00:00Z"),
                                meetingURL: URL(string: "https://meet.google.com/abc-defg-hij"))
        let nonMeeting = self.event("other", "2026-11-11T09:55:00Z", "2026-11-11T10:30:00Z")
        let events = [nonMeeting, event]
        let now = date("2026-11-11T10:08:00Z")
        XCTAssertEqual(AgendaPolicy.nearStart(events, now: now, minutes: 10).map(\.id), [event.id])
        XCTAssertTrue(AgendaPolicy.nearStart(events, now: now, minutes: 0).isEmpty)
        let early = date("2026-11-11T08:00:00Z")
        XCTAssertEqual(AgendaPolicy.menuEvent(events, now: early, timing: .upcoming,
                                              hideAfterMinutes: 0, meetingsOnly: true)?.id, event.id)
        XCTAssertNil(AgendaPolicy.menuEvent(events, now: early, timing: .never, hideAfterMinutes: 0, meetingsOnly: false))
        XCTAssertNil(AgendaPolicy.menuEvent(events, now: date("2026-11-11T09:44:00Z"),
                                            timing: .fifteenMinutes, hideAfterMinutes: 5, meetingsOnly: true))
        XCTAssertEqual(AgendaPolicy.menuEvent(events, now: date("2026-11-11T09:45:00Z"),
                                              timing: .fifteenMinutes, hideAfterMinutes: 5, meetingsOnly: true)?.id, event.id)
        XCTAssertNil(AgendaPolicy.menuEvent(events, now: date("2026-11-11T10:05:00Z"),
                                            timing: .fifteenMinutes, hideAfterMinutes: 5, meetingsOnly: true))
    }

    func testMeetingLinksSupportNativeAndRegionalProviders() throws {
        for link in [
            "https://us02web.zoom.us/j/12345",
            "https://app.slack.com/huddle/T123/C456",
            "https://meet.jit.si/ExampleRoom",
            "https://teams.cloud.microsoft/meet/123",
            "https://chime.aws/1234567890",
            "https://whereby.com/example",
            "https://riverside.fm/studio/example",
            "https://streamyard.com/example",
            "https://meeting.tencent.com/dm/example",
            "https://vc.feishu.cn/j/123",
            "facetime:alice@example.com"
        ] {
            XCTAssertTrue(AgendaMeetingLink.matches(try XCTUnwrap(URL(string: link))), link)
        }
    }

    func testMeetingLinksRejectLookalikesAndNonMeetingSlackLinks() throws {
        for link in [
            "https://zoom.us.example.com/j/12345",
            "https://fakezoom.us/j/12345",
            "https://alice@meet.google.com/abc-defg-hij",
            "http://meet.jit.si/ExampleRoom",
            "https://app.slack.com/archives/C456",
            "https://chime.aws/",
            "facetime:",
            "file:///tmp/meet.jit.si"
        ] {
            XCTAssertFalse(AgendaMeetingLink.matches(try XCTUnwrap(URL(string: link))), link)
        }
    }

}
