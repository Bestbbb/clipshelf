import XCTest
@testable import ClipShelf

@MainActor
final class StackPasteGestureCoordinatorTests: XCTestCase {
    @MainActor private final class Harness {
        var available = true
        var foreground: pid_t? = 10
        var capturedTarget: Int? = 10
        var captureCount = 0
        var performed: [Int] = []
        var pendingPredicate: (() -> Bool)?
        var duringCapture: (() -> Void)?
        lazy var coordinator = StackPasteGestureCoordinator<Int>(
            ownProcessIdentifier: 99,
            isAvailable: { [unowned self] in available },
            foregroundPID: { [unowned self] in foreground },
            captureTarget: { [unowned self] in
                captureCount += 1
                duringCapture?()
                return capturedTarget
            },
            targetPID: { pid_t($0) })

        func prepare() -> (() -> Void)? {
            coordinator.prepare { [unowned self] target, isCurrent in
                performed.append(target)
                pendingPredicate = isCurrent
            }
        }
    }

    func testPreparationNeverCapturesTargetAndSuccessfulActionRunsOnlyOnce() throws {
        let h = Harness(), action = try XCTUnwrap(h.prepare())
        XCTAssertEqual(h.captureCount, 0)
        action()
        XCTAssertEqual(h.captureCount, 1)
        XCTAssertEqual(h.performed, [10])
        XCTAssertTrue(try XCTUnwrap(h.pendingPredicate)())
        action()
        XCTAssertEqual(h.captureCount, 1)
        XCTAssertEqual(h.performed, [10])
    }

    func testAnotherForegroundApplicationRejectsDelayedActionBeforeAXCapture() throws {
        let h = Harness(), action = try XCTUnwrap(h.prepare())
        h.foreground = 20
        action()
        XCTAssertEqual(h.captureCount, 0)
        XCTAssertTrue(h.performed.isEmpty)
        h.foreground = 10
        action()
        XCTAssertEqual(h.captureCount, 0, "A rejected physical gesture cannot be replayed later")
    }

    func testLeavingAndReturningToSameApplicationStillInvalidatesOldGesture() throws {
        let h = Harness(), action = try XCTUnwrap(h.prepare())
        h.foreground = 20; h.coordinator.invalidate()
        h.foreground = 10; h.coordinator.invalidate()
        action()
        XCTAssertEqual(h.captureCount, 0)
        XCTAssertTrue(h.performed.isEmpty)
    }

    func testSuspensionRejectsPreparationAndAlreadyPreparedAction() throws {
        let h = Harness(), action = try XCTUnwrap(h.prepare())
        h.available = false
        XCTAssertNil(h.prepare())
        action()
        XCTAssertEqual(h.captureCount, 0)
        XCTAssertTrue(h.performed.isEmpty)
    }

    func testOwnApplicationAndMissingForegroundCannotPrepare() {
        let h = Harness()
        h.foreground = 99
        XCTAssertNil(h.prepare())
        h.foreground = nil
        XCTAssertNil(h.prepare())
        XCTAssertEqual(h.captureCount, 0)
    }

    func testContextChangesDuringCaptureCannotReachPerform() throws {
        for change in 0..<3 {
            let h = Harness(), action = try XCTUnwrap(h.prepare())
            h.duringCapture = {
                switch change {
                case 0: h.foreground = 20
                case 1: h.available = false
                default: h.coordinator.invalidate()
                }
            }
            action()
            h.duringCapture = nil
            XCTAssertEqual(h.captureCount, 1)
            XCTAssertTrue(h.performed.isEmpty)
        }
    }

    func testCapturedTargetMustExistAndMatchGestureApplication() throws {
        for target: Int? in [nil, 20, 99] {
            let h = Harness(), action = try XCTUnwrap(h.prepare())
            h.capturedTarget = target
            action()
            XCTAssertEqual(h.captureCount, 1)
            XCTAssertTrue(h.performed.isEmpty)
        }
    }

    func testQueuedPredicateRechecksAvailabilityForegroundAndGeneration() throws {
        let h = Harness(), action = try XCTUnwrap(h.prepare())
        action()
        let isCurrent = try XCTUnwrap(h.pendingPredicate)
        XCTAssertTrue(isCurrent())
        h.available = false
        XCTAssertFalse(isCurrent())
        h.available = true; h.foreground = 20
        XCTAssertFalse(isCurrent())
        h.foreground = 10
        XCTAssertTrue(isCurrent())
        h.coordinator.invalidate()
        XCTAssertFalse(isCurrent())
    }

    func testLateActionFromInvalidatedGenerationCannotDisplaceNewGesture() throws {
        let h = Harness(), oldAction = try XCTUnwrap(h.prepare())
        h.coordinator.invalidate()
        let newAction = try XCTUnwrap(h.prepare())
        oldAction()
        XCTAssertEqual(h.captureCount, 0)
        newAction()
        XCTAssertEqual(h.performed, [10])
        XCTAssertEqual(h.captureCount, 1)
    }
}
