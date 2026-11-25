import XCTest
@testable import KeylaneCore
final class CostBoundedCacheTests: XCTestCase {
    func testLRUEvictsWithinBothBoundsAndPreservesBorrowedValue() {
        let cache = CostBoundedCache<String, NSString>(bytes: 10, count: 2)
        cache.setObject("a", forKey: "a", cost: 4); cache.setObject("b", forKey: "b", cost: 4)
        let borrowed = cache.object(forKey: "a")
        cache.setObject("c", forKey: "c", cost: 5)
        XCTAssertEqual(cache.cost, 9); XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.object(forKey: "b")); XCTAssertEqual(borrowed, "a")
        cache.setObject("oversize", forKey: "a", cost: 11)
        XCTAssertNil(cache.object(forKey: "a")); XCTAssertEqual(cache.cost, 5)
    }
    func testBackgroundBudgetRejectsLateWorkersAndReenableWorks() {
        let cache = CostBoundedCache<Int, String>(bytes: 100, count: 4)
        cache.setObject("visible", forKey: 0, cost: 30)
        cache.setLimits(bytes: 0, count: 4)
        for i in 0..<100 { cache.setObject("late", forKey: i, cost: 20) }
        XCTAssertEqual(cache.cost, 0); XCTAssertEqual(cache.count, 0)
        cache.setLimits(bytes: 50, count: 1); cache.setObject("again", forKey: 1, cost: 20)
        XCTAssertEqual(cache.object(forKey: 1), "again")
    }
    func testValueDestructionRunsOutsideTheLockAndCostsCannotOverflow() {
        final class Value { let done: () -> Void; init(_ done: @escaping () -> Void) { self.done = done }; deinit { done() } }
        let cache = CostBoundedCache<Int, Value>(bytes: Int.max, count: 2)
        var released = 0
        cache.setObject(Value { _ = cache.count; released += 1 }, forKey: 1, cost: Int.max)
        cache.setObject(Value { _ = cache.count; released += 1 }, forKey: 2, cost: Int.max)
        XCTAssertEqual(released, 1); XCTAssertEqual(cache.cost, Int.max)
        cache.removeAllObjects(); XCTAssertEqual(released, 2)
    }
    func testConcurrentWorkersCannotRefillDisabledCache() {
        let cache = CostBoundedCache<Int, String>(bytes: 4096, count: 128)
        let group = DispatchGroup()
        for worker in 0..<4 {
            group.enter()
            DispatchQueue.global().async {
                for i in 0..<2000 {
                    cache.setObject("data", forKey: worker * 2000 + i, cost: 20)
                    _ = cache.object(forKey: i)
                }
                group.leave()
            }
        }
        cache.setLimits(bytes: 0, count: 128)
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(cache.cost, 0); XCTAssertEqual(cache.count, 0)
    }

}
