import XCTest
@testable import KeylaneCore

final class LatestWorkQueueTests: XCTestCase {
    func testBlockedReaderRetainsOnlyLatestPendingWork() {
        let queue = DispatchQueue(label: "test.latest")
        let mailbox = LatestWorkQueue(queue: queue)
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let lock = NSLock(); var published: [Int] = []
        mailbox.submit { token in
            started.signal(); release.wait()
            if !token.isCancelled { lock.lock(); published.append(-1); lock.unlock() }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 10), .success)
        for i in 0..<5000 {
            mailbox.submit { token in
                if !token.isCancelled { lock.lock(); published.append(i); lock.unlock() }
                done.signal()
            }
        }
        XCTAssertEqual(mailbox.diagnostics.pending, 1)
        XCTAssertEqual(mailbox.diagnostics.replaced, 4999)
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
        queue.sync {}
        lock.lock(); let result = published; lock.unlock()
        XCTAssertEqual(result, [4999])
        XCTAssertEqual(mailbox.diagnostics.executed, 2)
        XCTAssertEqual(mailbox.diagnostics.active, 0)
    }

    func testRefreshPreservesActiveResultAndYieldsToOtherReaderWork() {
        let queue = DispatchQueue(label: "test.fairness")
        let mailbox = LatestWorkQueue(queue: queue)
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let lock = NSLock(); var events: [String] = []
        func record(_ value: String) { lock.lock(); events.append(value); lock.unlock() }
        mailbox.submit { token in started.signal(); release.wait(); if !token.isCancelled { record("active") } }
        XCTAssertEqual(started.wait(timeout: .now() + 10), .success)
        mailbox.submit(cancelActive: false) { _ in record("replaced") }
        mailbox.submit(cancelActive: false) { _ in record("latest"); done.signal() }
        queue.async { record("auxiliary") }
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
        queue.sync {}
        lock.lock(); let result = events; lock.unlock()
        XCTAssertEqual(result, ["active", "auxiliary", "latest"])
    }

    func testCancelDropsPendingWorkAndRevokesActiveWork() {
        let queue = DispatchQueue(label: "test.cancel")
        let mailbox = LatestWorkQueue(queue: queue)
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        mailbox.submit { token in started.signal(); release.wait(); XCTAssertTrue(token.isCancelled) }
        XCTAssertEqual(started.wait(timeout: .now() + 10), .success)
        mailbox.submit { _ in XCTFail("Cancelled pending task must not execute") }
        mailbox.cancel()
        release.signal(); queue.sync {}
        XCTAssertEqual(mailbox.diagnostics.pending, 0)
        XCTAssertEqual(mailbox.diagnostics.executed, 1)
        let done = DispatchSemaphore(value: 0)
        mailbox.submit { _ in done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
    }
    func testReplacingWorkReleasesCapturedResourcesOutsideTheStateLock() {
        final class Resource {
            let release: () -> Void
            init(_ release: @escaping () -> Void) { self.release = release }
            deinit { release() }
        }
        let queue = DispatchQueue(label: "test.release")
        let mailbox = LatestWorkQueue(queue: queue)
        let blocked = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        queue.async { blocked.signal(); release.wait() }
        XCTAssertEqual(blocked.wait(timeout: .now() + 10), .success)
        var resource: Resource? = Resource { _ = mailbox.diagnostics; released.signal() }
        mailbox.submit { [captured = resource!] _ in withExtendedLifetime(captured) {} }
        resource = nil
        DispatchQueue.global().async { mailbox.submit { _ in } }
        XCTAssertEqual(released.wait(timeout: .now() + 10), .success)
        mailbox.cancel(); release.signal()
    }

}
