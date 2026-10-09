import AppKit
import ClipShelfCore
import XCTest
@testable import ClipShelf

@MainActor
private final class StorageSettingsGate<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    private(set) var waiting = false
    private(set) var returned = false
    func value() async throws -> Value {
        defer { returned = true }
        return try await withCheckedThrowingContinuation {
            continuation = $0
            waiting = true
        }
    }
    func resolve(_ result: Result<Value, Error>) {
        let saved = continuation; continuation = nil
        saved?.resume(with: result)
    }
}

/// Exercises the real controller and Core's opaque plans without presenting a
/// window or sheet. Every database, file and preference domain is disposable.
@MainActor
final class StorageSettingsControllerTests: XCTestCase {
    @MainActor private final class Fixture {
        let directory: URL
        let store: HistoryStore
        let preferences: UserDefaults
        let suite = "clipshelf-storage-settings-tests-" + UUID().uuidString
        let projection: URL
        let bytes = Data(repeating: 0x5A, count: 4_096)

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-storage-settings-\(UUID())", isDirectory: true)
            store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
            preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
            let record = try store.create(ClipboardRecord(text: "collectible.bin", parts: [ClipboardPart(representations: [
                ClipboardRepresentation(typeIdentifier: "public.file-url", data: Data())
            ])]), ownedFiles: [.init(partIndex: 0, representationIndex: 0, filename: "collectible.bin", data: bytes)],
            expectedSyncConfiguration: store.syncConfiguration(), expectedSharingConfiguration: store.sharingConfiguration())
            projection = try XCTUnwrap(ClipboardFileAccess.url(from: XCTUnwrap(record.parts.first?.representations.first?.data)))
            try store.delete(id: record.id)
            XCTAssertEqual(try store.prepareOwnedStorageCleanup().candidateCount, 1)
        }
        func actions() -> StorageSettingsController.Actions {
            let store = store
            return .init(scan: { try store.ownedStorageUsage() }, prepare: { try store.prepareOwnedStorageCleanup() },
                         commit: { try store.commitOwnedStorageCleanup($0) }, recover: { try store.resumeOwnedStorageCleanup() })
        }
        func close(_ controller: StorageSettingsController) {
            XCTAssertFalse(controller.window?.isVisible ?? true)
            _ = controller.cancelPending()
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { views(type, in: $0) }
    }
    private func fields(_ controller: StorageSettingsController) throws -> [NSTextField] {
        views(NSTextField.self, in: try XCTUnwrap(controller.window?.contentView))
    }
    private func status(_ controller: StorageSettingsController) throws -> String {
        try XCTUnwrap(fields(controller).first).stringValue
    }
    private func allText(_ controller: StorageSettingsController) throws -> String {
        try fields(controller).map(\.stringValue).joined(separator: "\n")
    }
    private func button(_ title: String, in controller: StorageSettingsController) throws -> NSButton {
        try XCTUnwrap(views(NSButton.self, in: XCTUnwrap(controller.window?.contentView)).first { $0.title == title })
    }
    private func waitFor(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                         _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(condition(), description, file: file, line: line)
    }
    private func drain() async { for _ in 0..<8 { await Task.yield() } }
    private var zero: OwnedStorageCleanupResult {
        .init(removedAssetCount: 0, removedFileCount: 0, removedLogicalBytes: 0, remainingPendingCount: 0)
    }

    func testManualConfirmationProtectsRealFileAndCloseInvalidatesLateApproval() async throws {
        let f = try Fixture()
        var actions = f.actions(), commits = 0, dismissals = 0
        actions.commit = { plan in commits += 1; return try f.store.commitOwnedStorageCleanup(plan) }
        let controller = StorageSettingsController(actions: actions, preferences: f.preferences)
        defer { f.close(controller) }
        var decision: ((Bool) -> Void)?
        controller.confirmation = { plan, reply in
            XCTAssertEqual(plan.candidateCount, 1)
            decision = reply
            return { dismissals += 1 }
        }
        controller.cleanup()
        await waitFor("waiting for user confirmation") { decision != nil }
        XCTAssertEqual(controller.phase, .confirming)
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(try Data(contentsOf: f.projection), f.bytes)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: controller.window))
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(dismissals, 1)
        decision?(true); decision?(true)
        await drain()
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(try Data(contentsOf: f.projection), f.bytes)
        XCTAssertTrue(try status(controller).contains("取消"))
    }

    func testLatePrepareAfterCloseCannotPresentConfirmationOrCommit() async throws {
        let f = try Fixture(), gate = StorageSettingsGate<OwnedStorageCleanupPlan>()
        let plan = try f.store.prepareOwnedStorageCleanup()
        var actions = f.actions(), confirmations = 0, commits = 0
        actions.prepare = { try await gate.value() }
        actions.commit = { _ in commits += 1; return self.zero }
        let controller = StorageSettingsController(actions: actions, preferences: f.preferences)
        defer { f.close(controller) }
        controller.confirmation = { _, _ in confirmations += 1; return {} }
        controller.cleanup()
        await waitFor("prepare awaiting Core") { gate.waiting }
        XCTAssertTrue(controller.cancelPending())
        controller.refresh()
        await waitFor("fresh scan completes") { controller.phase == .idle && controller.usage != nil }
        let currentText = try allText(controller)
        gate.resolve(.success(plan))
        await waitFor("old prepare returns") { gate.returned }
        await drain()
        XCTAssertEqual(confirmations, 0); XCTAssertEqual(commits, 0)
        XCTAssertEqual(try allText(controller), currentText)
        XCTAssertEqual(try Data(contentsOf: f.projection), f.bytes)
    }

    func testLateScanSuccessAndFailureCannotReplaceNewGenerationState() async throws {
        for staleFailure in [false, true] {
            let f = try Fixture(), gate = StorageSettingsGate<OwnedStorageUsage>()
            let staleReport = try f.store.ownedStorageUsage()
            var actions = f.actions(), scans = 0
            actions.scan = {
                scans += 1
                if scans == 1 { return try await gate.value() }
                return try f.store.ownedStorageUsage()
            }
            let controller = StorageSettingsController(actions: actions, preferences: f.preferences)
            defer { f.close(controller) }
            controller.refresh()
            await waitFor("old scan waiting") { gate.waiting }
            XCTAssertTrue(controller.cancelPending())
            _ = try f.store.commitOwnedStorageCleanup(f.store.prepareOwnedStorageCleanup())
            controller.refresh()
            await waitFor("new empty scan installed") { controller.phase == .idle && controller.usage?.assetCount == 0 }
            let currentText = try allText(controller), currentUsage = controller.usage
            gate.resolve(staleFailure ? .failure(NSError(domain: "stale scan", code: 1)) : .success(staleReport))
            await waitFor("old scan completion returns") { gate.returned }
            await drain()
            XCTAssertEqual(controller.usage, currentUsage)
            XCTAssertEqual(try allText(controller), currentText)
            XCTAssertEqual(controller.phase, .idle)
        }
    }

    func testAutomaticDefaultOffAndExplicitEnableCoalescesWhileExternalMutationIsBusy() async throws {
        let f = try Fixture()
        var actions = f.actions(), prepares = 0, commits = 0, externalBusy = true
        actions.prepare = { prepares += 1; return try f.store.prepareOwnedStorageCleanup() }
        actions.commit = { plan in commits += 1; return try f.store.commitOwnedStorageCleanup(plan) }
        let controller = StorageSettingsController(actions: actions, preferences: f.preferences)
        defer { f.close(controller) }
        controller.isExternalMutationBusy = { externalBusy }
        controller.confirmation = { _, _ in XCTFail("An explicitly enabled automatic pass needs no sheet"); return {} }
        let toggle = try button("自动回收已不再使用的托管文件", in: controller)
        XCTAssertEqual(toggle.state, .off)
        controller.requestAutomaticReclamation()
        await drain()
        XCTAssertEqual(prepares, 0); XCTAssertEqual(commits, 0)
        toggle.performClick(nil)
        XCTAssertTrue(f.preferences.bool(forKey: "automaticallyReclaimOwnedFiles"))
        for _ in 0..<4 { controller.requestAutomaticReclamation(); controller.resumeDeferred() }
        await drain()
        XCTAssertEqual(prepares, 0); XCTAssertEqual(commits, 0)
        XCTAssertEqual(try Data(contentsOf: f.projection), f.bytes)
        externalBusy = false; controller.resumeDeferred()
        await waitFor("one deferred automatic pass completes") { commits == 1 && controller.phase == .idle }
        XCTAssertEqual(prepares, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.projection.path))
        controller.resumeDeferred(); await drain()
        XCTAssertEqual(commits, 1)
    }

    func testAutomaticPassDefersAgainIfExternalMutationStartsDuringPreparation() async throws {
        let f = try Fixture(), gate = StorageSettingsGate<OwnedStorageCleanupPlan>()
        let originalPlan = try f.store.prepareOwnedStorageCleanup()
        f.preferences.set(true, forKey: "automaticallyReclaimOwnedFiles")
        var actions = f.actions(), prepares = 0, commits = 0, externalBusy = false
        actions.prepare = {
            prepares += 1
            if prepares == 1 { return try await gate.value() }
            return try f.store.prepareOwnedStorageCleanup()
        }
        actions.commit = { plan in commits += 1; return try f.store.commitOwnedStorageCleanup(plan) }
        let controller = StorageSettingsController(actions: actions, preferences: f.preferences)
        defer { f.close(controller) }
        controller.isExternalMutationBusy = { externalBusy }
        controller.requestAutomaticReclamation()
        await waitFor("automatic preparation waiting") { gate.waiting }
        externalBusy = true; gate.resolve(.success(originalPlan))
        await waitFor("automatic preparation yields to external mutation") { controller.phase == .idle }
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(try Data(contentsOf: f.projection), f.bytes)
        externalBusy = false; controller.resumeDeferred()
        await waitFor("deferred automatic request retries a fresh range") { commits == 1 && controller.phase == .idle }
        XCTAssertEqual(prepares, 2, "The old plan must be prepared again after intervening work.")
    }

    func testStartedCommitCannotBeCancelledOrSubmittedTwiceAndBusyIncludesFollowupScan() async throws {
        let f = try Fixture(), commitGate = StorageSettingsGate<Void>(), scanGate = StorageSettingsGate<OwnedStorageUsage>()
        var actions = f.actions(), commits = 0, result: OwnedStorageCleanupResult?
        actions.commit = { plan in
            commits += 1
            try await commitGate.value()
            let finished = try f.store.commitOwnedStorageCleanup(plan); result = finished
            return finished
        }
        actions.scan = { try await scanGate.value() }
        let controller = StorageSettingsController(actions: actions, preferences: f.preferences)
        defer { f.close(controller) }
        var decision: ((Bool) -> Void)?, messages: [String] = []
        controller.confirmation = { _, reply in decision = reply; return {} }
        controller.onMessage = { messages.append($0) }
        controller.cleanup()
        await waitFor("manual range confirmed") { decision != nil }
        decision?(true)
        await waitFor("commit entered") { commitGate.waiting }
        XCTAssertFalse(controller.cancelPending())
        controller.cleanup(); controller.refresh(); decision?(true)
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(controller.phase, .committing)
        commitGate.resolve(.success(()))
        await waitFor("commit's usage scan waiting") { scanGate.waiting }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.projection.path))
        XCTAssertTrue(controller.isBusy); XCTAssertTrue(controller.isCommitting)
        XCTAssertFalse(controller.cancelPending())
        controller.cleanup(); decision?(true)
        XCTAssertEqual(commits, 1)
        scanGate.resolve(.success(try f.store.ownedStorageUsage()))
        await waitFor("commit completion and usage installed") { controller.phase == .idle }
        XCTAssertEqual(messages.count, 1)
        let removed = try XCTUnwrap(result)
        XCTAssertGreaterThan(removed.removedLogicalBytes, 0)
        XCTAssertTrue(messages[0].contains("已移除"))
        XCTAssertTrue(messages[0].contains("文件大小合计"))
        XCTAssertTrue(messages[0].contains(ByteCountFormatter.string(fromByteCount: removed.removedLogicalBytes, countStyle: .file)))
        XCTAssertFalse(messages[0].contains("释放")); XCTAssertFalse(messages[0].contains("可用空间"))
        XCTAssertEqual(controller.usage?.assetCount, 0)
        XCTAssertFalse(controller.window?.isVisible ?? true)
    }

    func testDisablingAutomaticPreferenceWhilePreparingPreventsCommit() async throws {
        let f = try Fixture(), gate = StorageSettingsGate<OwnedStorageCleanupPlan>()
        let plan = try f.store.prepareOwnedStorageCleanup()
        f.preferences.set(true, forKey: "automaticallyReclaimOwnedFiles")
        var actions = f.actions(), commits = 0
        actions.prepare = { try await gate.value() }
        actions.commit = { _ in commits += 1; return self.zero }
        let controller = StorageSettingsController(actions: actions, preferences: f.preferences)
        defer { f.close(controller) }
        controller.requestAutomaticReclamation()
        await waitFor("automatic prepare waiting while preference changes") { gate.waiting }
        f.preferences.set(false, forKey: "automaticallyReclaimOwnedFiles")
        gate.resolve(.success(plan))
        await waitFor("disabled automatic pass stops") { controller.phase == .idle }
        XCTAssertEqual(commits, 0)
        XCTAssertTrue(try status(controller).contains("关闭"))
        XCTAssertEqual(try Data(contentsOf: f.projection), f.bytes)
        controller.resumeDeferred(); await drain()
        XCTAssertEqual(commits, 0)
    }

    func testRecoveryIsDeferredPrioritizedAndCannotBeCancelledAfterItStarts() async throws {
        let f = try Fixture(), gate = StorageSettingsGate<OwnedStorageCleanupResult>()
        f.preferences.set(true, forKey: "automaticallyReclaimOwnedFiles")
        var actions = f.actions(), events: [String] = [], externalBusy = true
        actions.recover = { events.append("recover"); return try await gate.value() }
        actions.prepare = { events.append("prepare"); return try f.store.prepareOwnedStorageCleanup() }
        let controller = StorageSettingsController(actions: actions, preferences: f.preferences)
        defer { f.close(controller) }
        controller.isExternalMutationBusy = { externalBusy }
        controller.requestAutomaticReclamation(); controller.requestRecovery(); controller.requestRecovery()
        await drain(); XCTAssertTrue(events.isEmpty)
        externalBusy = false; controller.resumeDeferred()
        await waitFor("recovery begins before automatic preparation") { gate.waiting }
        XCTAssertEqual(events, ["recover"])
        XCTAssertTrue(controller.isCommitting); XCTAssertFalse(controller.cancelPending())
        gate.resolve(.success(zero))
        await waitFor("recovery finishes") { controller.phase == .idle }
        await drain()
        XCTAssertEqual(events, ["recover"], "Closing during recovery clears queued future automatic work but lets the recovery finish.")
        XCTAssertEqual(try Data(contentsOf: f.projection), f.bytes)
    }

    func testScanFailureClearsStaleUsageAndNeverPresentsUnknownAsZero() async throws {
        let f = try Fixture()
        var actions = f.actions(), fail = false
        actions.scan = {
            if fail { throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取受保护目录"]) }
            return try f.store.ownedStorageUsage()
        }
        let controller = StorageSettingsController(actions: actions, preferences: f.preferences)
        defer { f.close(controller) }
        XCTAssertNil(controller.usage)
        XCTAssertTrue(try allText(controller).contains("尚未读取"))
        controller.refresh()
        await waitFor("initial usage installed") { controller.phase == .idle && controller.usage != nil }
        fail = true; controller.refresh()
        await waitFor("failed scan returned") { controller.phase == .idle && controller.usage == nil }
        let text = try allText(controller)
        XCTAssertTrue(text.contains("无法取得完整统计"))
        XCTAssertTrue(text.contains("未知")); XCTAssertTrue(text.contains("无法读取受保护目录"))
        XCTAssertFalse(text.contains("托管文件：0"))
        XCTAssertFalse(text.contains("原件与打开副本大小：0"))
    }

    func testIncompleteMeasurementLabelsNumbersAsPartialRatherThanCompleteOrZero() async throws {
        let f = try Fixture()
        var actions = f.actions()
        actions.scan = { .init(assetCount: 0, totalLogicalBytes: 0, totalAllocatedBytes: 0,
                              reclaimableAssetCount: 0, reclaimableLogicalBytes: 0, protectedAssetCount: 0,
                              unverifiedAssetCount: 1, pendingReclamationCount: 0, measurementComplete: false) }
        let controller = StorageSettingsController(actions: actions, preferences: f.preferences)
        defer { f.close(controller) }
        controller.refresh()
        await waitFor("incomplete scan installed") { controller.phase == .idle && controller.usage != nil }
        let text = try allText(controller)
        XCTAssertTrue(text.contains("不完整") || text.contains("部分") || text.contains("未能完整"), text)
        XCTAssertTrue(text.contains("未知") || text.contains("不代表") || text.contains("至少") || text.contains("下界"), text)
    }

    func testFailedCommitReportsPossiblyPartialWorkAndFollowupScanFailureKeepsResult() async throws {
        for commitFails in [true, false] {
            let f = try Fixture()
            var actions = f.actions(), messages: [String] = []
            actions.commit = { plan in
                let result = try f.store.commitOwnedStorageCleanup(plan)
                if commitFails { throw NSError(domain: "after filesystem commit", code: 1) }
                return result
            }
            actions.scan = { throw NSError(domain: "followup measurement", code: 2) }
            let controller = StorageSettingsController(actions: actions, preferences: f.preferences)
            defer { f.close(controller) }
            controller.confirmation = { _, reply in reply(true); return {} }
            controller.onMessage = { messages.append($0) }
            controller.cleanup()
            await waitFor("terminal result reported") { controller.phase == .idle && !messages.isEmpty }
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.projection.path))
            XCTAssertNil(controller.usage)
            let text = try allText(controller)
            if commitFails {
                XCTAssertTrue(text.contains("部分文件")); XCTAssertTrue(text.contains("不能把失败当作完全没有改变"))
                XCTAssertFalse(messages[0].contains("未删除任何"))
            } else {
                XCTAssertTrue(text.contains("最新占用读取失败"))
                XCTAssertTrue(messages[0].contains("文件大小合计"))
                XCTAssertFalse(messages[0].contains("释放"))
            }
        }
    }

    func testLongFailureAndCompactWindowKeepEveryControlAccessible() async throws {
        let f = try Fixture()
        var actions = f.actions()
        let longError = String(repeating: "合成目录无法读取；请在恢复后刷新。", count: 150)
        actions.scan = { throw NSError(domain: "long fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: longError]) }
        let controller = StorageSettingsController(actions: actions, preferences: f.preferences)
        defer { f.close(controller) }
        controller.refresh()
        await waitFor("long error rendered") { controller.phase == .idle && controller.usage == nil }
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 620, height: 500))
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isVisible)
        for control in views(NSButton.self, in: content) {
            let frame = control.convert(control.bounds, to: content)
            XCTAssertGreaterThan(frame.height, 0, control.title)
            XCTAssertTrue(content.bounds.insetBy(dx: -1, dy: -1).contains(frame), "\(control.title) outside compact content: \(frame), content: \(content.bounds)")
        }
        let scrolls = views(NSScrollView.self, in: content)
        XCTAssertTrue(scrolls.contains { $0.hasVerticalScroller })
        XCTAssertTrue(try allText(controller).contains(longError), "Long errors must remain available through wrapping/scrolling, without discarding content.")
        let longField = try XCTUnwrap(fields(controller).first { $0.stringValue.contains(longError) })
        XCTAssertNotNil(longField.enclosingScrollView, "An arbitrarily long error must be scrollable, not clipped in the fixed status header.")
    }
}
