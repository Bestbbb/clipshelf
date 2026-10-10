import AppKit
import XCTest
@testable import ClipShelf

@MainActor final class PanelNativeEntranceAnimationTests: XCTestCase {
    /// NSAnimation schedules native run-loop work. Yielding a Swift task does not
    /// guarantee that XCTest services that run-loop mode during a large async suite.
    private func pumpMainRunLoop(until deadline: Date, while pending: () -> Bool = { true }) {
        XCTAssertTrue(Thread.isMainThread)
        while pending(), Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.01)))
        }
    }

    func testNativeAnimationCompletesAsynchronouslyAndCancelledEntranceStaysHidden() {
        XCTAssertTrue(Thread.isMainThread)
        let motion = PanelPresentationMotion(reduceMotion: { false }, notificationCenter: NotificationCenter())
        let window = UnshownTestPanel(contentRect: NSRect(x: 40, y: 80, width: 720, height: 360),
                                      styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        let final = window.frame
        defer { motion.hide(window: window) }

        motion.present(window: window)
        XCTAssertTrue(motion.isAnimating, "The native driver must start without blocking until completion.")
        XCTAssertTrue(window.isVisible)

        // Service the mode containing NSAnimation's real common-mode driver.
        // Five seconds is a completion grace period, not an animation-speed assertion.
        pumpMainRunLoop(until: Date().addingTimeInterval(5), while: { motion.isAnimating })
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

        pumpMainRunLoop(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(motion.isAnimating)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(window.frame, final)
        XCTAssertEqual(window.alphaValue, 1)
    }
}
