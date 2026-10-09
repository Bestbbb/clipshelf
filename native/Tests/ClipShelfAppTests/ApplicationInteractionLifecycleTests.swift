import AppKit
import XCTest
@testable import ClipShelf

private final class DeferredSpaceNotificationCenter: NotificationCenter, @unchecked Sendable {
    private(set) var callbacks: [@Sendable (Notification) -> Void] = []
    private(set) var removedTokens: [NSObjectProtocol] = []

    override func addObserver(forName name: NSNotification.Name?, object obj: Any?,
                              queue: OperationQueue?,
                              using block: @escaping @Sendable (Notification) -> Void) -> NSObjectProtocol {
        callbacks.append(block)
        return NSObject()
    }

    override func removeObserver(_ observer: Any) {
        if let token = observer as? NSObjectProtocol { removedTokens.append(token) }
    }
}

@MainActor
final class ApplicationInteractionLifecycleTests: XCTestCase {
    @MainActor private final class Harness {
        var allowed = true
        var effects: [String] = []
        var onCancelPaste: (() -> Void)?
        lazy var lifecycle = ApplicationInteractionLifecycle(
            allowsInteraction: { [unowned self] in allowed },
            cancelPendingPaste: { [unowned self] in effects.append("cancelPaste"); onCancelPaste?() },
            cancelSuggestions: { [unowned self] in effects.append("cancelSuggestions") },
            hideHistory: { [unowned self] in effects.append("hideHistory") },
            hideStack: { [unowned self] in effects.append("hideStack") })
    }

    private let invalidation = ["cancelPaste", "cancelSuggestions", "hideHistory", "hideStack"]

    func testInvocationCancelsPendingWorkBeforeShowingAndReadsCurrentPermission() {
        let h = Harness()
        XCTAssertTrue(h.lifecycle.isAllowed)
        h.lifecycle.prepareForInvocation { h.effects.append("show") }
        XCTAssertEqual(h.effects, ["cancelPaste", "cancelSuggestions", "show"])
        h.allowed = false
        XCTAssertFalse(h.lifecycle.isAllowed)
    }

    func testForbiddenInvocationDoesNotShowOrRunPreparationEffects() {
        let h = Harness(); h.allowed = false
        h.lifecycle.prepareForInvocation { XCTFail("A suspended or terminating app must not show") }
        XCTAssertTrue(h.effects.isEmpty)
    }

    func testCancellationReenteringSuspensionPreventsShow() {
        let h = Harness()
        h.onCancelPaste = { h.allowed = false }
        h.lifecycle.prepareForInvocation { XCTFail("Cancellation changed interaction permission") }
        XCTAssertEqual(h.effects, ["cancelPaste", "cancelSuggestions"])
        h.onCancelPaste = nil
    }

    func testInvalidationStillCancelsAndHidesWhileInteractionIsForbidden() {
        let h = Harness(); h.allowed = false
        h.lifecycle.invalidateContext()
        XCTAssertEqual(h.effects, invalidation)
    }

    func testSpaceNotificationWithoutPIDOrUserInfoInvalidatesCurrentContext() {
        let h = Harness(), center = NotificationCenter()
        h.lifecycle.observeSpaces(in: center)
        defer { h.lifecycle.stopObserving() }
        // A Space change need not change the frontmost application or provide a PID.
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertEqual(h.effects, invalidation)
    }

    func testRepeatedObservationDeliversOnlyOnce() {
        let h = Harness(), center = NotificationCenter()
        h.lifecycle.observeSpaces(in: center)
        h.lifecycle.observeSpaces(in: center)
        defer { h.lifecycle.stopObserving() }
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertEqual(h.effects, invalidation)
    }

    func testStopRemovesObserverAndReobservationUsesOnlyNewCenter() {
        let h = Harness(), first = NotificationCenter(), second = NotificationCenter()
        h.lifecycle.observeSpaces(in: first)
        h.lifecycle.stopObserving()
        first.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertTrue(h.effects.isEmpty)
        h.lifecycle.observeSpaces(in: first)
        h.lifecycle.observeSpaces(in: second)
        defer { h.lifecycle.stopObserving() }
        first.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertTrue(h.effects.isEmpty)
        second.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertEqual(h.effects, invalidation)
    }

    func testAlreadyQueuedCallbackCannotInvalidateAfterStopOrReplacement() throws {
        let h = Harness(), center = DeferredSpaceNotificationCenter()
        h.lifecycle.observeSpaces(in: center)
        let oldDelivery = try XCTUnwrap(center.callbacks.first)
        let notification = Notification(name: NSWorkspace.activeSpaceDidChangeNotification)
        h.lifecycle.stopObserving()
        oldDelivery(notification)
        XCTAssertTrue(h.effects.isEmpty)
        h.lifecycle.observeSpaces(in: center)
        oldDelivery(notification)
        XCTAssertTrue(h.effects.isEmpty)
        try XCTUnwrap(center.callbacks.last)(notification)
        XCTAssertEqual(h.effects, invalidation)
        h.lifecycle.stopObserving()
        XCTAssertEqual(center.removedTokens.count, 2)
    }
}
