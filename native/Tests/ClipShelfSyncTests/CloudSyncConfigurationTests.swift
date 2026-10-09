import Foundation
import XCTest
import ClipShelfCore
@testable import ClipShelf

final class CloudSyncConfigurationTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-cloud-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testMissingConfigurationCannotEnableOrUploadAndPreservesLocalUse() async throws {
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let service = CloudSyncService(store: store, configuration: CloudSyncConfiguration(containerIdentifier: nil))
        let status = await service.configurationStatus()
        guard case .unavailable = status else { return XCTFail("Missing container must be unavailable") }
        do { _ = try await service.enable(); XCTFail("No configured container") } catch { }
        do { _ = try await service.synchronize(); XCTFail("Sync is disabled") } catch { }
        XCTAssertNil(try store.syncConfiguration().accountID)
        try store.record(ClipboardRecord(text: "local remains usable"))
        XCTAssertEqual(try store.load().count, 1)
    }

    func testUnsignedUnknownContainerIsRejectedBeforeCreatingCloudKitContainer() async throws {
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let nonexistent = "iCloud.test.clipshelf." + UUID().uuidString.lowercased()
        XCTAssertFalse(CloudSyncService.hasCloudKitEntitlement(containerIdentifier: nonexistent))
        let service = CloudSyncService(store: store, configuration: CloudSyncConfiguration(containerIdentifier: nonexistent))
        let status = await service.configurationStatus()
        guard case .unavailable = status else { return XCTFail("Unsigned container must be unavailable") }
        do { _ = try await service.enable(includeLocalData: true); XCTFail("Missing entitlement") } catch { }
        XCTAssertNil(try store.syncConfiguration().accountID)
    }

    func testEmptyConfigurationTrimsWhitespaceAndDisableDoesNotEraseHistory() async throws {
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let record = ClipboardRecord(text: "keep locally")
        try store.record(record)
        let service = CloudSyncService(store: store, configuration: CloudSyncConfiguration(containerIdentifier: "  \n"))
        let status = await service.configurationStatus()
        guard case .unavailable = status else { return XCTFail("Blank identifier must be unavailable") }
        try await service.disable()
        XCTAssertEqual(try store.load(), [record])
    }

    func testImmutableOperationEncodingIsStableAcrossDecodeAndRetry() throws {
        let record = ClipboardRecord(text: "same bytes 👩🏽‍💻", rtf: Data([0, 255, 1]))
        let operation = SyncOperation(accountID: "synthetic-account", entityID: record.id, entityKind: .clipboard,
                                      action: .upsert, baseRevision: 0, revision: 1, record: record)
        let first = try CloudSyncService.encodeOperation(operation)
        let decoded = try JSONDecoder().decode(SyncOperation.self, from: first)
        XCTAssertEqual(try CloudSyncService.encodeOperation(decoded), first)
        XCTAssertEqual(CloudSyncService.digest(try CloudSyncService.encodeOperation(decoded)), CloudSyncService.digest(first))
    }
}
