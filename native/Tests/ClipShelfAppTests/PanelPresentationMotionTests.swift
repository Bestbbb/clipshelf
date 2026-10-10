import AppKit
import XCTest
@testable import ClipShelf

@MainActor private final class MotionTestAnimation: PanelPresentationAnimation {
    let duration: TimeInterval
    let progress: (CGFloat) -> Void
    let completion: () -> Void
    var starts = 0
    var cancellations = 0
    var callbacksDuringCancel = false

    init(duration: TimeInterval, progress: @escaping (CGFloat) -> Void, completion: @escaping () -> Void) {
        self.duration = duration
        self.progress = progress
        self.completion = completion
    }

    func start() { starts += 1 }
    func cancel() {
        cancellations += 1
        if callbacksDuringCancel {
            progress(0.9)
            completion()
        }
    }
}

@MainActor private final class MotionTestWindowDelegate: NSObject, NSWindowDelegate {
    var resizeNotifications = 0
    func windowDidResize(_ notification: Notification) { resizeNotifications += 1 }
}

@MainActor private final class MotionTestHarness {
    var reduceMotion = false
    var animations: [MotionTestAnimation] = []
    lazy var motion = PanelPresentationMotion(
        reduceMotion: { [unowned self] in reduceMotion },
        makeAnimation: { [unowned self] duration, progress, completion in
            let animation = MotionTestAnimation(duration: duration, progress: progress, completion: completion)
            animations.append(animation)
            return animation
        })

    func window() -> UnshownTestPanel {
        UnshownTestPanel(contentRect: NSRect(x: 40, y: 80, width: 720, height: 360),
                         styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
    }
}

@MainActor final class PanelPresentationMotionTests: XCTestCase {
    func testPresentationInterpolatesOriginAndAlphaWithoutResizing() throws {
        let h = MotionTestHarness(), window = h.window(), observer = MotionTestWindowDelegate()
        window.delegate = observer
        let final = window.frame
        defer { h.motion.hide(window: window) }

        h.motion.present(window: window)
        let animation = try XCTUnwrap(h.animations.first)
        XCTAssertEqual(h.animations.count, 1)
        XCTAssertEqual(animation.duration, 0.14, accuracy: 0.000001)
        XCTAssertEqual(animation.starts, 1)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(h.motion.isAnimating)
        XCTAssertEqual(window.frame.origin.x, final.origin.x)
        XCTAssertEqual(window.frame.origin.y, final.origin.y - 18)
        XCTAssertEqual(window.frame.size, final.size)
        XCTAssertEqual(window.alphaValue, 0)

        animation.progress(0.5)
        XCTAssertEqual(window.frame.origin.y, final.origin.y - 9, accuracy: 0.000001)
        XCTAssertEqual(window.frame.size, final.size)
        XCTAssertEqual(window.alphaValue, 0.5, accuracy: 0.000001)
        animation.completion()
        XCTAssertEqual(window.frame, final)
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertFalse(h.motion.isAnimating)
        XCTAssertEqual(observer.resizeNotifications, 0)
    }

    func testHideIsImmediateAndRetiresCallbacksBeforeCancel() throws {
        let h = MotionTestHarness(), window = h.window(), final = window.frame
        h.motion.present(window: window)
        let animation = try XCTUnwrap(h.animations.first)
        animation.progress(0.3)
        animation.callbacksDuringCancel = true

        h.motion.hide(window: window)
        XCTAssertEqual(animation.cancellations, 1)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(h.motion.isAnimating)
        XCTAssertEqual(window.frame, final)
        XCTAssertEqual(window.alphaValue, 1)
        animation.progress(0.6)
        animation.completion()
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(h.motion.isAnimating)
        XCTAssertEqual(window.frame, final)
        XCTAssertEqual(window.alphaValue, 1)
    }

    func testLateCallbacksFromHiddenPresentationCannotChangeReopenedPresentation() throws {
        let h = MotionTestHarness(), window = h.window()
        defer { h.motion.hide(window: window) }
        h.motion.present(window: window)
        let old = try XCTUnwrap(h.animations.first)
        old.progress(0.2)
        h.motion.hide(window: window)
        let final = NSRect(x: 900, y: 150, width: 840, height: 410)
        window.setFrame(final, display: false)
        h.motion.present(window: window)
        XCTAssertEqual(h.animations.count, 2)
        let current = try XCTUnwrap(h.animations.last)
        current.progress(0.25)
        let currentFrame = window.frame, currentAlpha = window.alphaValue

        old.progress(0.9)
        old.completion()
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(h.motion.isAnimating)
        XCTAssertEqual(window.frame, currentFrame)
        XCTAssertEqual(window.alphaValue, currentAlpha)
        current.completion()
        XCTAssertEqual(window.frame, final)
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertFalse(h.motion.isAnimating)
    }

    func testReduceMotionVisibleWindowAndDisabledAnimationPresentImmediately() {
        for mode in 0...2 {
            let h = MotionTestHarness(), window = h.window(), final = window.frame
            defer { h.motion.hide(window: window) }
            if mode == 0 { h.reduceMotion = true }
            if mode == 1 { window.makeKeyAndOrderFront(nil) }
            window.alphaValue = 0.25

            h.motion.present(window: window, animated: mode != 2)
            XCTAssertTrue(h.animations.isEmpty, "mode \(mode)")
            XCTAssertTrue(window.isVisible)
            XCTAssertFalse(h.motion.isAnimating)
            XCTAssertEqual(window.frame, final)
            XCTAssertEqual(window.alphaValue, 1)
        }
    }

    func testFinishCancelsAnimationAndKeepsFinalFrameAgainstLateCallbacks() throws {
        let h = MotionTestHarness(), window = h.window(), final = window.frame
        defer { h.motion.hide(window: window) }
        h.motion.present(window: window)
        let animation = try XCTUnwrap(h.animations.first)
        animation.progress(0.25)

        h.motion.finish()
        XCTAssertEqual(animation.cancellations, 1)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(h.motion.isAnimating)
        XCTAssertEqual(window.frame, final)
        XCTAssertEqual(window.alphaValue, 1)
        animation.progress(0.1)
        animation.completion()
        XCTAssertEqual(window.frame, final)
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertFalse(h.motion.isAnimating)
    }

    func testCancelPreservingFrameKeepsUserResizeAndMoveAgainstLateCallbacks() throws {
        let h = MotionTestHarness(), window = h.window()
        defer { h.motion.hide(window: window) }
        h.motion.present(window: window)
        let animation = try XCTUnwrap(h.animations.first)
        animation.progress(0.5)
        let resized = NSRect(x: 250, y: 170, width: 930, height: 510)
        window.setFrame(resized, display: false)
        animation.callbacksDuringCancel = true

        h.motion.cancelPreservingFrame()
        XCTAssertEqual(animation.cancellations, 1)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(h.motion.isAnimating)
        XCTAssertEqual(window.frame, resized)
        XCTAssertEqual(window.alphaValue, 1)
        animation.progress(0.75)
        animation.completion()
        XCTAssertEqual(window.frame, resized)
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertFalse(h.motion.isAnimating)
    }

    func testReduceMotionNotificationFinishesActiveAnimationAndSkipsNextPresentation() throws {
        let center = NotificationCenter()
        var shouldReduce = false
        var animations: [MotionTestAnimation] = []
        let motion = PanelPresentationMotion(reduceMotion: { shouldReduce }, notificationCenter: center,
            makeAnimation: { duration, progress, completion in
                let animation = MotionTestAnimation(duration: duration, progress: progress, completion: completion)
                animations.append(animation)
                return animation
            })
        let window = UnshownTestPanel(contentRect: NSRect(x: 40, y: 80, width: 720, height: 360),
                                     styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        let final = window.frame
        defer { motion.hide(window: window) }
        motion.present(window: window)
        let animation = try XCTUnwrap(animations.first)
        animation.progress(0.4)
        XCTAssertTrue(motion.isAnimating)

        shouldReduce = true
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        XCTAssertEqual(animation.cancellations, 1)
        XCTAssertFalse(motion.isAnimating)
        XCTAssertEqual(window.frame, final)
        XCTAssertEqual(window.alphaValue, 1)
        animation.progress(0.8)
        animation.completion()
        XCTAssertFalse(motion.isAnimating)
        XCTAssertEqual(window.frame, final)
        XCTAssertEqual(window.alphaValue, 1)

        motion.hide(window: window)
        motion.present(window: window)
        XCTAssertEqual(animations.count, 1)
        XCTAssertEqual(animation.cancellations, 1)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(motion.isAnimating)
        XCTAssertEqual(window.frame, final)
        XCTAssertEqual(window.alphaValue, 1)
    }
}
