import Darwin
import Foundation
import XCTest
@testable import ClipShelfCore

final class StorageUsageTests: XCTestCase {
    private var directory: URL!
    private var profile: URL!

    override func setUpWithError() throws {
        let proposed = FileManager.default.temporaryDirectory.appendingPathComponent("storage-usage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: proposed, withIntermediateDirectories: true)
        let canonical = try XCTUnwrap(realpath(proposed.path, nil))
        directory = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        free(canonical)
        profile = directory.appendingPathComponent("profile", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func scope(_ additional: [StorageUsageRoot] = []) -> StorageUsageScope {
        .init(profileDirectory: profile, databaseName: "history.sqlite", additionalRoots: additional)
    }
    private func write(_ path: String, bytes: Int, under root: URL? = nil) throws -> URL {
        let file = (root ?? profile!).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 42, count: bytes).write(to: file)
        return file
    }
    private func total(_ report: StorageUsageReport, _ category: StorageUsageCategory) -> Int64 {
        report.measurements.filter { $0.category == category }.reduce(0) { $0 + $1.logicalBytes }
    }
    private let blobName = String(repeating: "a", count: 64) + ".blob"

    func testScopePreservesCanonicalPathSpellingForProfileAndAdditionalRoots() throws {
        _ = try write("Backups/archive.bin", bytes: 19)
        _ = try write("OCR/result.json", bytes: 23)
        let cache = profile.appendingPathComponent("OCR", isDirectory: true)
        let root = StorageUsageRoot(id: "ocr", url: cache, category: .ocrCache, scopeKind: .profile)
        let scope = scope([root])
        XCTAssertEqual(scope.profileDirectory.path, profile.path)
        XCTAssertEqual(scope.roots.first?.url?.path, profile.path)
        XCTAssertEqual(root.url?.path, cache.path)
        let report = try StorageUsageScanner.scan(scope: scope)
        XCTAssertFalse(report.isPartial, "\(report.issues)")
        XCTAssertEqual(report.logicalBytes, 42)
        XCTAssertEqual(total(report, .ocrCache), 23)
    }

    func testRootLinksAndParentTraversalAreRejectedInsteadOfStandardizedAway() throws {
        _ = try write("Backups/archive.bin", bytes: 29)
        let alias = directory.appendingPathComponent("profile-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: profile)
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let traversal = URL(fileURLWithPath: nested.path + "/../profile", isDirectory: true)
        for (url, reason) in [(alias, StorageUsageIssueReason.symbolicLink), (traversal, .invalidRoot)] {
            let scope = StorageUsageScope(profileDirectory: url, databaseName: "history.sqlite")
            XCTAssertEqual(scope.profileDirectory.path, url.path)
            XCTAssertEqual(scope.roots.first?.url?.path, url.path)
            let report = try StorageUsageScanner.scan(scope: scope)
            XCTAssertTrue(report.isPartial)
            XCTAssertEqual(report.roots.first?.status, .unavailable)
            XCTAssertTrue(report.issues.contains { $0.reason == reason }, "\(report.issues)")
            XCTAssertEqual(report.logicalBytes, 0)
        }
    }

    func testProfileCategoriesIncludeSidecarsOwnedCopiesCredentialsBackupsAndShareImportsExactlyOnce() throws {
        _ = try write("history.sqlite", bytes: 101)
        _ = try write("history.sqlite-wal", bytes: 102)
        _ = try write("history.sqlite-shm", bytes: 103)
        _ = try write("history.sqlite-journal", bytes: 104)
        _ = try write("history.attachments/" + blobName, bytes: 105)
        let asset = UUID().uuidString
        _ = try write("history.attachments/owned/\(asset)/payload", bytes: 106)
        _ = try write("history.attachments/owned/\(asset)/files/report.txt", bytes: 107)
        _ = try write("history.attachments/owned/.reclamation/\(UUID().uuidString)/\(UUID().uuidString)/payload", bytes: 108)
        _ = try write("history.attachments/owned/.leases/\(UUID().uuidString)", bytes: 109)
        _ = try write(".storage-reservations/receipt.json", bytes: 110)
        _ = try write("Backups/archive.zip", bytes: 111)
        _ = try write("ShareImports/receipt.json", bytes: 112)
        _ = try write(".storage-reservations.lock", bytes: 113)
        let report = try StorageUsageScanner.scan(scope: scope())
        XCTAssertFalse(report.isPartial, "\(report.issues)")
        XCTAssertEqual(total(report, .database), 410)
        XCTAssertEqual(total(report, .representations), 105)
        XCTAssertEqual(total(report, .ownedOriginals), 106)
        XCTAssertEqual(total(report, .ownedOpenCopies), 107)
        XCTAssertEqual(total(report, .ownedQuarantine), 108)
        XCTAssertEqual(total(report, .ownedCredentials), 109)
        XCTAssertEqual(total(report, .storageCredentials), 223)
        XCTAssertEqual(total(report, .backups), 111)
        XCTAssertEqual(total(report, .shareImports), 112)
        XCTAssertEqual(report.logicalBytes, Int64((101...113).reduce(0, +)))
        XCTAssertEqual(report.measurements.reduce(0) { $0 + $1.fileCount }, 13)
        XCTAssertTrue(report.measurements.allSatisfy { !$0.volumeID.isEmpty && $0.allocatedBytes >= 0 })
        XCTAssertGreaterThanOrEqual(report.finishedAt, report.startedAt)
    }

    func testSparseFilesSeparateLogicalAndAllocatedBytes() throws {
        let file = try write("Backups/sparse.bin", bytes: 0)
        let fd = Darwin.open(file.path, O_WRONLY | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(fd, 0); defer { Darwin.close(fd) }
        XCTAssertEqual(ftruncate(fd, 8 * 1_024 * 1_024), 0)
        var metadata = stat(); XCTAssertEqual(fstat(fd, &metadata), 0)
        let report = try StorageUsageScanner.scan(scope: scope())
        let backup = report.measurements.filter { $0.category == .backups }
        XCTAssertEqual(total(report, .backups), 8 * 1_024 * 1_024)
        // The category also includes its directory metadata; inspect the sparse file's
        // independently observed allocation rather than assume an APFS compression ratio.
        XCTAssertLessThan(Int64(metadata.st_blocks) * 512, Int64(metadata.st_size))
        XCTAssertGreaterThanOrEqual(backup.reduce(Int64(0)) { $0 + $1.allocatedBytes }, Int64(metadata.st_blocks) * 512)
    }

    func testExplicitNestedCacheScopesAreExclusiveAndHardLinksDeduplicateAcrossScopesDeterministically() throws {
        let original = try write("history.attachments/" + blobName, bytes: 80)
        _ = try write("OCR/result.json", bytes: 30)
        let shared = directory.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false)
        try FileManager.default.linkItem(at: original, to: shared.appendingPathComponent("hardlink.bin"))
        let roots: [StorageUsageRoot] = [
            .init(id: "profile-ocr", url: profile.appendingPathComponent("OCR"), category: .ocrCache, scopeKind: .profile),
            .init(id: "a-shared", url: shared, category: .imageExports, scopeKind: .sharedCache)
        ]
        for ordered in [roots, roots.reversed().map { $0 }] {
            let report = try StorageUsageScanner.scan(scope: scope(ordered))
            XCTAssertFalse(report.isPartial, "\(report.issues)")
            XCTAssertEqual(report.logicalBytes, 110)
            XCTAssertEqual(total(report, .ocrCache), 30)
            XCTAssertEqual(total(report, .imageExports), 80)
            XCTAssertEqual(total(report, .representations), 0)
            XCTAssertEqual(report.measurements.reduce(0) { $0 + $1.deduplicatedFileCount }, 1)
            XCTAssertEqual(report.measurements.first { $0.category == .ocrCache }?.scopeKind, .profile)
            XCTAssertEqual(report.measurements.first { $0.category == .imageExports }?.scopeKind, .sharedCache)
        }
    }

    func testDuplicateRootCannotDoubleCountOrSilentlyChooseAConflictingCategory() throws {
        _ = try write("OCR/result.json", bytes: 11)
        let cache = profile.appendingPathComponent("OCR")
        let report = try StorageUsageScanner.scan(scope: scope([
            .init(id: "a", url: cache, category: .ocrCache, scopeKind: .profile),
            .init(id: "b", url: cache, category: .imageExports, scopeKind: .sharedCache)
        ]))
        XCTAssertTrue(report.isPartial)
        XCTAssertTrue(report.issues.contains { $0.reason == .overlappingScope })
        XCTAssertEqual(report.logicalBytes, 11)
        XCTAssertEqual(total(report, .ocrCache), 11)
        XCTAssertEqual(total(report, .imageExports), 0)
    }

    func testSymlinksAndExternalClipboardURLsNeverExpandScope() throws {
        let outside = try write("outside/sentinel", bytes: 1_000_000, under: directory)
        let store = try HistoryStore(databaseURL: profile.appendingPathComponent("history.sqlite"))
        _ = try store.record(ClipboardRecord(text: "external reference", parts: [.init(representations: [
            .init(typeIdentifier: "public.file-url", data: Data(outside.absoluteString.utf8))
        ])]))
        let backup = profile.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: backup.appendingPathComponent("link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: backup.appendingPathComponent("directory"), withDestinationURL: outside.deletingLastPathComponent())
        let report = try StorageUsageScanner.scan(scope: store.storageUsageScope())
        XCTAssertTrue(report.isPartial)
        XCTAssertEqual(report.issues.filter { $0.reason == .symbolicLink }.count, 2)
        XCTAssertEqual(total(report, .backups), 0)
        XCTAssertEqual(total(report, .representations), Int64(outside.absoluteString.utf8.count))
        XCTAssertEqual(try Data(contentsOf: outside).count, 1_000_000)
    }

    func testDirectoryReplacementBetweenStatAndOpenDoesNotFollowNewSymlink() throws {
        let inside = try write("Backups/child/original", bytes: 12).deletingLastPathComponent()
        let external = try write("outside/sentinel", bytes: 10_000, under: directory).deletingLastPathComponent()
        let moved = directory.appendingPathComponent("moved")
        var replaced = false
        let report = try StorageUsageScanner.scan(scope: scope(), hooks: .init(willOpenEntry: { url in
            guard url.path == inside.path, !replaced else { return }
            replaced = true
            do {
                try FileManager.default.moveItem(at: inside, to: moved)
                try FileManager.default.createSymbolicLink(at: inside, withDestinationURL: external)
            } catch { XCTFail("Fixture replacement failed: \(error)") }
        }))
        XCTAssertTrue(replaced)
        XCTAssertTrue(report.isPartial)
        XCTAssertTrue(report.issues.contains { $0.reason == .changedDuringScan })
        XCTAssertEqual(total(report, .backups), 0)
    }

    func testActualReclamationRenameDuringTraversalIsPartialAndDoesNotCountOriginalAndQuarantineTwice() throws {
        let store = try HistoryStore(databaseURL: profile.appendingPathComponent("history.sqlite"))
        let storage = store.ownedFileStorage, bytes = Data(repeating: 7, count: 4_096)
        let asset = OwnedFileAsset(id: UUID(), filename: "file.bin", byteCount: bytes.count, sha256: RepresentationStorage.digest(bytes))
        try storage.create(asset, data: bytes, didCreateDirectory: {})
        let candidate = try XCTUnwrap(storage.prepareReclamation(asset))
        var moved = false
        let report = try StorageUsageScanner.scan(scope: store.storageUsageScope(), hooks: .init(didOpenDirectory: { url in
            guard url.path == storage.assetDirectory(asset.id).path, !moved else { return }
            moved = true
            do { _ = try storage.quarantine(candidate, operationID: UUID()) }
            catch { XCTFail("Real GC rename failed: \(error)") }
        }))
        XCTAssertTrue(moved)
        XCTAssertTrue(report.isPartial)
        XCTAssertTrue(report.issues.contains { $0.reason == .changedDuringScan })
        XCTAssertLessThanOrEqual(total(report, .ownedOriginals) + total(report, .ownedOpenCopies) + total(report, .ownedQuarantine), 8_192)
        let stable = try StorageUsageScanner.scan(scope: store.storageUsageScope())
        XCTAssertFalse(stable.isPartial, "\(stable.issues)")
        XCTAssertEqual(total(stable, .ownedQuarantine), 8_192)
        XCTAssertEqual(total(stable, .ownedOriginals), 0)
        XCTAssertEqual(total(stable, .ownedOpenCopies), 0)
    }

    func testPausedFilesystemScanDoesNotHoldTheStoreLockAgainstAnActualSave() throws {
        let store = try HistoryStore(databaseURL: profile.appendingPathComponent("history.sqlite"))
        let scoped = store.storageUsageScope()
        let entered = expectation(description: "filesystem scan paused")
        let saved = expectation(description: "actual SQLite save completed while scan paused")
        let completed = expectation(description: "scan completed")
        let release = DispatchSemaphore(value: 0)
        let hooks = StorageUsageScanHooks(didOpenDirectory: { url in
            guard url.path == scoped.profileDirectory.path else { return }
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
        })
        DispatchQueue.global().async {
            defer { completed.fulfill() }
            do { _ = try StorageUsageScanner.scan(scope: scoped, hooks: hooks) }
            catch { XCTFail("Scan failed: \(error)") }
        }
        wait(for: [entered], timeout: 2)
        DispatchQueue.global().async {
            do { _ = try store.record(ClipboardRecord(text: "save while scanner holds a directory descriptor")) }
            catch { XCTFail("Save failed: \(error)") }
            saved.fulfill()
        }
        wait(for: [saved], timeout: 2)
        release.signal()
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(try store.search(HistoryQuery()).count, 1)
    }

    func testUnknownUnreadableAndTraversalLimitsArePartialRatherThanZeroSuccess() throws {
        _ = try write("unexpected.bin", bytes: 17)
        _ = try write("Backups/deep/child/file", bytes: 21)
        let unknown = try StorageUsageScanner.scan(scope: scope())
        XCTAssertTrue(unknown.isPartial)
        XCTAssertTrue(unknown.issues.contains { $0.reason == .unknownLayout })
        XCTAssertEqual(total(unknown, .unknown), 17)
        for (limits, reason) in [(StorageUsageLimits(maximumEntries: 1), StorageUsageIssueReason.entryLimit),
                                 (.init(maximumDepth: 0), .depthLimit), (.init(maximumDuration: 0), .timeLimit)] {
            let report = try StorageUsageScanner.scan(scope: scope(), limits: limits)
            XCTAssertTrue(report.isPartial)
            XCTAssertTrue(report.issues.contains { $0.reason == reason }, "\(report.issues)")
        }
        if getuid() != 0 {
            let unreadable = try write("Backups/unreadable", bytes: 25)
            XCTAssertEqual(chmod(unreadable.path, 0), 0)
            defer { _ = chmod(unreadable.path, 0o600) }
            let report = try StorageUsageScanner.scan(scope: scope())
            XCTAssertTrue(report.issues.contains { $0.reason == .unreadable && $0.relativePath.hasSuffix("unreadable") })
        }
    }

    func testUnavailableAppGroupAndOptionalAbsentCacheAreExplicitAndNothingIsCreated() throws {
        let absent = directory.appendingPathComponent("missing-cache")
        let report = try StorageUsageScanner.scan(scope: scope([
            .unavailable(id: "group", category: .shareInbox, scopeKind: .appGroup, reason: .notAuthorized),
            .init(id: "cache", url: absent, category: .ocrCache, scopeKind: .sharedCache)
        ]))
        XCTAssertTrue(report.isPartial)
        XCTAssertEqual(report.roots.first { $0.root.id == "group" }?.status, .unavailable)
        XCTAssertEqual(report.roots.first { $0.root.id == "cache" }?.status, .notPresent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
    }

    func testCancellationBeforeAndDuringEnumerationThrowsWithoutMutatingFiles() throws {
        let file = try write("Backups/file", bytes: 100)
        let before = HistoryReadCancellation(); before.cancel()
        XCTAssertThrowsError(try StorageUsageScanner.scan(scope: scope(), cancellation: before)) { XCTAssertTrue($0 is CancellationError) }
        let active = HistoryReadCancellation()
        XCTAssertThrowsError(try StorageUsageScanner.scan(scope: scope(), cancellation: active,
            hooks: .init(didOpenDirectory: { _ in active.cancel() }))) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: file).count, 100)
    }

    func testByteAccountingRejectsNegativeMetadataAndBothMultiplicationAndAggregateOverflow() {
        var totals = StorageUsageTotals()
        XCTAssertNil(totals.append(fileSize: -1, allocatedBlocks: 0, isRegularFile: true))
        XCTAssertNil(totals.append(fileSize: 0, allocatedBlocks: -1, isRegularFile: true))
        XCTAssertNil(totals.append(fileSize: 1, allocatedBlocks: .max, isRegularFile: true))
        XCTAssertEqual(totals.logicalBytes, 0)
        XCTAssertEqual(totals.allocatedBytes, 0)
        XCTAssertNotNil(totals.append(fileSize: .max, allocatedBlocks: 0, isRegularFile: true))
        XCTAssertNil(totals.append(fileSize: 1, allocatedBlocks: 0, isRegularFile: true))
        XCTAssertEqual(totals.logicalBytes, .max)
        var allocated = StorageUsageTotals()
        XCTAssertNotNil(allocated.append(fileSize: 0, allocatedBlocks: Int64.max / 512, isRegularFile: true))
        XCTAssertNil(allocated.append(fileSize: 0, allocatedBlocks: 1, isRegularFile: true))
        XCTAssertEqual(allocated.allocatedBytes, (Int64.max / 512) * 512)
    }
}
