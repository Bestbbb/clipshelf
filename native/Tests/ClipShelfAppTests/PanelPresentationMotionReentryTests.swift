import AppKit
import XCTest
@testable import ClipShelf

@MainActor private final class ReentryMotionWindow: NSPanel {
    private var simulatedVisible = false
    var afterOrderOut: (() -> Void)?
    var afterSetOrigin: (() -> Void)?
    override var isVisible: Bool { simulatedVisible }
    override func makeKeyAndOrderFront(_ sender: Any?) { simulatedVisible = true }
    override func orderOut(_ sender: Any?) {
        simulatedVisible = false
        let callback = afterOrderOut; afterOrderOut = nil
        callback?()
    }
    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(point)
        let callback = afterSetOrigin; afterSetOrigin = nil
        callback?()
    }
}

@MainActor private final class ReentryMotionAnimation: PanelPresentationAnimation {
    let progress: (CGFloat) -> Void
    let completion: () -> Void
    init(progress: @escaping (CGFloat) -> Void, completion: @escaping () -> Void) {
        self.progress = progress; self.completion = completion
    }
    func start() {}
    func cancel() {}
}

@MainActor final class PanelPresentationMotionReentryTests: XCTestCase {
    func testOrderOutReentryCannotNormalizeOverNewPresentation() throws {
        var animations: [ReentryMotionAnimation] = []
        let motion = PanelPresentationMotion(reduceMotion: { false }, notificationCenter: NotificationCenter(),
            makeAnimation: { _, progress, completion in
                let animation = ReentryMotionAnimation(progress: progress, completion: completion)
                animations.append(animation); return animation
            })
        let window = ReentryMotionWindow(contentRect: NSRect(x: 40, y: 80, width: 720, height: 360),
            styleMask: .borderless, backing: .buffered, defer: false)
        defer { motion.hide(window: window) }
        motion.present(window: window)
        let old = try XCTUnwrap(animations.first)
        old.progress(0.4)
        let next = NSRect(x: 900, y: 200, width: 840, height: 410)
        window.afterOrderOut = {
            window.setFrame(next, display: false)
            motion.present(window: window)
        }
        motion.hide(window: window)
        XCTAssertEqual(animations.count, 2)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(motion.isAnimating)
        XCTAssertEqual(window.frame, next.offsetBy(dx: 0, dy: -18))
        XCTAssertEqual(window.alphaValue, 0)
        old.progress(0.9); old.completion()
        XCTAssertEqual(window.frame, next.offsetBy(dx: 0, dy: -18))
        XCTAssertEqual(window.alphaValue, 0)
        animations[1].completion()
        XCTAssertEqual(window.frame, next)
        XCTAssertEqual(window.alphaValue, 1)
    }

    func testOriginCallbackDuringFinishOrCompletionCannotOverwriteNewEntranceAlpha() throws {
        for naturalCompletion in [false, true] {
            var animations: [ReentryMotionAnimation] = []
            let motion = PanelPresentationMotion(reduceMotion: { false }, notificationCenter: NotificationCenter(),
                makeAnimation: { _, progress, completion in
                    let animation = ReentryMotionAnimation(progress: progress, completion: completion)
                    animations.append(animation); return animation
                })
            let window = ReentryMotionWindow(contentRect: NSRect(x: 40, y: 80, width: 720, height: 360),
                styleMask: .borderless, backing: .buffered, defer: false)
            defer { motion.hide(window: window) }
            motion.present(window: window)
            let old = try XCTUnwrap(animations.first)
            old.progress(0.3)
            let next = NSRect(x: 1000, y: 250, width: 900, height: 430)
            window.afterSetOrigin = {
                window.orderOut(nil)
                window.setFrame(next, display: false)
                motion.present(window: window)
            }
            if naturalCompletion { old.completion() } else { motion.finish() }
            XCTAssertEqual(animations.count, 2)
            XCTAssertTrue(window.isVisible)
            XCTAssertTrue(motion.isAnimating)
            XCTAssertEqual(window.frame, next.offsetBy(dx: 0, dy: -18))
            XCTAssertEqual(window.alphaValue, 0)
            old.progress(0.8); old.completion()
            XCTAssertEqual(window.frame, next.offsetBy(dx: 0, dy: -18))
            XCTAssertEqual(window.alphaValue, 0)
        }
    }
}
