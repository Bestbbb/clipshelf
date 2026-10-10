import AppKit
import XCTest
@testable import ClipShelf

final class PasteClickShieldTests: XCTestCase {
    @MainActor func testOnlyOriginalClickToleranceAreaIsCovered() throws {
        let frame = try XCTUnwrap(PasteClickShield.protectedFrame(at: NSPoint(x: 200, y: 400)))
        XCTAssertTrue(frame.contains(NSPoint(x: 200, y: 400)))
        XCTAssertTrue(frame.contains(NSPoint(x: 204, y: 396)))
        XCTAssertFalse(frame.contains(NSPoint(x: 215, y: 400)))
        XCTAssertNil(PasteClickShield.protectedFrame(at: NSPoint(x: CGFloat.infinity, y: 400)))
    }

    @MainActor func testDelayedCardResolutionDoesNotExtendTheOriginalDoubleClickInterval() throws {
        XCTAssertEqual(try XCTUnwrap(PasteClickShield.remainingDuration(eventTime: 100, now: 100.2, interval: 0.5)),
                       0.3, accuracy: 0.0001)
        XCTAssertNil(PasteClickShield.remainingDuration(eventTime: 100, now: 100.5, interval: 0.5))
        XCTAssertNil(PasteClickShield.remainingDuration(eventTime: 100, now: 101, interval: 0.5))
        XCTAssertNil(PasteClickShield.remainingDuration(eventTime: .nan, now: 100, interval: 0.5))
        XCTAssertNil(PasteClickShield.remainingDuration(eventTime: 101, now: 100, interval: 0.5))
    }
}
