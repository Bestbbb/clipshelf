import AppKit
import XCTest
@testable import ClipShelf

@MainActor final class PanelNativeEntranceAnimationTests: XCTestCase {
    func testNativeAnimationCompletesAsynchronouslyAndCancelledEntranceStaysHidden() async throws {
        let motion = PanelPresentationMotion(reduceMotion: { false }, notificationCenter: NotificationCenter())
        let window = UnshownTestPanel(contentRect: NSRect(x: 40, y: 80, width: 720, height: 360),
                                      styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        let final = window.frame
        defer { motion.hide(window: window) }

        motion.present(window: window)
        XCTAssertTrue(motion.isAnimating, "The native driver must start without blocking until completion.")
        XCTAssertTrue(window.isVisible)

        // Yield the main actor so NSAnimation's real run-loop driver can advance.
        // Five seconds is a completion grace period, not an animation-speed assertion.
        let deadline = Date().addingTimeInterval(5)
        while motion.isAnimating, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(motion.isAnimating, "The native driver did not deliver its completion callback.")
        XCTAssertEqual(window.frame, final)
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertTrue(window.isVisible)

        motion.hide(window: window)
        motion.present(window: window)
        XCTAssertTrue(motion.isAnimating)
        // Cancel while this second entrance is active, before yielding to its next tick.
        motion.hide(window: window)
        XCTAssertFalse(motion.isAnimating)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(window.frame, final)
        XCTAssertEqual(window.alphaValue, 1)

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(motion.isAnimating)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(window.frame, final)
        XCTAssertEqual(window.alphaValue, 1)
    }
}
