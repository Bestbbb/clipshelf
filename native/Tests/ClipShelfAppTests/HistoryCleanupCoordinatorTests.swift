import Foundation
import XCTest
@testable import ClipShelf
import ClipShelfCore

@MainActor private final class CleanupFlowHarness {
    let coordinator = HistoryCleanupCoordinator()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-cleanup-flow-\(UUID().uuidString)")
    let preferencesName = "ClipShelf.cleanup-tests.\(UUID().uuidString)"
    let preferences: UserDefaults
    let store: HistoryStore
    let now = Date(timeIntervalSinceReferenceDate: 2_000_000)
    let expired: ClipboardRecord
    let recent: ClipboardRecord
    let pinned: ClipboardRecord
    var prepares: [(HistoryCleanupRequest, (Result<HistoryCleanupPlan, Error>) -> Void)] = []
    var confirmations: [(HistoryCleanupSummary, HistoryCleanupRequest, (Bool) -> Void)] = []
    var commits: [(HistoryCleanupPlan, (Result<HistoryCleanupResult, Error>) -> Void)] = []
    var successes: [(HistoryCleanupResult, HistoryCleanupRequest)] = []
    var failures: [(Error, HistoryCleanupRequest)] = []
    var cancellations: [HistoryCleanupRequest] = []
    var busy: [Bool] = []
    var externalBusy = false
    var confirmationDismissals = 0
    var refreshes = 0

    init() throws {
        preferences = UserDefaults(suiteName: preferencesName)!
        preferences.set(30, forKey: "retentionDays")
        store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let board = try store.createPinboard(name: "Retained fixture")
        expired = try store.create(.init(text: "expired", copiedAt: now.addingTimeInterval(-10 * 86_400)))
        recent = try store.create(.init(text: "recent", copiedAt: now.addingTimeInterval(-86_400)))
        pinned = try store.create(.init(text: "pinned expired", copiedAt: now.addingTimeInterval(-10 * 86_400), pinboardID: board.id))
        coordinator.onPrepare = { [weak self] request, reply in self?.prepares.append((request, reply)) }
        coordinator.onCommit = { [weak self] plan, reply in self?.commits.append((plan, reply)) }
        coordinator.confirm = { [weak self] summary, request, reply in
            self?.confirmations.append((summary, request, reply))
            return { [weak self] in self?.confirmationDismissals += 1; reply(false) }
        }
        coordinator.isExternalMutationBusy = { [weak self] in self?.externalBusy == true }
        coordinator.onBusyChanged = { [weak self] in self?.busy.append($0) }
        coordinator.onSuccess = { [weak self] result, request in
            guard let self else { return }
            self.successes.append((result, request)); self.refreshes += 1
            if case .retention(let days) = request { self.preferences.set(days, forKey: "retentionDays") }
        }
        coordinator.onFailure = { [weak self] error, request in self?.failures.append((error, request)) }
        coordinator.onCancelled = { [weak self] in self?.cancellations.append($0) }
    }
    var retentionDays: Int { preferences.integer(forKey: "retentionDays") }
    func plan(for request: HistoryCleanupRequest) throws -> HistoryCleanupPlan {
        switch request {
        case .clearHistory: return try store.prepareHistoryCleanup()
        case .retention(let days), .automatic(let days):
            return try store.prepareHistoryCleanup(before: now.addingTimeInterval(-Double(days) * 86_400))
        }
    }
    func prepare(_ index: Int? = nil) throws {
        let item = prepares[index ?? (prepares.count - 1)]
        item.1(.success(try plan(for: item.0)))
    }
    func approve(_ index: Int? = nil) { confirmations[index ?? (confirmations.count - 1)].2(true) }
    func commit(_ index: Int? = nil) throws {
        let item = commits[index ?? (commits.count - 1)]
        item.1(Result { try store.commitHistoryCleanup(item.0) })
    }
    func close() {
        _ = coordinator.terminate()
        preferences.removePersistentDomain(forName: preferencesName)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor final class HistoryCleanupCoordinatorTests: XCTestCase {
    private func failure() -> Error { NSError(domain: "cleanup.fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "暂时无法清理"]) }

    func testManualCleanupConfirmsFrozenScopeAndChangesPreferenceOnlyAfterActualCommit() throws {
        let h = try CleanupFlowHarness(); defer { h.close() }
        XCTAssertEqual(h.coordinator.start(.retention(days: 7)), .started)
        XCTAssertTrue(h.coordinator.isBusy); XCTAssertFalse(h.coordinator.isCommitting)
        XCTAssertEqual(h.retentionDays, 30); try h.prepare()
        XCTAssertEqual(h.confirmations[0].0.deletedCount, 1)
        XCTAssertEqual(h.confirmations[0].0.preservedPinnedCount, 1)
        let added = try h.store.create(.init(text: "newly imported old date", copiedAt: h.expired.copiedAt))
        h.approve(); XCTAssertTrue(h.coordinator.isCommitting); XCTAssertEqual(h.retentionDays, 30)
        try h.commit()
        XCTAssertNil(try h.store.item(id: h.expired.id))
        XCTAssertNotNil(try h.store.item(id: added.id), "Confirmation must not expand to later matching entries")
        XCTAssertNotNil(try h.store.item(id: h.recent.id))
        XCTAssertEqual(try h.store.item(id: h.pinned.id)?.isInHistory, false)
        XCTAssertEqual(h.retentionDays, 7); XCTAssertEqual(h.refreshes, 1)
        XCTAssertEqual(h.successes[0].0.deletedIDs, [h.expired.id])
        XCTAssertEqual(h.successes[0].0.preservedReferences.first?.id, h.pinned.id)
        XCTAssertEqual(h.busy, [true, false]); XCTAssertFalse(h.coordinator.isBusy)
    }

    func testPreparationFailurePreservesPreferencesAndRequiresNewRequest() throws {
        let h = try CleanupFlowHarness(); defer { h.close() }
        h.coordinator.start(.retention(days: 7)); h.prepares[0].1(.failure(failure()))
        XCTAssertFalse(h.coordinator.isBusy); XCTAssertEqual(h.retentionDays, 30)
        XCTAssertEqual(h.failures.count, 1); XCTAssertTrue(h.confirmations.isEmpty); XCTAssertTrue(h.commits.isEmpty)
        h.coordinator.resumeDeferred(); XCTAssertEqual(h.prepares.count, 1)
        h.coordinator.start(.retention(days: 7)); try h.prepare()
        XCTAssertEqual(h.prepares.count, 2); XCTAssertEqual(h.confirmations.count, 1)
        XCTAssertTrue(h.commits.isEmpty, "Fresh statistics require a fresh manual decision")
    }

    func testChangedCandidateFailsAtomicallyAndExplicitRetryRequiresAnotherConfirmation() throws {
        let h = try CleanupFlowHarness(); defer { h.close() }
        h.coordinator.start(.clearHistory); try h.prepare()
        var changed = h.expired; changed.text = "edited after confirmation snapshot"
        _ = try h.store.update(record: changed)
        h.approve(); try h.commit()
        XCTAssertEqual(h.failures.count, 1); XCTAssertTrue(h.successes.isEmpty)
        XCTAssertEqual(try h.store.load().count, 3); XCTAssertEqual(h.retentionDays, 30)
        XCTAssertEqual(h.refreshes, 0); XCTAssertFalse(h.coordinator.isBusy)
        h.coordinator.resumeDeferred(); XCTAssertEqual(h.prepares.count, 1)
        h.coordinator.start(.clearHistory); try h.prepare(); XCTAssertEqual(h.confirmations.count, 2)
        XCTAssertEqual(h.commits.count, 1); h.approve(); try h.commit()
        XCTAssertEqual(h.successes.count, 1); XCTAssertEqual(h.successes[0].0.summary.deletedCount, 2)
    }

    func testCancelPreparationAndLateReplyCannotOpenConfirmationOrAffectNewOperation() throws {
        let h = try CleanupFlowHarness(); defer { h.close() }
        h.coordinator.start(.clearHistory)
        let oldReply = h.prepares[0].1, oldPlan = try h.plan(for: .clearHistory)
        XCTAssertTrue(h.coordinator.cancelPending()); XCTAssertEqual(h.cancellations, [.clearHistory])
        h.coordinator.start(.retention(days: 7)); oldReply(.success(oldPlan))
        XCTAssertTrue(h.confirmations.isEmpty); XCTAssertTrue(h.commits.isEmpty)
        try h.prepare(); XCTAssertEqual(h.confirmations[0].1, .retention(days: 7))
    }

    func testCancelConfirmationDismissesOnceAndLateApprovalCannotCommit() throws {
        let h = try CleanupFlowHarness(); defer { h.close() }
        h.coordinator.start(.clearHistory); try h.prepare()
        let reply = h.confirmations[0].2
        XCTAssertTrue(h.coordinator.cancelPending()); reply(true); reply(false)
        XCTAssertEqual(h.confirmationDismissals, 1); XCTAssertEqual(h.cancellations, [.clearHistory])
        XCTAssertTrue(h.commits.isEmpty); XCTAssertEqual(h.retentionDays, 30); XCTAssertFalse(h.coordinator.isBusy)
    }

    func testDuplicateRequestsAndRepliesCommitAndReportSuccessOnce() throws {
        let h = try CleanupFlowHarness(); defer { h.close() }
        h.coordinator.start(.clearHistory)
        XCTAssertEqual(h.coordinator.start(.clearHistory), .ignored)
        let plan = try h.plan(for: .clearHistory)
        h.prepares[0].1(.success(plan)); h.prepares[0].1(.success(plan))
        XCTAssertEqual(h.confirmations.count, 1)
        h.approve(); h.approve(); XCTAssertEqual(h.commits.count, 1)
        let result = try h.store.commitHistoryCleanup(h.commits[0].0)
        h.commits[0].1(.success(result)); h.commits[0].1(.success(result)); h.commits[0].1(.failure(failure()))
        XCTAssertEqual(h.successes.count, 1); XCTAssertTrue(h.failures.isEmpty); XCTAssertEqual(h.refreshes, 1)
    }

    func testCancellationAndTerminationCannotClaimAnAlreadyStartedCommitWasCancelled() throws {
        let h = try CleanupFlowHarness(); defer { h.close() }
        h.coordinator.start(.clearHistory); try h.prepare(); h.approve()
        XCTAssertFalse(h.coordinator.cancelPending()); XCTAssertFalse(h.coordinator.terminate())
        XCTAssertTrue(h.coordinator.isBusy); XCTAssertTrue(h.coordinator.isCommitting); XCTAssertTrue(h.cancellations.isEmpty)
        try h.commit(); XCTAssertEqual(h.successes.count, 1)
        XCTAssertTrue(h.coordinator.terminate()); XCTAssertEqual(h.coordinator.start(.clearHistory), .ignored)
    }

    func testExternalBusyAutomaticRequestsCoalesceToLatestAndResumeOnlyOnceWithoutConfirmation() throws {
        let h = try CleanupFlowHarness(); defer { h.close() }
        h.externalBusy = true
        for days in [7, 30, 90, 90] { XCTAssertEqual(h.coordinator.start(.automatic(days: days)), .deferred) }
        h.coordinator.resumeDeferred(); XCTAssertTrue(h.prepares.isEmpty); XCTAssertFalse(h.coordinator.isBusy)
        h.externalBusy = false; h.coordinator.resumeDeferred(); h.coordinator.resumeDeferred()
        XCTAssertEqual(h.prepares.map(\.0), [.automatic(days: 90)])
        try h.prepare(); XCTAssertTrue(h.confirmations.isEmpty); XCTAssertEqual(h.commits.count, 1)
        try h.commit(); h.coordinator.resumeDeferred()
        XCTAssertEqual(h.prepares.count, 1); XCTAssertEqual(h.retentionDays, 30)
    }

    func testRepeatedActiveAutomaticTimerTicksDoNotRunASecondPass() throws {
        let h = try CleanupFlowHarness(); defer { h.close() }
        h.coordinator.start(.automatic(days: 7))
        XCTAssertEqual(h.coordinator.start(.automatic(days: 7)), .ignored)
        try h.prepare(); XCTAssertEqual(h.coordinator.start(.automatic(days: 7)), .ignored)
        try h.commit(); XCTAssertEqual(h.prepares.count, 1); XCTAssertEqual(h.successes.count, 1)
    }

    func testManualRequestSupersedesUnsubmittedAutomaticPreparation() throws {
        let h = try CleanupFlowHarness(); defer { h.close() }
        h.coordinator.start(.automatic(days: 7)); let old = h.prepares[0].1
        XCTAssertEqual(h.coordinator.start(.clearHistory), .deferred)
        XCTAssertEqual(h.prepares.map(\.0), [.automatic(days: 7), .clearHistory])
        old(.success(try h.plan(for: .automatic(days: 7))))
        XCTAssertTrue(h.commits.isEmpty); XCTAssertEqual(h.cancellations, [.automatic(days: 7)])
        try h.prepare(); XCTAssertEqual(h.confirmations[0].1, .clearHistory)
    }

    func testManualRequestWaitsForCommittedAutomaticThenRequiresItsOwnConfirmation() throws {
        let h = try CleanupFlowHarness(); defer { h.close() }
        h.coordinator.start(.automatic(days: 7)); try h.prepare()
        XCTAssertTrue(h.coordinator.isCommitting)
        XCTAssertEqual(h.coordinator.start(.retention(days: 1)), .deferred)
        XCTAssertEqual(h.coordinator.start(.clearHistory), .ignored)
        XCTAssertEqual(h.prepares.count, 1); try h.commit()
        XCTAssertEqual(h.prepares.map(\.0), [.automatic(days: 7), .retention(days: 1)])
        XCTAssertEqual(h.retentionDays, 30)
        try h.prepare(); XCTAssertEqual(h.confirmations[0].1, .retention(days: 1))
    }

    func testRetentionSuccessDiscardsOldAutomaticQueueAndCallbackCanScheduleNewPreference() throws {
        let h = try CleanupFlowHarness(); defer { h.close() }
        let originalSuccess = h.coordinator.onSuccess
        h.coordinator.onSuccess = { result, request in
            XCTAssertTrue(h.coordinator.isBusy)
            originalSuccess?(result, request)
            if case .retention = request { h.coordinator.start(.automatic(days: h.retentionDays)) }
        }
        h.coordinator.start(.retention(days: 7)); try h.prepare()
        h.coordinator.start(.automatic(days: 30))
        h.approve(); try h.commit()
        XCTAssertEqual(h.prepares.map(\.0), [.retention(days: 7), .automatic(days: 7)])
    }

    func testSynchronousPresentAndCommitCallbacksNeverInstallStaleCancelHandle() throws {
        let h = try CleanupFlowHarness(); defer { h.close() }
        var dismissals = 0
        h.coordinator.onPrepare = { request, reply in reply(Result { try h.plan(for: request) }) }
        h.coordinator.confirm = { _, _, reply in reply(true); return { dismissals += 1; reply(false) } }
        h.coordinator.onCommit = { plan, reply in reply(Result { try h.store.commitHistoryCleanup(plan) }) }
        h.coordinator.start(.retention(days: 7))
        XCTAssertEqual(h.successes.count, 1); XCTAssertTrue(h.cancellations.isEmpty)
        XCTAssertEqual(h.retentionDays, 7); XCTAssertEqual(dismissals, 1); XCTAssertEqual(h.busy, [true, false])
        XCTAssertTrue(h.coordinator.cancelPending()); XCTAssertEqual(dismissals, 1)
    }

    func testBusyObserverCanCancelBeforePreparationDispatchWithoutStartingOldWork() throws {
        let h = try CleanupFlowHarness(); defer { h.close() }
        h.coordinator.onBusyChanged = { busy in h.busy.append(busy); if busy { XCTAssertTrue(h.coordinator.cancelPending()) } }
        h.coordinator.start(.clearHistory)
        XCTAssertTrue(h.prepares.isEmpty); XCTAssertEqual(h.cancellations, [.clearHistory]); XCTAssertEqual(h.busy, [true, false])
    }

    func testExternalMutationBetweenConfirmationAndCommitWaitsUsingTheSameFrozenPlan() throws {
        let h = try CleanupFlowHarness(); defer { h.close() }
        h.coordinator.start(.clearHistory); try h.prepare(); h.externalBusy = true; h.approve()
        XCTAssertTrue(h.coordinator.isBusy); XCTAssertFalse(h.coordinator.isCommitting); XCTAssertTrue(h.commits.isEmpty)
        let later = try h.store.create(.init(text: "added while externally busy"))
        h.coordinator.resumeDeferred(); XCTAssertTrue(h.commits.isEmpty)
        h.externalBusy = false; h.coordinator.resumeDeferred(); h.coordinator.resumeDeferred()
        XCTAssertEqual(h.prepares.count, 1); XCTAssertEqual(h.confirmations.count, 1); XCTAssertEqual(h.commits.count, 1)
        try h.commit(); XCTAssertNotNil(try h.store.item(id: later.id))
    }

    func testTerminateBeforeCommitInvalidatesPresenterAndEveryQueuedRequest() throws {
        let h = try CleanupFlowHarness(); defer { h.close() }
        h.coordinator.start(.clearHistory); try h.prepare(); h.coordinator.start(.automatic(days: 7))
        XCTAssertTrue(h.coordinator.terminate()); h.approve(); h.coordinator.resumeDeferred()
        XCTAssertEqual(h.coordinator.start(.clearHistory), .ignored)
        XCTAssertTrue(h.commits.isEmpty); XCTAssertEqual(h.prepares.count, 1); XCTAssertFalse(h.coordinator.isBusy)
    }

    func testPermanentRetentionNeverGeneratesADeletionPlanAndClearsDeferredAutomation() throws {
        let h = try CleanupFlowHarness(); defer { h.close() }
        h.externalBusy = true; h.coordinator.start(.automatic(days: 7))
        h.coordinator.start(.automatic(days: 0)); h.externalBusy = false; h.coordinator.resumeDeferred()
        XCTAssertTrue(h.prepares.isEmpty)
        h.coordinator.start(.retention(days: 0))
        XCTAssertEqual(h.failures.last?.0 as? HistoryCleanupFlowError, .invalidRequest)
        XCTAssertTrue(h.prepares.isEmpty); XCTAssertEqual(h.retentionDays, 30)
    }

    func testPermanentRetentionCancelsUnsubmittedConfirmationAndQueuedManualBeforeSavingPreference() throws {
        let h = try CleanupFlowHarness(); defer { h.close() }
        h.coordinator.start(.retention(days: 7)); try h.prepare()
        let oldApproval = h.confirmations[0].2
        h.coordinator.start(.automatic(days: 30))
        XCTAssertFalse(h.coordinator.isCommitting)
        XCTAssertTrue(h.coordinator.cancelPending())
        h.coordinator.start(.automatic(days: 0))
        h.preferences.set(0, forKey: "retentionDays")
        oldApproval(true); h.coordinator.resumeDeferred()
        XCTAssertTrue(h.commits.isEmpty); XCTAssertEqual(h.prepares.count, 1)
        XCTAssertEqual(h.confirmationDismissals, 1); XCTAssertEqual(h.retentionDays, 0)

        // A manual request may be queued behind an external write without setting isBusy.
        // Merely sending automatic(0) is insufficient: cancelPending must retire both queues.
        h.externalBusy = true
        XCTAssertEqual(h.coordinator.start(.retention(days: 1)), .deferred)
        h.coordinator.start(.automatic(days: 7))
        XCTAssertFalse(h.coordinator.isBusy)
        h.externalBusy = false
        XCTAssertTrue(h.coordinator.cancelPending())
        h.coordinator.start(.automatic(days: 0))
        h.preferences.set(0, forKey: "retentionDays")
        h.coordinator.resumeDeferred()
        XCTAssertEqual(h.prepares.count, 1); XCTAssertTrue(h.commits.isEmpty)
        XCTAssertEqual(h.retentionDays, 0); XCTAssertEqual(try h.store.load().count, 3)
    }

    func testPendingTerminationGateDefersTimerAndEitherResumesOrPermanentlyRetiresRequests() throws {
        let h = try CleanupFlowHarness(); defer { h.close() }
        h.coordinator.start(.clearHistory); try h.prepare()
        let oldApproval = h.confirmations[0].2

        // The app holds this external gate throughout the asynchronous draft/quit decision.
        h.externalBusy = true
        XCTAssertTrue(h.coordinator.cancelPending())
        XCTAssertEqual(h.coordinator.start(.automatic(days: 7)), .deferred)
        oldApproval(true); h.coordinator.resumeDeferred()
        XCTAssertEqual(h.prepares.count, 1); XCTAssertTrue(h.commits.isEmpty)

        // Cancelling quit reopens the gate and resumes the current automatic rule once.
        h.externalBusy = false; h.coordinator.resumeDeferred(); h.coordinator.resumeDeferred()
        XCTAssertEqual(h.prepares.map(\.0), [.clearHistory, .automatic(days: 7)])
        try h.prepare(); XCTAssertTrue(h.coordinator.isCommitting)
        XCTAssertFalse(h.coordinator.terminate(), "The final quit check must still reject an already dispatched write")
        try h.commit()

        // Accepting quit retires queued work before replying to AppKit, not only in willTerminate.
        h.externalBusy = true
        XCTAssertEqual(h.coordinator.start(.automatic(days: 1)), .deferred)
        XCTAssertEqual(h.coordinator.start(.clearHistory), .deferred)
        XCTAssertTrue(h.coordinator.terminate())
        h.externalBusy = false; h.coordinator.resumeDeferred()
        XCTAssertEqual(h.coordinator.start(.automatic(days: 1)), .ignored)
        XCTAssertEqual(h.prepares.count, 2); XCTAssertEqual(h.commits.count, 1)
        XCTAssertEqual(h.retentionDays, 30)
    }

    func testFailureCallbackReentryQueuesFreshRequestWithoutReusingOldConfirmation() throws {
        let h = try CleanupFlowHarness(); defer { h.close() }
        let originalFailure = h.coordinator.onFailure
        h.coordinator.onFailure = { error, request in
            originalFailure?(error, request)
            XCTAssertEqual(h.coordinator.start(.clearHistory), .deferred)
        }
        h.coordinator.start(.retention(days: 7)); h.prepares[0].1(.failure(failure()))
        XCTAssertEqual(h.prepares.map(\.0), [.retention(days: 7), .clearHistory])
        XCTAssertTrue(h.confirmations.isEmpty); XCTAssertTrue(h.commits.isEmpty)
        try h.prepare(); XCTAssertEqual(h.confirmations[0].1, .clearHistory)
    }
}
