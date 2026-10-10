import XCTest
@testable import ClipShelf

final class PasteTargetHistoryTests: XCTestCase {
    func testOwnActivationRetainsFocusCapturedWhenExternalAppDeactivated() {
        var history = PasteTargetHistory<String>(ownPID: 1)
        history.activated(2)
        history.deactivated(2) { _ in "window B, field 2, original cursor" }
        history.activated(1)
        XCTAssertEqual(history.resolve(foregroundPID: 1) { _ in "new focus" }, "window B, field 2, original cursor")
    }

    func testExternalForegroundAlwaysUsesFreshFocusInsteadOfRememberedApp() {
        var history = PasteTargetHistory<String>(ownPID: 1)
        history.activated(2)
        history.deactivated(2) { _ in "old" }
        XCTAssertEqual(history.resolve(foregroundPID: 3) { "fresh \($0)" }, "fresh 3")
        XCTAssertNil(history.resolve(foregroundPID: 3) { _ in nil })
    }

    func testLateDeactivationCannotReplaceNewExternalAppAndMissingNotificationCanRecapture() {
        var history = PasteTargetHistory<String>(ownPID: 1)
        history.activated(2)
        history.activated(3)
        history.deactivated(2) { _ in XCTFail("Stale activation order"); return "old" }
        history.activated(1)
        XCTAssertEqual(history.resolve(foregroundPID: 1) { "current \($0)" }, "current 3")
    }

    func testSessionOrSpaceChangeAndMissingForegroundNeverRestoreStaleTarget() {
        var history = PasteTargetHistory<String>(ownPID: 1)
        history.activated(2)
        history.deactivated(2) { _ in "old" }
        XCTAssertNil(history.resolve(foregroundPID: nil) { _ in XCTFail(); return "old" })
        history.clear()
        XCTAssertNil(history.resolve(foregroundPID: 1) { _ in XCTFail(); return "old" })
    }
}
