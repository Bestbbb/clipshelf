import CSQLite
import Foundation
import XCTest
@testable import ClipShelfCore

private final class CancellingCoalesceFunction {
    let cancellation: HistoryReadCancellation
    var calls = 0
    init(cancellation: HistoryReadCancellation) { self.cancellation = cancellation }
}

final class MetadataFacetCancellationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-facet-cancellation-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func makeStore() throws -> HistoryStore {
        try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"))
    }

    private func populate(_ store: HistoryStore, device: UUID) throws {
        try store.transaction {
            for index in 0..<2_000 {
                try store.insert(ClipboardRecord(text: "record \(index)", sourceApp: String(format: "App%04d", index),
                    sourceBundleID: "app.shared", originDeviceID: device, originDeviceName: String(format: "Device%04d", index)))
            }
        }
    }

    func testSourceGroupByCancellationDoesNotReplaceCachedCompleteValue() throws {
        let store = try makeStore(), device = UUID()
        try populate(store, device: device)
        XCTAssertEqual(try store.metadataSources(), ["app.shared": "App1999"])
        let previous = try XCTUnwrap(store.sourceMetadataCache)
        _ = try store.record(ClipboardRecord(text: "new source", sourceApp: "ZZ", sourceBundleID: "app.shared"))
        let cancellation = HistoryReadCancellation(), probe = CancellingCoalesceFunction(cancellation: cancellation)
        installCancellingCoalesce(probe, in: store)
        XCTAssertThrowsError(try store.metadataSources(cancellation: cancellation)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertGreaterThanOrEqual(probe.calls, 100)
        XCTAssertLessThan(probe.calls, 2_000, "GROUP BY must retire before examining the complete group")
        XCTAssertEqual(store.sourceMetadataCache?.stamp, previous.stamp)
        XCTAssertEqual(store.sourceMetadataCache?.value, previous.value)
        XCTAssertEqual(sqlite3_get_autocommit(store.database), 1)
        XCTAssertEqual(try store.metadataSources(cancellation: HistoryReadCancellation()), ["app.shared": "ZZ"])
        XCTAssertNotEqual(store.sourceMetadataCache?.stamp, previous.stamp)
        _ = try store.record(ClipboardRecord(text: "post cancellation", sourceApp: "Other", sourceBundleID: "app.other"))
        XCTAssertEqual(try store.metadataSources().count, 2)
        XCTAssertEqual(try store.metadataPage(HistoryQuery(text: "r"), boundary: .last).records.count, 300)
    }

    func testDeviceGroupByCancellationDoesNotReplaceCachedCompleteValue() throws {
        let store = try makeStore(), device = UUID()
        try populate(store, device: device)
        XCTAssertEqual(try store.metadataDevices(), [.init(id: device, name: "Device0000")])
        let previous = try XCTUnwrap(store.deviceMetadataCache)
        _ = try store.record(ClipboardRecord(text: "new device label", originDeviceID: device, originDeviceName: "AAA"))
        let cancellation = HistoryReadCancellation(), probe = CancellingCoalesceFunction(cancellation: cancellation)
        installCancellingCoalesce(probe, in: store)
        XCTAssertThrowsError(try store.metadataDevices(cancellation: cancellation)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertGreaterThanOrEqual(probe.calls, 100)
        XCTAssertLessThan(probe.calls, 2_000, "GROUP BY must retire before examining the complete group")
        XCTAssertEqual(store.deviceMetadataCache?.stamp, previous.stamp)
        XCTAssertEqual(store.deviceMetadataCache?.value, previous.value)
        XCTAssertEqual(sqlite3_get_autocommit(store.database), 1)
        XCTAssertEqual(try store.metadataDevices(cancellation: HistoryReadCancellation()), [.init(id: device, name: "AAA")])
        XCTAssertNotEqual(store.deviceMetadataCache?.stamp, previous.stamp)
        let second = UUID()
        _ = try store.record(ClipboardRecord(text: "post cancellation", originDeviceID: second, originDeviceName: "Other"))
        XCTAssertEqual(Set(try store.metadataDevices().map(\.id)), [device, second])
        XCTAssertEqual(try store.metadataPage(HistoryQuery(text: "r"), boundary: .last).records.count, 300)
    }

    func testAllFacetReadsRejectCancelledTokensEvenWithWarmCachesAndNeverInitializeIdentity() throws {
        let store = try makeStore()
        let board = try store.createPinboard(name: "Board")
        let identity = try store.localDeviceIdentity()
        _ = try store.record(ClipboardRecord(text: "data", sourceApp: "App", sourceBundleID: "app.test",
            originDeviceID: identity.id, originDeviceName: identity.name))
        _ = try store.metadataSources(); _ = try store.metadataDevices()
        let changes = sqlite3_total_changes64(store.database)
        let cancellation = HistoryReadCancellation(); cancellation.cancel()
        XCTAssertThrowsError(try store.pinboards(cancellation: cancellation)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try store.metadataSources(cancellation: cancellation)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try store.metadataDevices(cancellation: cancellation)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try store.localDeviceIdentity(cancellation: cancellation)) { XCTAssertTrue($0 is CancellationError) }
        let fresh = HistoryReadCancellation()
        XCTAssertEqual(try store.pinboards(cancellation: fresh).map(\.id), [board.id])
        XCTAssertEqual(try store.localDeviceIdentity(cancellation: fresh), identity)
        XCTAssertEqual(try store.metadataSources(cancellation: fresh), ["app.test": "App"])
        XCTAssertEqual(try store.metadataDevices(cancellation: fresh), [identity])
        XCTAssertEqual(sqlite3_total_changes64(store.database), changes)
        XCTAssertEqual(sqlite3_get_autocommit(store.database), 1)
    }

    func testAllFacetReadsReleaseTheirProgressCallbackContexts() throws {
        let store = try makeStore()
        let reads: [(HistoryReadCancellation) throws -> Void] = [
            { _ = try store.pinboards(cancellation: $0) },
            { _ = try store.metadataSources(cancellation: $0) },
            { _ = try store.metadataDevices(cancellation: $0) },
            { _ = try store.localDeviceIdentity(cancellation: $0) },
        ]
        for read in reads {
            weak var weakToken: HistoryReadCancellation?
            do {
                let cancellation = HistoryReadCancellation(); weakToken = cancellation
                try read(cancellation)
            }
            XCTAssertNil(weakToken)
        }
        _ = try store.record(ClipboardRecord(text: "connection remains writable"))
    }

    private func installCancellingCoalesce(_ probe: CancellingCoalesceFunction, in store: HistoryStore) {
        // Both aggregate queries evaluate coalesce for every input row. All fixtures belong
        // to one group, so cancellation occurs inside sqlite3_step before any result row returns.
        let status = sqlite3_create_function_v2(store.database, "coalesce", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC,
            Unmanaged.passRetained(probe).toOpaque(), { context, count, values in
                guard let context, let raw = sqlite3_user_data(context) else { return }
                let probe = Unmanaged<CancellingCoalesceFunction>.fromOpaque(raw).takeUnretainedValue()
                probe.calls += 1
                if probe.calls == 100 { probe.cancellation.cancel() }
                for index in 0..<Int(count) {
                    if let value = values?[index], sqlite3_value_type(value) != SQLITE_NULL {
                        sqlite3_result_value(context, value); return
                    }
                }
                sqlite3_result_null(context)
            }, nil, nil, { raw in
                if let raw { Unmanaged<CancellingCoalesceFunction>.fromOpaque(raw).release() }
            })
        XCTAssertEqual(status, SQLITE_OK)
    }
}
