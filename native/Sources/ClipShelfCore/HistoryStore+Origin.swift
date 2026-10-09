import CSQLite
import Foundation

extension HistoryStore {
    /// An installation identifier stored outside logical backups. It is not an authenticated device identity.
    public func localDeviceIdentity(cancellation: HistoryReadCancellation? = nil) throws -> ClipboardOriginDevice {
        try synchronizedRead(cancellation: cancellation) {
            // Schema migration creates the identity; this path only reads the existing row.
            try withReadCancellation(cancellation) { try localDeviceIdentityWithoutLock() }
        }
    }

    public func metadataDevices(cancellation: HistoryReadCancellation? = nil) throws -> [ClipboardOriginDevice] {
        try synchronizedRead(cancellation: cancellation) {
            try withReadCancellation(cancellation) {
                let stamp = try metadataCacheStamp()
                if let stamp, let cached = deviceMetadataCache, cached.stamp == stamp { return cached.value }
                let statement = try prepare("""
                    SELECT origin_device_id, min(coalesce(origin_device_name, 'Mac')) FROM clipboard_records
                    WHERE (is_in_history = 1 OR pinboard_id IS NOT NULL) AND origin_device_id IS NOT NULL AND origin_device_conflict = 0
                    GROUP BY origin_device_id ORDER BY min(coalesce(origin_device_name, 'Mac')), origin_device_id
                    """)
                defer { sqlite3_finalize(statement) }
                var devices: [ClipboardOriginDevice] = []
                while true {
                    try cancellation?.checkCancellation()
                    let status = sqlite3_step(statement)
                    if status == SQLITE_DONE { break }
                    try check(status, allowingRow: true)
                    try cancellation?.checkCancellation()
                    guard let id = textColumn(statement, 0).flatMap(UUID.init(uuidString:)) else { throw HistoryStoreError.invalidStoredRecord }
                    devices.append(ClipboardOriginDevice(id: id, name: textColumn(statement, 1) ?? "Mac"))
                }
                if let stamp, try metadataCacheStamp() == stamp {
                    try cancellation?.checkCancellation()
                    deviceMetadataCache = MetadataCacheEntry(stamp: stamp, value: devices)
                }
                return devices
            }
        }
    }

    func initializeOriginSchema() throws {
        let statement = try prepare("PRAGMA table_info(clipboard_records)")
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW { if let name = textColumn(statement, 1) { columns.insert(name) } }
        sqlite3_finalize(statement)
        for (name, type) in [("origin_device_id", "TEXT"), ("origin_device_name", "TEXT"), ("origin_device_conflict", "INTEGER NOT NULL DEFAULT 0")] where !columns.contains(name) {
            try execute("ALTER TABLE clipboard_records ADD COLUMN \(name) \(type)")
        }
        try execute("""
            CREATE TABLE IF NOT EXISTS local_device_identity(singleton INTEGER PRIMARY KEY CHECK(singleton = 1), device_id TEXT NOT NULL, name TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS clipboard_origin_device ON clipboard_records(origin_device_id, origin_device_conflict);
            """)
        try syncExecute("INSERT OR IGNORE INTO local_device_identity(singleton, device_id, name) VALUES(1, ?, 'Mac')", [UUID().uuidString])
    }

    func localDeviceIdentityWithoutLock() throws -> ClipboardOriginDevice {
        let statement = try prepare("SELECT device_id, name FROM local_device_identity WHERE singleton = 1")
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_step(statement), allowingRow: true)
        guard let id = textColumn(statement, 0).flatMap(UUID.init(uuidString:)), let name = textColumn(statement, 1) else { throw HistoryStoreError.invalidStoredRecord }
        return ClipboardOriginDevice(id: id, name: name)
    }

    func assigningLocalOrigin(_ candidate: ClipboardRecord, preserveOrigin: Bool) throws -> ClipboardRecord {
        var record = candidate
        if recordsLocalOrigin, !preserveOrigin, record.originDeviceID == nil, !record.originDeviceConflict {
            let device = try localDeviceIdentityWithoutLock()
            record.originDeviceID = device.id
            record.originDeviceName = device.name
        }
        return record
    }

    /// A contradictory self-reported origin becomes explicitly unknown/conflicted on every replica.
    /// Once marked, neither old clients omitting fields nor later edits may silently erase the marker.
    func resolvingOrigin(_ incoming: ClipboardRecord, existing: ClipboardRecord?) -> ClipboardRecord {
        guard let existing else { return incoming }
        var result = incoming
        if existing.originDeviceConflict || incoming.originDeviceConflict
            || (existing.originDeviceID != nil && incoming.originDeviceID != nil && existing.originDeviceID != incoming.originDeviceID) {
            result.originDeviceID = nil; result.originDeviceName = nil; result.originDeviceConflict = true
        } else {
            result.originDeviceID = existing.originDeviceID ?? incoming.originDeviceID
            if result.originDeviceID != nil {
                result.originDeviceName = [existing.originDeviceName, incoming.originDeviceName].compactMap { $0 }.min() ?? "Mac"
            }
        }
        return result
    }

    func reconcileRemoteOrigin(_ incoming: ClipboardRecord) throws {
        guard let current = try itemWithoutLock(id: incoming.id) else { return }
        let resolved = resolvingOrigin(incoming, existing: current)
        if current.originDeviceID != resolved.originDeviceID || current.originDeviceName != resolved.originDeviceName
            || current.originDeviceConflict != resolved.originDeviceConflict {
            try syncExecute("UPDATE clipboard_records SET origin_device_id = ?, origin_device_name = ?, origin_device_conflict = ?, revision = revision + 1 WHERE id = ?",
                            [resolved.originDeviceID?.uuidString, resolved.originDeviceName, resolved.originDeviceConflict ? "1" : "0", incoming.id.uuidString])
        }
    }
}
