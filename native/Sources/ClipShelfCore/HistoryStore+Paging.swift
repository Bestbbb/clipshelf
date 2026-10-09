import CSQLite
import Foundation

extension HistoryStore {
    /// Resolves an anchor and reads a bounded page in one SQLite read snapshot. An anchor removed
    /// or filtered out, or a displacement beyond the result, throws recordNotFound instead of selecting another item.
    /// A boundary selects the first/last item of the complete query and cannot be combined with
    /// offset or anchor navigation. Empty boundary results have no focus and an offset of zero.
    public func metadataPage(_ query: HistoryQuery, offset: Int = 0, anchorID: UUID? = nil,
                             displacement: Int = 0, boundary: HistoryPageBoundary? = nil) throws -> HistoryMetadataPage {
        try synchronized {
            if boundary != nil, offset != 0 || anchorID != nil || displacement != 0 {
                throw HistoryStoreError.invalidPageRequest
            }
            guard query.limit > 0 else { return HistoryMetadataPage(records: [], offset: max(0, offset), hasMore: false, focusID: nil) }
            try execute("BEGIN")
            var committed = false
            defer { if !committed { try? execute("ROLLBACK") } }
            let pageSize = min(300, query.limit)
            var start = max(0, offset)
            var target: Int?
            func resultCount() throws -> Int {
                let count = try prepareSearch(query, metadataOnly: true, offset: 0, countOnly: true)
                defer { sqlite3_finalize(count) }
                try check(sqlite3_step(count), allowingRow: true)
                return Int(sqlite3_column_int64(count, 0))
            }
            if boundary == .last {
                // COUNT and the bounded window share the read transaction, so a
                // concurrent insertion/deletion cannot shift the chosen endpoint.
                start = max(0, try resultCount() - pageSize)
            }
            if let anchorID {
                let anchor = try prepareSearch(query, metadataOnly: true, offset: 0, offsetFor: anchorID)
                defer { sqlite3_finalize(anchor) }
                let status = sqlite3_step(anchor)
                guard status != SQLITE_DONE else { throw HistoryStoreError.recordNotFound }
                try check(status, allowingRow: true)
                let (index, overflow) = Int(sqlite3_column_int64(anchor, 0)).addingReportingOverflow(displacement)
                guard !overflow, index >= 0 else { throw HistoryStoreError.recordNotFound }
                target = index
                start = max(0, index - pageSize / 2)
            }
            var bounded = query; bounded.limit = pageSize + 1
            func readWindow(at windowOffset: Int) throws -> [ClipboardRecordMetadata] {
                let statement = try prepareSearch(bounded, metadataOnly: true, offset: windowOffset)
                defer { sqlite3_finalize(statement) }
                var records: [ClipboardRecordMetadata] = []
                while true {
                    let status = sqlite3_step(statement)
                    if status == SQLITE_DONE { return records }
                    try check(status, allowingRow: true)
                    records.append(try decodeMetadata(statement))
                }
            }
            var records = try readWindow(at: start)
            if boundary == nil, anchorID == nil, start > 0, records.isEmpty {
                // Deletions or a narrower filter can invalidate an ordinary page offset. Keep
                // the last bounded window visible without weakening explicit anchor validation.
                let total = try resultCount()
                start = max(0, total - pageSize)
                if total > 0 { records = try readWindow(at: start) }
            }
            let hasMore = records.count > pageSize
            if hasMore { records.removeLast() }
            var focusID: UUID?
            if boundary == .first { focusID = records.first?.id }
            else if boundary == .last { focusID = records.last?.id }
            else if let target {
                guard records.indices.contains(target - start) else { throw HistoryStoreError.recordNotFound }
                focusID = records[target - start].id
            }
            try execute("COMMIT"); committed = true
            return HistoryMetadataPage(records: records, offset: start, hasMore: hasMore, focusID: focusID)
        }
    }
}
