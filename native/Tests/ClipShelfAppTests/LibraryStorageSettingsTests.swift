import AppKit
import Darwin
import XCTest
import ClipShelfCore
import ClipShelfLocalization
@testable import ClipShelf

@MainActor final class LibraryStorageSettingsTests: XCTestCase {
    private var directory: URL!
    private var store: HistoryStore!
    private var preferences: UserDefaults!
    private var domain: String!
    override func setUp() async throws {
        let proposed = FileManager.default.temporaryDirectory.appendingPathComponent("library-usage-ui-\(UUID())")
        try FileManager.default.createDirectory(at: proposed, withIntermediateDirectories: true)
        let canonical = try XCTUnwrap(realpath(proposed.path, nil))
        directory = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        free(canonical)
        store = try HistoryStore(databaseURL: directory.appendingPathComponent("profile/history.sqlite"))
        _ = try store.create(.init(text: "synthetic storage report"))
        domain = "clipshelf.library-usage-test.\(UUID())"
        preferences = try XCTUnwrap(UserDefaults(suiteName: domain))
    }
    override func tearDown() async throws {
        if let preferences, let domain { preferences.removePersistentDomain(forName: domain) }
        store = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
    private func snapshot(validation: Bool = false) throws -> LibraryStorageSnapshot {
        let roots = LibraryStorageReader.additionalRoots(validationDirectory: validation ? store.storageUsageScope().profileDirectory : nil,
            cachesDirectory: directory.appendingPathComponent("caches"), shareInboxRoot: nil)
        return try LibraryStorageReader.read(store: store, roots: roots, cancellation: HistoryReadCancellation())
    }
    private func actions() -> StorageSettingsController.Actions {
        let store = store!
        return .init(scan: { XCTFail("Whole-library refresh must not run the expensive dependency audit"); return try store.ownedStorageUsage() },
                     prepare: { try store.prepareOwnedStorageCleanup() }, commit: { try store.commitOwnedStorageCleanup($0) },
                     recover: { try store.resumeOwnedStorageCleanup() })
    }
    private func texts(_ controller: StorageSettingsController) -> [String] {
        func collect(_ view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(collect)
        }
        return controller.window?.contentView.map(collect) ?? []
    }
    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(predicate())
    }

    func testLibraryScanIsIndependentOfReclamationGateAndDistinguishesUnavailableScope() async throws {
        let report = try snapshot()
        XCTAssertTrue(report.report.roots.contains { $0.root.scopeKind == .appGroup && $0.status == .unavailable })
        var actions = actions(); actions.scanLibrary = { _ in report }
        let controller = StorageSettingsController(actions: actions, preferences: preferences)
        defer { _ = controller.cancelPending() }
        controller.isExternalMutationBusy = { true }
        controller.allowsLibraryScan = { true }
        controller.refresh()
        await waitUntil { !controller.isBusy && controller.libraryUsage != nil }
        XCTAssertNil(controller.usage)
        XCTAssertTrue(texts(controller).contains { $0.contains(L10n.text("当前资料库")) && $0.contains(L10n.text("数据库与日志")) })
        XCTAssertTrue(texts(controller).contains { $0.contains(L10n.text("部分范围不可访问，未计入总量。")) })
        XCTAssertFalse(preferences.bool(forKey: "automaticallyReclaimOwnedFiles"))
        XCTAssertFalse(controller.window?.isVisible ?? true)
    }

    func testCancellationRetiresWorkerAndLateFailureCannotReplaceFreshTotals() async throws {
        let report = try snapshot(validation: true)
        var continuation: CheckedContinuation<LibraryStorageSnapshot, Error>?
        var firstToken: HistoryReadCancellation?, calls = 0
        var actions = actions()
        actions.scanLibrary = { token in
            calls += 1
            if calls == 1 {
                firstToken = token
                return try await withCheckedThrowingContinuation { continuation = $0 }
            }
            return report
        }
        let controller = StorageSettingsController(actions: actions, preferences: preferences)
        defer { _ = controller.cancelPending() }
        controller.refresh()
        await waitUntil { continuation != nil }
        XCTAssertTrue(controller.cancelPending()); XCTAssertTrue(firstToken?.isCancelled == true)
        controller.refresh()
        await waitUntil { controller.libraryUsage != nil && !controller.isBusy }
        let shown = texts(controller)
        continuation?.resume(throwing: NSError(domain: "obsolete scan", code: 1)); continuation = nil
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(texts(controller), shown)
        XCTAssertEqual(controller.libraryUsage?.report.logicalBytes, report.report.logicalBytes)
    }

    func testFailedRefreshClearsOldTotalsAndSuspendedSessionCannotStartScan() async throws {
        let report = try snapshot(validation: true)
        var calls = 0, allowed = true
        var actions = actions()
        actions.scanLibrary = { _ in
            calls += 1
            if calls > 1 { throw NSError(domain: "read failure", code: 1) }
            return report
        }
        let controller = StorageSettingsController(actions: actions, preferences: preferences)
        defer { _ = controller.cancelPending() }
        controller.allowsLibraryScan = { allowed }
        controller.refresh(); await waitUntil { controller.libraryUsage != nil && !controller.isBusy }
        controller.refresh(); await waitUntil { calls == 2 && !controller.isBusy }
        XCTAssertNil(controller.libraryUsage)
        XCTAssertTrue(texts(controller).contains(L10n.text("读取未完成，原因见下方。")))
        XCTAssertFalse(texts(controller).contains { $0.contains(L10n.text("整库占用 · 已计量范围")) })
        allowed = false; controller.refresh()
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(calls, 2)
    }

    func testValidationScopeExcludesSharedCachesAndUnknownCapacityIsNotZero() throws {
        let caches = directory.appendingPathComponent("caches/ClipShelf/OCR-v1")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try Data(repeating: 31, count: 12_345).write(to: caches.appendingPathComponent("fixture.json"))
        let shared = try snapshot(), isolated = try snapshot(validation: true)
        XCTAssertNotNil(isolated.profileAvailableBytes)
        XCTAssertEqual(shared.report.measurements.filter { $0.scopeKind == .sharedCache && $0.category == .ocrCache }.reduce(0) { $0 + $1.logicalBytes }, 12_345)
        XCTAssertFalse(isolated.report.roots.contains { $0.root.scopeKind != .profile })
        XCTAssertFalse(isolated.report.measurements.contains { $0.scopeKind == .sharedCache })
        let unknown = LibraryStorageSnapshot(report: isolated.report, profileAvailableBytes: nil)
        XCTAssertTrue(LibraryStorageReader.describe(unknown).contains(L10n.text("资料库所在卷的可用空间暂时未知。")))
        XCTAssertFalse(LibraryStorageReader.describe(unknown).contains(L10n.text("资料库所在卷当前可用：\(L10n.fileSize(0))")))
    }

    func testLibraryRefreshRetiresOldManagedDependencyAudit() async throws {
        let report = try snapshot(validation: true)
        var actions = actions(); actions.scanLibrary = { _ in report }
        let controller = StorageSettingsController(actions: actions, preferences: preferences)
        defer { _ = controller.cancelPending() }
        controller.cleanup()
        await waitUntil { controller.usage != nil && !controller.isBusy }
        controller.refresh()
        XCTAssertNil(controller.usage)
        await waitUntil { controller.libraryUsage != nil && !controller.isBusy }
        XCTAssertNil(controller.usage)
        XCTAssertTrue(texts(controller).contains(L10n.text("托管文件的保留依赖尚未核对。点击“清理可回收文件…”可查看本次范围，确认前不会删除文件。")))
    }
}
