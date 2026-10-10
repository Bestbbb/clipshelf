import AppKit
import ClipShelfCore
import ClipShelfLocalization
import XCTest
@testable import ClipShelf

@MainActor final class ContentQuotaSettingsTests: XCTestCase {
    private var directory: URL!
    private var store: HistoryStore!
    private var preferences: UserDefaults!
    private var suite: String!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-quota-ui-\(UUID())")
        store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        suite = "clipshelf.quota-ui.\(UUID())"
        preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
    }
    override func tearDown() async throws {
        preferences.removePersistentDomain(forName: suite)
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }
    private func actions() -> StorageSettingsController.Actions {
        let store = store!
        return .init(scan: { try store.ownedStorageUsage() }, prepare: { try store.prepareOwnedStorageCleanup() },
                     commit: { try store.commitOwnedStorageCleanup($0) }, recover: { try store.resumeOwnedStorageCleanup() },
                     readContentQuota: { try store.contentQuotaStatus() },
                     setContentQuota: { try store.setContentQuotaLimit($0, expectedRevision: $1) })
    }
    private func view<T: NSView>(_ id: String, _ type: T.Type, in controller: StorageSettingsController) throws -> T {
        func find(_ root: NSView) -> T? {
            if root.accessibilityIdentifier() == id, let value = root as? T { return value }
            return root.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(find(XCTUnwrap(controller.window?.contentView)))
    }
    private func notice(_ controller: StorageSettingsController) throws -> String {
        try view("storage.quota.notice", NSTextField.self, in: controller).stringValue
    }
    private func input(_ text: String?, into controller: StorageSettingsController) throws {
        let mode = try view("storage.quota.mode", NSPopUpButton.self, in: controller)
        mode.selectItem(at: text == nil ? 0 : 1)
        _ = mode.sendAction(mode.action, to: mode.target)
        if let text {
            let field = try view("storage.quota.mib", NSTextField.self, in: controller)
            field.stringValue = text
            controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
    }
    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(predicate(), file: file, line: line)
    }
    private func loaded(_ actions: StorageSettingsController.Actions? = nil) async -> StorageSettingsController {
        let controller = StorageSettingsController(actions: actions ?? self.actions(), preferences: preferences)
        controller.refresh()
        await waitUntil { !controller.isBusy }
        return controller
    }

    func testDefaultUnlimitedExplicitSaveAndReopenReadDatabasePolicy() async throws {
        let controller = await loaded()
        defer { _ = controller.cancelPending() }
        XCTAssertNil(try XCTUnwrap(controller.contentQuota).limitBytes)
        XCTAssertEqual(try view("storage.quota.mode", NSPopUpButton.self, in: controller).indexOfSelectedItem, 0)
        try input("2", into: controller)
        XCTAssertNil(try store.contentQuotaStatus().limitBytes, "Editing alone does not commit a setting")
        controller.saveContentQuota()
        await waitUntil { !controller.isBusy }
        let reopened = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        XCTAssertEqual(try reopened.contentQuotaStatus().limitBytes, 2 * 1_048_576)
        XCTAssertEqual(controller.contentQuota?.limitBytes, 2 * 1_048_576)
        XCTAssertFalse(try view("storage.quota.save", NSButton.self, in: controller).isEnabled)
        try input(nil, into: controller)
        controller.saveContentQuota()
        await waitUntil { !controller.isBusy }
        XCTAssertNil(try reopened.contentQuotaStatus().limitBytes)
    }

    func testMiBInputRejectsInvalidValuesAndOverflow() throws {
        for text in ["", "0", "-1", "+1", "1.5", "1,024", "invalid", String(Int64.max), String(Int64.max / 1_048_576 + 1)] {
            XCTAssertThrowsError(try StorageSettingsController.contentQuotaBytes(limited: true, text: text), text)
        }
        XCTAssertEqual(try StorageSettingsController.contentQuotaBytes(limited: true, text: " 12 "), 12 * 1_048_576)
        XCTAssertNil(try StorageSettingsController.contentQuotaBytes(limited: false, text: "invalid retained draft"))
    }

    func testBelowUsageKeepsContentAndFailedFileQueueCanRaiseOrDisableLimit() async throws {
        let record = try store.create(ClipboardRecord(text: "large synthetic payload", parts: [.init(representations: [
            .init(typeIdentifier: "test.large", data: Data(repeating: 0x41, count: 2 * 1_048_576))
        ])]))
        let pending = CapturePersistenceInput(snapshot: .init(parts: [.init(representations: [
            .init(typeIdentifier: "public.file-url", data: Data("file:///synthetic-pending-file".utf8))
        ])], byteCount: 0), stackSessionID: nil)
        XCTAssertTrue(pending.blocksOwnedReclamation)
        let controller = await loaded()
        defer { _ = controller.cancelPending() }
        controller.isExternalMutationBusy = { pending.blocksOwnedReclamation }
        controller.allowsLimitChange = { true }
        try input("1", into: controller)
        controller.saveContentQuota()
        await waitUntil { !controller.isBusy }
        XCTAssertGreaterThan(try XCTUnwrap(controller.contentQuota).exceededBytes, 0)
        XCTAssertNotNil(try store.item(id: record.id))
        XCTAssertEqual(try store.item(id: record.id)?.parts, record.parts)
        try input("4", into: controller)
        controller.saveContentQuota()
        await waitUntil { !controller.isBusy }
        XCTAssertEqual(controller.contentQuota?.limitBytes, 4 * 1_048_576)
        try input(nil, into: controller)
        controller.saveContentQuota()
        await waitUntil { !controller.isBusy }
        XCTAssertNil(try store.contentQuotaStatus().limitBytes)
        XCTAssertNotNil(try store.item(id: record.id))
    }

    func testLateReadCannotOverwriteAnUnsavedDraft() async throws {
        let snapshot = try store.contentQuotaStatus()
        var continuation: CheckedContinuation<LibraryContentQuotaStatus, Error>?
        var configured = actions()
        configured.readContentQuota = { try await withCheckedThrowingContinuation { continuation = $0 } }
        let controller = StorageSettingsController(actions: configured, preferences: preferences)
        defer { _ = controller.cancelPending() }
        controller.refresh()
        await waitUntil { continuation != nil }
        try input("3", into: controller)
        continuation?.resume(returning: snapshot); continuation = nil
        await waitUntil { !controller.isBusy }
        XCTAssertEqual(try view("storage.quota.mode", NSPopUpButton.self, in: controller).indexOfSelectedItem, 1)
        XCTAssertEqual(try view("storage.quota.mib", NSTextField.self, in: controller).stringValue, "3")
        XCTAssertNil(controller.contentQuota?.limitBytes)
        XCTAssertTrue(try view("storage.quota.save", NSButton.self, in: controller).isEnabled)
    }

    func testFullQuotaStillAllowsConfirmedOwnedReclamationAndRefreshesSavedUsage() async throws {
        let record = try store.create(ClipboardRecord(text: "reclaimable.bin", parts: [.init(representations: [
            .init(typeIdentifier: "public.file-url", data: Data())
        ])]), ownedFiles: [.init(partIndex: 0, representationIndex: 0, filename: "reclaimable.bin", data: Data(repeating: 0x41, count: 2 * 1_048_576))],
        expectedSyncConfiguration: store.syncConfiguration(), expectedSharingConfiguration: store.sharingConfiguration())
        try store.delete(id: record.id)
        let before = try store.contentQuotaStatus()
        XCTAssertGreaterThan(before.ownedFileBytes, 1_048_576)
        _ = try store.setContentQuotaLimit(1_048_576, expectedRevision: before.policyRevision)
        let controller = await loaded()
        defer { _ = controller.cancelPending() }
        XCTAssertGreaterThan(try XCTUnwrap(controller.contentQuota).exceededBytes, 0)
        controller.confirmation = { plan, reply in
            XCTAssertEqual(plan.candidateCount, 1)
            reply(true)
            return {}
        }
        controller.cleanup()
        await waitUntil { !controller.isBusy }
        XCTAssertEqual(controller.contentQuota?.ownedFileBytes, 0)
        XCTAssertEqual(controller.contentQuota?.exceededBytes, 0)
        XCTAssertEqual(controller.contentQuota?.limitBytes, 1_048_576)
    }

    func testPolicyConflictRefreshesAuthorityButRequiresAnotherExplicitSave() async throws {
        let controller = await loaded()
        defer { _ = controller.cancelPending() }
        let revision = try XCTUnwrap(controller.contentQuota).policyRevision
        let other = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        _ = try other.setContentQuotaLimit(4 * 1_048_576, expectedRevision: revision)
        try input("2", into: controller)
        controller.saveContentQuota()
        await waitUntil { !controller.isBusy }
        XCTAssertEqual(try other.contentQuotaStatus().limitBytes, 4 * 1_048_576)
        XCTAssertEqual(controller.contentQuota?.limitBytes, 4 * 1_048_576)
        XCTAssertEqual(try view("storage.quota.mib", NSTextField.self, in: controller).stringValue, "2")
        XCTAssertEqual(try notice(controller), L10n.text("上限已在其他窗口或进程中改变。你的输入仍保留；请核对当前上限后再次保存。"))
        controller.saveContentQuota()
        await waitUntil { !controller.isBusy }
        XCTAssertEqual(try other.contentQuotaStatus().limitBytes, 2 * 1_048_576)
    }

    func testReadFailureClearsOldMeasurementAndPreservesDraft() async throws {
        var fail = false
        let store = store!
        var configured = actions()
        configured.readContentQuota = {
            if fail { throw ContentQuotaError.measurementUnavailable }
            return try store.contentQuotaStatus()
        }
        let controller = await loaded(configured)
        defer { _ = controller.cancelPending() }
        try input("7", into: controller)
        fail = true; controller.refresh()
        await waitUntil { !controller.isBusy }
        XCTAssertNil(controller.contentQuota)
        XCTAssertFalse(try view("storage.quota.save", NSButton.self, in: controller).isEnabled)
        XCTAssertEqual(try view("storage.quota.mib", NSTextField.self, in: controller).stringValue, "7")
        XCTAssertTrue(try view("storage.quota.usage", NSTextField.self, in: controller).stringValue.contains(ContentQuotaError.measurementUnavailable.localizedDescription))
    }

    func testFailedSetterKeepsPolicyAndInputForExplicitRetry() async throws {
        var fail = true
        let store = store!
        var configured = actions()
        configured.setContentQuota = { bytes, revision in
            if fail { throw NSError(domain: NSPOSIXErrorDomain, code: 28) }
            return try store.setContentQuotaLimit(bytes, expectedRevision: revision)
        }
        let controller = await loaded(configured)
        defer { _ = controller.cancelPending() }
        try input("6", into: controller)
        controller.saveContentQuota(); await waitUntil { !controller.isBusy }
        XCTAssertNil(try store.contentQuotaStatus().limitBytes)
        XCTAssertEqual(try view("storage.quota.mib", NSTextField.self, in: controller).stringValue, "6")
        fail = false
        controller.saveContentQuota(); await waitUntil { !controller.isBusy }
        XCTAssertEqual(try store.contentQuotaStatus().limitBytes, 6 * 1_048_576)
    }

    func testClosedOrSuspendedWindowSuppressesLateSaveReceiptButSettlesCommit() async throws {
        for suspended in [false, true] {
            var continuation: CheckedContinuation<Void, Never>?
            var calls = 0
            let store = store!
            var configured = actions()
            configured.setContentQuota = { bytes, revision in
                calls += 1
                await withCheckedContinuation { continuation = $0 }
                return try store.setContentQuotaLimit(bytes, expectedRevision: revision)
            }
            let controller = await loaded(configured)
            defer { _ = controller.cancelPending() }
            try input("5", into: controller)
            let previousNotice = try notice(controller)
            controller.saveContentQuota()
            await waitUntil { continuation != nil }
            XCTAssertTrue(controller.isCommitting)
            controller.saveContentQuota(); XCTAssertEqual(calls, 1)
            if suspended { controller.suspend() }
            else { controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: controller.window)) }
            XCTAssertTrue(controller.isCommitting)
            continuation?.resume(); continuation = nil
            await waitUntil { !controller.isBusy }
            XCTAssertEqual(try store.contentQuotaStatus().limitBytes, 5 * 1_048_576)
            XCTAssertEqual(try notice(controller), previousNotice)
            XCTAssertNil(controller.contentQuota)
            XCTAssertFalse(controller.window?.isVisible ?? true)
            controller.refresh(); await waitUntil { !controller.isBusy }
            XCTAssertEqual(controller.contentQuota?.limitBytes, 5 * 1_048_576)
        }
    }

    func testDisallowedSessionCannotReadOrWriteQuota() async throws {
        let controller = await loaded()
        defer { _ = controller.cancelPending() }
        try input("9", into: controller)
        controller.allowsLimitChange = { false }
        controller.allowsLibraryScan = { false }
        controller.saveContentQuota(); controller.refresh()
        await Task.yield()
        XCTAssertFalse(controller.isBusy)
        XCTAssertNil(try store.contentQuotaStatus().limitBytes)
        XCTAssertEqual(try view("storage.quota.mib", NSTextField.self, in: controller).stringValue, "9")
    }
}
