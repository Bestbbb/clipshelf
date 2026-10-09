import AppKit
import ClipShelfCore
@testable import ClipShelf
import XCTest

@MainActor private final class StackVisibilityFixture: NSPanel {
    var logicallyVisible = true
    override var isVisible: Bool { logicallyVisible }
    override func orderOut(_ sender: Any?) { logicallyVisible = false }
    override func orderFrontRegardless() { XCTFail("A suspended Stack must never present a window") }
}

@MainActor final class StackKeyMonitorTests: XCTestCase {
    func testPreparationCapturesTargetBeforeDeliveryRatherThanReadingTheNewTarget() {
        var scheduled: [@MainActor () -> Void] = []
        var target = "A", preparations = 0, delivered: [String] = []
        let monitor = StackKeyMonitor(schedule: { scheduled.append($0) })
        monitor.shouldHandlePaste = { true }
        monitor.preparePaste = {
            preparations += 1
            let capturedTarget = target
            return { delivered.append(capturedTarget) }
        }
        XCTAssertTrue(monitor.handleKeyEvent(type: .keyDown, keyCode: 9, flags: .maskCommand))
        XCTAssertEqual(preparations, 1); XCTAssertTrue(delivered.isEmpty)
        target = "B"
        scheduled.removeFirst()()
        XCTAssertEqual(delivered, ["A"]); XCTAssertEqual(preparations, 1)
        XCTAssertTrue(monitor.handleKeyEvent(type: .keyUp, keyCode: 9, flags: []))
        XCTAssertTrue(monitor.handleKeyEvent(type: .keyDown, keyCode: 9, flags: .maskCommand))
        scheduled.removeFirst()()
        XCTAssertEqual(delivered, ["A", "B"])
    }

    func testDeclinedPreparationPassesTheWholeGestureAndNeverAdoptsItsRepeat() {
        var scheduled: [@MainActor () -> Void] = [], preparations = 0
        let monitor = StackKeyMonitor(schedule: { scheduled.append($0) })
        monitor.shouldHandlePaste = { true }
        monitor.preparePaste = { preparations += 1; return nil }
        XCTAssertFalse(monitor.handleKeyEvent(type: .keyDown, keyCode: 9, flags: .maskCommand))
        monitor.preparePaste = { preparations += 1; return {} }
        XCTAssertFalse(monitor.handleKeyEvent(type: .keyDown, keyCode: 9, flags: .maskCommand, isRepeat: true))
        XCTAssertFalse(monitor.handleKeyEvent(type: .keyUp, keyCode: 9, flags: []))
        XCTAssertEqual(preparations, 1); XCTAssertTrue(scheduled.isEmpty)
        XCTAssertTrue(monitor.handleKeyEvent(type: .keyDown, keyCode: 9, flags: .maskCommand))
        XCTAssertEqual(preparations, 2); XCTAssertEqual(scheduled.count, 1)
    }

    func testInvalidatingPreparedActionDrainsTheOwnedPressWithoutDeliveringIt() {
        var scheduled: [@MainActor () -> Void] = [], calls = 0, available = true
        let monitor = StackKeyMonitor(schedule: { scheduled.append($0) })
        monitor.shouldHandlePaste = { available }; monitor.preparePaste = { { calls += 1 } }
        XCTAssertTrue(monitor.handleKeyEvent(type: .keyDown, keyCode: 9, flags: .maskCommand))
        available = false; monitor.stopAfterCurrentPress(); available = true
        scheduled.removeFirst()()
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(monitor.handleKeyEvent(type: .keyDown, keyCode: 9, flags: .maskCommand, isRepeat: true))
        XCTAssertTrue(monitor.handleKeyEvent(type: .keyUp, keyCode: 9, flags: []))
        XCTAssertTrue(monitor.handleKeyEvent(type: .keyDown, keyCode: 9, flags: .maskCommand))
        scheduled.removeFirst()()
        XCTAssertEqual(calls, 1)
    }

    func testRapidPhysicalGesturesDriveSerialQueueAndFinalHeldPressCannotRepeatLastItem() {
        var handoffs: [@MainActor () -> Void] = []
        let stack = StackCoordinator(scheduleHandoff: { delay, action in
            XCTAssertEqual(delay, StackCoordinator.clipboardHandoffInterval)
            handoffs.append(action)
        })
        stack.activate()
        ["A", "B"].forEach { stack.append(ClipboardRecord(text: $0)) }
        var scheduled: [@MainActor () -> Void] = []
        var sent: [(String, (PasteCoordinator.Outcome) -> Void)] = []
        let monitor = StackKeyMonitor(schedule: { scheduled.append($0) })
        monitor.shouldHandlePaste = { stack.peek() != nil }
        monitor.preparePaste = { { stack.requestPaste { request, done in sent.append((request.record.text, done)) } } }
        stack.onChange = { if stack.peek() == nil { monitor.stopAfterCurrentPress() } }
        XCTAssertTrue(monitor.handleKeyEvent(type: .keyDown, keyCode: 9, flags: .maskCommand))
        XCTAssertTrue(monitor.handleKeyEvent(type: .keyUp, keyCode: 9, flags: .maskCommand))
        XCTAssertTrue(monitor.handleKeyEvent(type: .keyDown, keyCode: 9, flags: .maskCommand))
        scheduled.forEach { $0() }
        XCTAssertEqual(sent.map { $0.0 }, ["A"])
        sent[0].1(.dispatched)
        XCTAssertEqual(sent.map { $0.0 }, ["A"])
        XCTAssertEqual(handoffs.count, 1)
        handoffs.removeFirst()()
        XCTAssertEqual(sent.map { $0.0 }, ["A", "B"])
        sent[1].1(.dispatched)
        XCTAssertTrue(stack.queue.isEmpty)
        XCTAssertTrue(monitor.handleKeyEvent(type: .keyDown, keyCode: 9, flags: .maskCommand, isRepeat: true))
        XCTAssertTrue(monitor.handleKeyEvent(type: .keyUp, keyCode: 9, flags: []))
        XCTAssertFalse(monitor.handleKeyEvent(type: .keyDown, keyCode: 9, flags: .maskCommand))
        XCTAssertEqual(sent.count, 2)
    }

    func testPanelPresentationGateHidesExistingWindowAndBlocksLaterQueueChanges() throws {
        let controller = StackPanelController(), stack = StackCoordinator()
        let fixture = StackVisibilityFixture(contentRect: NSRect(x: 0, y: 0, width: 330, height: 310),
                                             styleMask: .borderless, backing: .buffered, defer: false)
        fixture.contentView = controller.window?.contentView; controller.window = fixture
        controller.isPresentationAllowed = { false }
        stack.activate(); stack.append(ClipboardRecord(text: "retained while suspended"))
        controller.update(stack)
        XCTAssertFalse(fixture.isVisible)
        stack.append(ClipboardRecord(text: "another occurrence")); controller.update(stack)
        XCTAssertFalse(fixture.isVisible); XCTAssertEqual(stack.queue.count, 2)
        fixture.logicallyVisible = true; controller.suspend()
        XCTAssertFalse(fixture.isVisible); XCTAssertEqual(stack.queue.count, 2)
    }

    func testDistinctPressesQueueCallbacksWhileAutoRepeatProducesOnlyOneAction() {
        var scheduled: [@MainActor () -> Void] = [], calls = 0
        let monitor = StackKeyMonitor(schedule: { scheduled.append($0) })
        monitor.shouldHandlePaste = { true }; monitor.preparePaste = { { calls += 1 } }
        XCTAssertTrue(monitor.handleKeyEvent(type: .keyDown, keyCode: 9, flags: .maskCommand))
        for _ in 0..<10 { XCTAssertTrue(monitor.handleKeyEvent(type: .keyDown, keyCode: 9, flags: .maskCommand, isRepeat: true)) }
        XCTAssertTrue(monitor.handleKeyEvent(type: .keyUp, keyCode: 9, flags: .maskCommand))
        XCTAssertTrue(monitor.handleKeyEvent(type: .keyDown, keyCode: 9, flags: .maskCommand))
        XCTAssertTrue(monitor.handleKeyEvent(type: .keyUp, keyCode: 9, flags: []))
        XCTAssertEqual(scheduled.count, 2)
        scheduled.forEach { $0() }; XCTAssertEqual(calls, 2)
    }

    func testOwnedPressStaysSwallowedWhenQueueEmptiesAndModifiersChange() {
        var scheduled: [@MainActor () -> Void] = [], available = true, calls = 0
        let monitor = StackKeyMonitor(schedule: { scheduled.append($0) })
        monitor.shouldHandlePaste = { available }; monitor.preparePaste = { { calls += 1 } }
        XCTAssertTrue(monitor.handleKeyEvent(type: .keyDown, keyCode: 9, flags: .maskCommand))
        scheduled.removeFirst()(); available = false; monitor.stopAfterCurrentPress()
        for flags: CGEventFlags in [.maskCommand, [], .maskShift] {
            XCTAssertTrue(monitor.handleKeyEvent(type: .keyDown, keyCode: 9, flags: flags, isRepeat: true))
        }
        XCTAssertTrue(monitor.handleKeyEvent(type: .keyUp, keyCode: 9, flags: []))
        XCTAssertFalse(monitor.handleKeyEvent(type: .keyDown, keyCode: 9, flags: .maskCommand))
        XCTAssertEqual(calls, 1)
    }

    func testSyntheticEventsDoNotFinishPhysicalPressAndUnclaimedRepeatPassesThrough() {
        var scheduled: [@MainActor () -> Void] = []
        let monitor = StackKeyMonitor(schedule: { scheduled.append($0) })
        monitor.shouldHandlePaste = { true }; monitor.preparePaste = { {} }
        XCTAssertFalse(monitor.handleKeyEvent(type: .keyDown, keyCode: 9, flags: .maskCommand, isRepeat: true))
        XCTAssertTrue(monitor.handleKeyEvent(type: .keyDown, keyCode: 9, flags: .maskCommand))
        XCTAssertFalse(monitor.handleKeyEvent(type: .keyDown, keyCode: 9, flags: .maskCommand, isSynthetic: true))
        XCTAssertFalse(monitor.handleKeyEvent(type: .keyUp, keyCode: 9, flags: .maskCommand, isSynthetic: true))
        XCTAssertTrue(monitor.handleKeyEvent(type: .keyDown, keyCode: 9, flags: [], isRepeat: true))
        XCTAssertTrue(monitor.handleKeyEvent(type: .keyUp, keyCode: 9, flags: []))
        XCTAssertEqual(scheduled.count, 1)
    }

    func testStopInvalidatesQueuedCallbacksBeforeAnotherSessionUsesTheMonitor() {
        var scheduled: [@MainActor () -> Void] = [], calls = 0
        let monitor = StackKeyMonitor(schedule: { scheduled.append($0) })
        monitor.shouldHandlePaste = { true }; monitor.preparePaste = { { calls += 1 } }
        _ = monitor.handleKeyEvent(type: .keyDown, keyCode: 9, flags: .maskCommand)
        monitor.stop()
        _ = monitor.handleKeyEvent(type: .keyDown, keyCode: 9, flags: .maskCommand)
        scheduled[0](); XCTAssertEqual(calls, 0)
        scheduled[1](); XCTAssertEqual(calls, 1)
    }

    func testLateTapDisabledCallbackCannotStopNewSessionOrReportItsFailure() {
        var scheduled: [@MainActor () -> Void] = [], failures = 0, calls = 0
        let monitor = StackKeyMonitor(schedule: { scheduled.append($0) })
        monitor.shouldHandlePaste = { true }; monitor.preparePaste = { { calls += 1 } }; monitor.onUnavailable = { failures += 1 }
        monitor.handleTapDisabled(); monitor.stop()
        _ = monitor.handleKeyEvent(type: .keyDown, keyCode: 9, flags: .maskCommand)
        scheduled[0](); scheduled[1]()
        XCTAssertEqual(failures, 0); XCTAssertEqual(calls, 1)
        monitor.handleTapDisabled(); scheduled.last?()
        XCTAssertEqual(failures, 1)
    }

    func testPassThroughModifiersAndEligibilityRecheckAvoidUnwantedPaste() {
        var scheduled: [@MainActor () -> Void] = [], available = true, calls = 0
        let monitor = StackKeyMonitor(schedule: { scheduled.append($0) })
        monitor.shouldHandlePaste = { available }; monitor.preparePaste = { { calls += 1 } }
        for flags: CGEventFlags in [[], .maskShift, [.maskCommand, .maskShift], [.maskCommand, .maskAlternate], .maskControl] {
            XCTAssertFalse(monitor.handleKeyEvent(type: .keyDown, keyCode: 9, flags: flags))
        }
        XCTAssertFalse(monitor.handleKeyEvent(type: .keyDown, keyCode: 8, flags: .maskCommand))
        _ = monitor.handleKeyEvent(type: .keyDown, keyCode: 9, flags: .maskCommand)
        available = false; scheduled[0]()
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(monitor.handleKeyEvent(type: .keyUp, keyCode: 9, flags: []))
    }

    func testNewQueueDuringFinishingPressRemainsReadyForTheNextPhysicalGesture() {
        var scheduled: [@MainActor () -> Void] = [], available = true, calls = 0
        let monitor = StackKeyMonitor(schedule: { scheduled.append($0) })
        monitor.shouldHandlePaste = { available }; monitor.preparePaste = { { calls += 1 } }
        _ = monitor.handleKeyEvent(type: .keyDown, keyCode: 9, flags: .maskCommand); scheduled.removeFirst()()
        available = false; monitor.stopAfterCurrentPress(); available = true
        _ = monitor.handleKeyEvent(type: .keyUp, keyCode: 9, flags: [])
        _ = monitor.handleKeyEvent(type: .keyDown, keyCode: 9, flags: .maskCommand); scheduled.removeFirst()()
        XCTAssertEqual(calls, 2)
    }
}
