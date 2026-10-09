import AppKit
@testable import ClipShelfCore
import XCTest
@testable import ClipShelf

@MainActor
private final class SharingLifecycleGate<Value> {
    var waiting: (() -> Void)?
    private var continuation: CheckedContinuation<Value, Never>?
    func value() async -> Value {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiting?()
        }
    }
    func resolve(_ value: Value) {
        let pending = continuation; continuation = nil
        pending?.resume(returning: value)
    }
}

@MainActor
final class SharingSettingsLifecycleTests: XCTestCase {
    @MainActor private final class Harness {
        let directory: URL
        let suite = "clipshelf-sharing-lifecycle-" + UUID().uuidString
        let preferences: UserDefaults
        let controller: SharingSettingsController
        init(readStates: @escaping @MainActor () async throws -> [SharedBoardState] = { [] },
             availability: @escaping @MainActor () async -> CloudSyncAvailability = { .disabled }) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("sharing-lifecycle-" + UUID().uuidString)
            preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
            let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
            controller = SharingSettingsController(store: store, preferences: preferences,
                                                    readStates: readStates, availability: availability)
            XCTAssertFalse(controller.window?.isVisible ?? true)
        }
        func close() {
            controller.stop()
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
    private func fields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    private func status(_ controller: SharingSettingsController) throws -> NSTextField {
        try XCTUnwrap(controller.window?.contentView.flatMap { fields($0).first })
    }
    private func allText(_ controller: SharingSettingsController) -> String {
        controller.window?.contentView.map { fields($0).map(\.stringValue).joined(separator: "\n") } ?? ""
    }
    private func sharedState() -> SharedBoardState {
        .init(descriptor: .init(boardID: UUID(), accountID: "synthetic", containerIdentifier: "iCloud.synthetic",
                                zoneName: "synthetic", zoneOwnerName: "synthetic", shareRecordName: "synthetic"), access: .owner)
    }

    func testStoppedLateSuccessCannotApplyPreferencesCopyLinkOrOverwriteReplacementStatus() async throws {
        let h = try Harness(); defer { h.close() }
        let status = try status(h.controller), gate = SharingLifecycleGate<Void>()
        let waiting = expectation(description: "old action waiting")
        gate.waiting = { waiting.fulfill() }
        var copies = 0, changes = 0
        h.controller.onCopyLink = { _ in copies += 1 }
        h.controller.onDataChanged = { changes += 1 }
        let old = try XCTUnwrap(h.controller.perform {
            await gate.value()
            return {
                h.preferences.set(true, forKey: "sharingEnabled")
                status.stringValue = "stale success"
                h.controller.onCopyLink?(URL(string: "https://example.invalid/invitation")!)
            }
        })
        await fulfillment(of: [waiting], timeout: 2)
        h.controller.stop()
        let replacement = try XCTUnwrap(h.controller.perform {
            return {
                h.preferences.set(false, forKey: "sharingEnabled")
                status.stringValue = "sharing stopped"
            }
        })
        await replacement.value
        gate.resolve(())
        await old.value
        XCTAssertFalse(h.preferences.bool(forKey: "sharingEnabled"))
        XCTAssertEqual(status.stringValue, "sharing stopped")
        XCTAssertEqual(copies, 0); XCTAssertEqual(changes, 1)
        XCTAssertFalse(h.controller.window?.isVisible ?? true)
    }

    func testStoppedLateFailureCannotReplaceNewOperationResult() async throws {
        let h = try Harness(); defer { h.close() }
        let status = try status(h.controller), gate = SharingLifecycleGate<Void>()
        let waiting = expectation(description: "old failure waiting")
        gate.waiting = { waiting.fulfill() }
        var changes = 0; h.controller.onDataChanged = { changes += 1 }
        let old = try XCTUnwrap(h.controller.perform {
            await gate.value()
            throw SyncError.unavailable("stale network failure")
        })
        await fulfillment(of: [waiting], timeout: 2)
        h.controller.stop()
        let replacement = try XCTUnwrap(h.controller.perform { { status.stringValue = "new result" } })
        await replacement.value
        gate.resolve(())
        await old.value
        XCTAssertEqual(status.stringValue, "new result")
        XCTAssertEqual(changes, 1)
    }

    func testStateReadKeepsOperationBusyAndStopRejectsLateRowsAndCompletion() async throws {
        let gate = SharingLifecycleGate<[SharedBoardState]>()
        let waiting = expectation(description: "state read waiting")
        gate.waiting = { waiting.fulfill() }
        var reads = 0
        let h = try Harness(readStates: {
            reads += 1
            if reads == 1 { return await gate.value() }
            return []
        }); defer { h.close() }
        let status = try status(h.controller)
        var oldCompletion = 0, changes = 0
        h.controller.onDataChanged = { changes += 1 }
        let old = try XCTUnwrap(h.controller.perform { { oldCompletion += 1; status.stringValue = "old state result" } })
        await fulfillment(of: [waiting], timeout: 2)
        XCTAssertNil(h.controller.perform { { XCTFail("A second action must stay blocked during the state read") } })
        XCTAssertEqual(oldCompletion, 0, "UI effects must wait for the state snapshot too")
        h.controller.stop()
        let replacement = try XCTUnwrap(h.controller.perform { { status.stringValue = "closed current generation" } })
        await replacement.value
        let stale = sharedState()
        gate.resolve([stale]); await old.value
        XCTAssertEqual(oldCompletion, 0); XCTAssertEqual(changes, 1)
        XCTAssertEqual(status.stringValue, "closed current generation")
        XCTAssertFalse(allText(h.controller).contains(String(stale.id.uuidString.prefix(8))))
        XCTAssertTrue(allText(h.controller).contains("尚无共享板"))
        XCTAssertTrue(allText(h.controller).contains("文件传输已停止"))
    }

    func testCurrentCompletionAppliesOnlyAfterStateReadAndAllowsNextAction() async throws {
        let gate = SharingLifecycleGate<[SharedBoardState]>()
        let waiting = expectation(description: "current state read waiting")
        gate.waiting = { waiting.fulfill() }
        var reads = 0
        let h = try Harness(readStates: {
            reads += 1
            if reads == 1 { return await gate.value() }
            return []
        }); defer { h.close() }
        let status = try status(h.controller)
        var completed = 0, changes = 0
        h.controller.onDataChanged = { changes += 1 }
        let operation = try XCTUnwrap(h.controller.perform { { completed += 1; status.stringValue = "current complete" } })
        await fulfillment(of: [waiting], timeout: 2)
        XCTAssertEqual(completed, 0); XCTAssertEqual(changes, 0)
        gate.resolve([]); await operation.value
        XCTAssertEqual(completed, 1); XCTAssertEqual(changes, 1)
        XCTAssertEqual(status.stringValue, "current complete")
        let next = try XCTUnwrap(h.controller.perform { { status.stringValue = "next complete" } })
        await next.value
        XCTAssertEqual(status.stringValue, "next complete")
    }

}
