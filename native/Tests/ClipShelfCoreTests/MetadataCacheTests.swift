import CSQLite
import Foundation
import XCTest
@testable import ClipShelfCore

private final class AggregateTrace {
    var sources = 0
    var devices = 0
}

final class MetadataCacheTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-facets-\(UUID().uuidString)") }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func store(_ name: String = "local") throws -> HistoryStore { try HistoryStore(databaseURL: directory.appendingPathComponent(name + "/history.sqlite3")) }
    private func item(_ label: String, device: UUID = UUID()) -> ClipboardRecord {
        ClipboardRecord(text: label, sourceApp: label, sourceBundleID: "app." + label, originDeviceID: device, originDeviceName: "Mac")
    }
    private func trace(_ store: HistoryStore, _ trace: AggregateTrace) {
        sqlite3_trace_v2(store.database, UInt32(SQLITE_TRACE_STMT), { _, context, statement, _ in
            guard let context, let statement, let sql = sqlite3_sql(OpaquePointer(statement)) else { return 0 }
            let trace = Unmanaged<AggregateTrace>.fromOpaque(context).takeUnretainedValue()
            let text = String(cString: sql)
            if text.contains("GROUP BY source_bundle_id") { trace.sources += 1 }
            if text.contains("GROUP BY origin_device_id") { trace.devices += 1 }
            return 0
        }, Unmanaged.passUnretained(trace).toOpaque())
    }

    func testUnchangedReadsReuseAggregatesAndSameConnectionCreateEditDeleteInvalidate() throws {
        let store = try store(), probe = AggregateTrace()
        trace(store, probe); defer { sqlite3_trace_v2(store.database, 0, nil, nil) }
        XCTAssertEqual(try store.metadataSources(), [:]); XCTAssertEqual(try store.metadataDevices(), [])
        for _ in 0..<10 { _ = try store.metadataSources(); _ = try store.metadataDevices() }
        XCTAssertEqual(probe.sources, 1); XCTAssertEqual(probe.devices, 1)
        var record = try store.create(item("First"))
        XCTAssertEqual(try store.metadataSources(), ["app.First": "First"])
        XCTAssertEqual(try store.metadataDevices().map(\.id), [record.originDeviceID!])
        XCTAssertEqual(probe.sources, 2); XCTAssertEqual(probe.devices, 2)
        record.sourceApp = "Renamed"; record.sourceBundleID = "app.Renamed"
        _ = try store.update(record: record)
        XCTAssertEqual(try store.metadataSources(), ["app.Renamed": "Renamed"])
        _ = try store.metadataDevices()
        XCTAssertEqual(probe.sources, 3); XCTAssertEqual(probe.devices, 3)
        try store.delete(id: record.id)
        XCTAssertEqual(try store.metadataSources(), [:]); XCTAssertEqual(try store.metadataDevices(), [])
        XCTAssertEqual(probe.sources, 4); XCTAssertEqual(probe.devices, 4)
    }

    func testSecondConnectionWritesInvalidateBothCachesWithoutLocalChangeCounterMovement() throws {
        let reader = try store(), writer = try store()
        XCTAssertEqual(try reader.metadataSources(), [:]); XCTAssertEqual(try reader.metadataDevices(), [])
        let localChanges = sqlite3_total_changes64(reader.database)
        var remote = try writer.create(item("OtherConnection"))
        XCTAssertEqual(sqlite3_total_changes64(reader.database), localChanges)
        XCTAssertEqual(try reader.metadataSources(), ["app.OtherConnection": "OtherConnection"])
        XCTAssertEqual(try reader.metadataDevices().map(\.id), [remote.originDeviceID!])
        remote.sourceApp = "Changed"; _ = try writer.update(record: remote)
        XCTAssertEqual(try reader.metadataSources(), ["app.OtherConnection": "Changed"])
        try writer.delete(id: remote.id)
        XCTAssertEqual(try reader.metadataSources(), [:]); XCTAssertEqual(try reader.metadataDevices(), [])
    }

    func testTransactionReadsNeverReuseOrPublishUncommittedValuesAndRollbackRestoresResults() throws {
        let store = try store(), probe = AggregateTrace()
        let committed = try store.create(item("Committed"))
        _ = try store.metadataSources(); _ = try store.metadataDevices()
        trace(store, probe); defer { sqlite3_trace_v2(store.database, 0, nil, nil) }
        enum Rollback: Error { case intentional }
        let uncommitted = item("Uncommitted")
        XCTAssertThrowsError(try store.transaction {
            try store.insert(uncommitted)
            for _ in 0..<2 {
                XCTAssertEqual(try store.metadataSources().count, 2)
                XCTAssertEqual(Set(try store.metadataDevices().map(\.id)), [committed.originDeviceID!, uncommitted.originDeviceID!])
            }
            throw Rollback.intentional
        })
        XCTAssertEqual(probe.sources, 2); XCTAssertEqual(probe.devices, 2, "Each transaction read must aggregate, without reusing a cache")
        XCTAssertEqual(try store.metadataSources(), ["app.Committed": "Committed"])
        XCTAssertEqual(try store.metadataDevices().map(\.id), [committed.originDeviceID!])
        XCTAssertEqual(probe.sources, 3); XCTAssertEqual(probe.devices, 3)
        _ = try store.metadataSources(); _ = try store.metadataDevices()
        XCTAssertEqual(probe.sources, 3); XCTAssertEqual(probe.devices, 3)
    }

    func testRestoreAndRemoteOriginConflictInvalidateCachedLists() throws {
        let archiveStore = try store("archive")
        let archived = try archiveStore.create(item("Restored"))
        let backup = directory.appendingPathComponent("facets.clipshelfbackup"); try archiveStore.exportBackup(to: backup)
        let store = try store()
        _ = try store.create(item("Removed")); _ = try store.metadataSources(); _ = try store.metadataDevices()
        _ = try store.restoreBackup(from: backup, mode: .replace)
        XCTAssertEqual(try store.metadataSources(), ["app.Restored": "Restored"])
        XCTAssertEqual(try store.metadataDevices().map(\.id), [archived.originDeviceID!])
        try store.configureSync(accountID: "account", includeLocalData: true)
        let root = try XCTUnwrap(store.pendingSyncOperations(accountID: "account").first { $0.entityID == archived.id })
        var contradictory = archived; contradictory.originDeviceID = UUID()
        let operation = SyncOperation(accountID: "account", entityID: archived.id, entityKind: .clipboard, action: .upsert,
                                      baseRevision: root.revision, revision: root.revision + 1, baseOperationID: root.operationID, record: contradictory)
        _ = try store.metadataDevices()
        try store.applyRemoteChanges(accountID: "account", changes: [operation], nextCursor: nil)
        XCTAssertEqual(try store.metadataDevices(), [])
        XCTAssertEqual(try store.metadataSources(), ["app.Restored": "Restored"])
        XCTAssertEqual(try store.item(id: archived.id)?.originDeviceConflict, true)
    }
}
