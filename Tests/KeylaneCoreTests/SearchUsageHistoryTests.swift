import Foundation
import XCTest
import KeylaneCore

final class SearchUsageHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func ranking(_ query: String, history: SearchUsageHistory, aliases: [String: String] = [:],
                         usage: [String: Int] = [:], at date: Date? = nil) -> LauncherSearchRanking {
        LauncherSearchRanking(query: query, aliases: aliases, favorites: [], usage: usage,
                              history: history, now: date ?? now)
    }

    func testRepeatedSelectionsForSameQueryOutrankOverallUse() throws {
        var history = SearchUsageHistory()
        for _ in 0..<3 { history.record(id: "calendar", queryKey: SearchUsageHistory.queryKey(" ＣＡＬ "), at: now) }
        for _ in 0..<10 { history.record(id: "calculator", queryKey: SearchUsageHistory.queryKey("calc"), at: now) }
        let learned = ranking("cal", history: history)
        let calendar = try XCTUnwrap(learned.match(id: "calendar", title: "Calendar"))
        let calculator = try XCTUnwrap(learned.match(id: "calculator", title: "Calculator"))
        XCTAssertTrue(calendar.precedes(calculator))

        let freshQuery = ranking("ca", history: history)
        XCTAssertTrue(try XCTUnwrap(freshQuery.match(id: "calculator", title: "Calculator"))
            .precedes(XCTUnwrap(freshQuery.match(id: "calendar", title: "Calendar"))))
    }

    func testRecencyAndResetSurviveRoundTrip() throws {
        var history = SearchUsageHistory()
        let query = SearchUsageHistory.queryKey("ca")
        let oldDate = now.addingTimeInterval(-60 * 86_400)
        for _ in 0..<6 { history.record(id: "old", queryKey: query, at: oldDate) }
        history.record(id: "recent", queryKey: query, at: now)
        let encoded = try JSONEncoder().encode(history)
        var decoded = try JSONDecoder().decode(SearchUsageHistory.self, from: encoded)
        let ranked = ranking("ca", history: decoded)
        XCTAssertTrue(try XCTUnwrap(ranked.match(id: "recent", title: "Calculator"))
            .precedes(XCTUnwrap(ranked.match(id: "old", title: "Calendar"))))
        decoded.reset(id: "recent")
        let reset = ranking("ca", history: decoded)
        XCTAssertTrue(try XCTUnwrap(reset.match(id: "old", title: "Calendar"))
            .precedes(XCTUnwrap(reset.match(id: "recent", title: "Calculator"))))
    }

    func testAliasesAndTitleRelevancePrecedeLearnedUsage() throws {
        var history = SearchUsageHistory()
        for _ in 0..<32 { history.record(id: "popular", queryKey: SearchUsageHistory.queryKey("calendar"), at: now) }
        let rank = ranking("calendar", history: history, aliases: ["alias": "calendar", "prefix": "calendar tools"])
        let exact = try XCTUnwrap(rank.match(id: "exact", title: "Calendar"))
        let popular = try XCTUnwrap(rank.match(id: "popular", title: "Calendar Utilities"))
        let alias = try XCTUnwrap(rank.match(id: "alias", title: "Agenda"))
        let prefix = try XCTUnwrap(rank.match(id: "prefix", title: "Planner"))
        let keyword = try XCTUnwrap(rank.match(id: "keyword", title: "Events", names: ["Calendar"]))
        XCTAssertTrue(alias.precedes(prefix))
        XCTAssertTrue(prefix.precedes(exact))
        XCTAssertTrue(exact.precedes(popular))
        XCTAssertTrue(popular.precedes(keyword))
        XCTAssertNil(rank.match(id: "popular", title: "Finder"))
    }

    func testLegacyFrequencyOrdersEquivalentMatches() throws {
        let rank = ranking("cal", history: .init(), usage: ["calendar": 4])
        XCTAssertTrue(try XCTUnwrap(rank.match(id: "calendar", title: "Calendar"))
            .precedes(XCTUnwrap(rank.match(id: "calculator", title: "Calculator"))))
    }
}
