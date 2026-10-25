import AppKit
import XCTest
@testable import ClipShelf
@testable import ClipShelfCore

private final class IconLoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func increment() { lock.lock(); defer { lock.unlock() }; calls += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return calls }
}

@MainActor final class CardIconCacheTests: XCTestCase {
    func testSlowLookupIsOffMainAndCoalescesPrewarmWithVisibleRequests() async {
        let counter = IconLoadCounter()
        let gate = DispatchSemaphore(value: 0)
        let done = expectation(description: "both visible cards receive the shared lookup")
        done.expectedFulfillmentCount = 2
        let cache = CardIconCache { _ in
            XCTAssertFalse(Thread.isMainThread)
            counter.increment()
            _ = gate.wait(timeout: .now() + 3)
            return CardIconCache.Icon()
        }
        let key = CardIconCache.Key.application("fixture.uninstalled")
        cache.request(key) // prewarm
        var delivered = 0
        for _ in 0..<2 {
            cache.request(key) { _ in
                XCTAssertTrue(Thread.isMainThread)
                delivered += 1
                done.fulfill()
            }
        }
        XCTAssertEqual(delivered, 0, "A cold icon must leave the main thread free while loading.")
        gate.signal()
        await fulfillment(of: [done], timeout: 4)
        XCTAssertEqual(counter.value, 1)
        var cachedMissDelivered = false
        cache.request(key) { icon in cachedMissDelivered = true; XCTAssertNil(icon.image) }
        XCTAssertTrue(cachedMissDelivered, "Missing applications must also be cached.")
        XCTAssertEqual(counter.value, 1)
    }

    func testPendingIconDoesNotKeepDiscardedCardAlive() async {
        let gate = DispatchSemaphore(value: 0)
        let done = expectation(description: "pending lookup drains")
        let cache = CardIconCache { _ in
            _ = gate.wait(timeout: .now() + 3)
            return CardIconCache.Icon()
        }
        weak var releasedCard: ClipboardCardView?
        autoreleasepool {
            let record = ClipboardRecord(text: "Fixture", sourceBundleID: "fixture.slow")
            let card = ClipboardCardView(record: ClipboardCardContent(record), position: 0, iconCache: cache)
            releasedCard = card
        }
        XCTAssertNil(releasedCard)
        cache.request(.application("fixture.slow")) { _ in done.fulfill() }
        gate.signal()
        await fulfillment(of: [done], timeout: 4)
        XCTAssertNil(releasedCard)
    }

    func testApplicationAndFileTypeWithSameIdentifierUseSeparateEntries() async {
        let counter = IconLoadCounter()
        let done = expectation(description: "two distinct icon kinds")
        done.expectedFulfillmentCount = 2
        let cache = CardIconCache { _ in counter.increment(); return CardIconCache.Icon() }
        cache.request(.application("public.pdf")) { _ in done.fulfill() }
        cache.request(.fileType("public.pdf")) { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 4)
        XCTAssertEqual(counter.value, 2)
    }
}
