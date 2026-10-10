import AppKit
import XCTest
@testable import ClipShelf

final class PasteEventTests: XCTestCase {
    @MainActor func testNormalPasteReleasesSyntheticCommandWithoutPosting() throws {
        let events = try XCTUnwrap(PasteSystemEnvironment.commandVEvents(restoring: []))
        XCTAssertEqual(events.down.type, .keyDown)
        XCTAssertEqual(events.up.type, .keyUp)
        XCTAssertTrue(events.down.flags.contains(.maskCommand))
        XCTAssertFalse(events.up.flags.contains(.maskCommand), "A following paste must not wait for our own Command flag")
        for event in [events.down, events.up] {
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 9)
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), StackKeyMonitor.syntheticEventTag)
            let sourceID = event.getIntegerValueField(.eventSourceStateID)
            XCTAssertNotEqual(sourceID, Int64(CGEventSourceStateID.hidSystemState.rawValue))
            XCTAssertNotEqual(sourceID, Int64(CGEventSourceStateID.combinedSessionState.rawValue))
        }
        XCTAssertEqual(events.down.getIntegerValueField(.eventSourceStateID), events.up.getIntegerValueField(.eventSourceStateID))
    }

    @MainActor func testStackPreservesRealHeldCommandAndCapsLock() throws {
        for flags: CGEventFlags in [.maskCommand, .maskAlphaShift, [.maskCommand, .maskAlphaShift]] {
            let events = try XCTUnwrap(PasteSystemEnvironment.commandVEvents(restoring: flags))
            XCTAssertEqual(events.up.flags, flags)
            XCTAssertEqual(events.down.flags, flags.union(.maskCommand))
        }
    }
}
