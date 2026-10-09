import CSQLite
import Foundation

public enum HistorySearchIndexStatus: String, Sendable {
    case trigram
    case literalScan
}

extension HistoryStore {
    public func searchIndexStatus() -> HistorySearchIndexStatus {
        synchronized { trigramSearchAvailable ? .trigram : .literalScan }
    }

    /// Keep this expression identical in the verification predicate, view, and index triggers.
    /// SQLite lower() deliberately folds ASCII only; the original text stays untouched.
    static func searchableTextSQL(prefix: String = "") -> String {
        "lower(\(prefix)text || char(10) || coalesce(\(prefix)renamed_title, '') || char(10) || coalesce(\(prefix)ocr_text, '') || char(10) || coalesce(\(prefix)source_app, ''))"
    }

    /// Each quoted term is exactly three Unicode scalars, compatible with FTS5 detail=none.
    /// This is only a candidate filter: the existing instr() predicate verifies the full literal.
    /// Bounded sampling avoids large MATCH expressions for pasted paragraphs or code.
    static func trigramCandidateExpression(_ text: String) -> String? {
        let scalars = text.unicodeScalars.prefix(96).map { scalar in
            (65...90).contains(scalar.value) ? Unicode.Scalar(scalar.value + 32)! : scalar
        }
        guard scalars.count >= 3, !scalars.contains(where: { $0.value == 0 }) else { return nil }
        let last = scalars.count - 3
        let samples = min(8, last + 1)
        var grams: [String] = []
        for sample in 0..<samples {
            let start = samples == 1 ? 0 : sample * last / (samples - 1)
            let gram = String(String.UnicodeScalarView(scalars[start..<(start + 3)]))
            let quoted = "\"" + gram.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            if !grams.contains(quoted) { grams.append(quoted) }
        }
        return grams.joined(separator: " AND ")
    }

    /// Runs within migration's write transaction. Unsupported system SQLite remains usable via
    /// literal scanning, and a later capable runtime rebuilds changes made while indexing was off.
    func initializeSearchIndex(capabilityOverride: Bool? = nil) throws {
        let available = try capabilityOverride ?? supportsTrigramSearch()
        try execute("""
            CREATE TABLE IF NOT EXISTS search_index_state(singleton INTEGER PRIMARY KEY CHECK(singleton = 1), needs_rebuild INTEGER NOT NULL);
            INSERT OR IGNORE INTO search_index_state(singleton, needs_rebuild) VALUES(1, 1);
            DROP TRIGGER IF EXISTS clipboard_search_insert;
            DROP TRIGGER IF EXISTS clipboard_search_update;
            DROP TRIGGER IF EXISTS clipboard_search_delete;
            """)
        guard available else {
            try execute("UPDATE search_index_state SET needs_rebuild = 1 WHERE singleton = 1")
            trigramSearchAvailable = false
            return
        }
        let existed = try syncScalar("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'clipboard_search'", []) != nil
        try execute("""
            CREATE VIEW IF NOT EXISTS clipboard_search_documents AS
                SELECT rowid, \(Self.searchableTextSQL()) AS body FROM clipboard_records;
            CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_search USING fts5(
                body, content='clipboard_search_documents', content_rowid='rowid',
                tokenize='trigram case_sensitive 1', detail=none, columnsize=0
            );
            INSERT INTO clipboard_search(clipboard_search, rank) VALUES('secure-delete', 1);
            CREATE TRIGGER clipboard_search_insert AFTER INSERT ON clipboard_records BEGIN
                INSERT INTO clipboard_search(rowid, body) VALUES(new.rowid, \(Self.searchableTextSQL(prefix: "new.")));
            END;
            CREATE TRIGGER clipboard_search_delete AFTER DELETE ON clipboard_records BEGIN
                INSERT INTO clipboard_search(clipboard_search, rowid, body) VALUES('delete', old.rowid, \(Self.searchableTextSQL(prefix: "old.")));
            END;
            CREATE TRIGGER clipboard_search_update AFTER UPDATE OF text, renamed_title, ocr_text, source_app ON clipboard_records
                WHEN new.text IS NOT old.text OR new.renamed_title IS NOT old.renamed_title
                    OR new.ocr_text IS NOT old.ocr_text OR new.source_app IS NOT old.source_app BEGIN
                INSERT INTO clipboard_search(clipboard_search, rowid, body) VALUES('delete', old.rowid, \(Self.searchableTextSQL(prefix: "old.")));
                INSERT INTO clipboard_search(rowid, body) VALUES(new.rowid, \(Self.searchableTextSQL(prefix: "new.")));
            END;
            """)
        let needsRebuild = try syncScalar("SELECT needs_rebuild FROM search_index_state WHERE singleton = 1", []) == "1"
        if !existed || needsRebuild {
            try execute("INSERT INTO clipboard_search(clipboard_search) VALUES('rebuild')")
            try execute("UPDATE search_index_state SET needs_rebuild = 0 WHERE singleton = 1")
        }
        trigramSearchAvailable = true
    }

    func supportsTrigramSearch() throws -> Bool {
        // FTS secure-delete requires SQLite 3.42; older runtimes retain the correct scan path.
        guard sqlite3_libversion_number() >= 3_042_000 else { return false }
        do {
            try execute("CREATE VIRTUAL TABLE temp.clipshelf_search_probe USING fts5(body, tokenize='trigram case_sensitive 1', detail=none, columnsize=0)")
            defer { try? execute("DROP TABLE temp.clipshelf_search_probe") }
            // Secure deletion keeps removed terms out of live FTS index segments as well as free pages.
            try execute("INSERT INTO temp.clipshelf_search_probe(clipshelf_search_probe, rank) VALUES('secure-delete', 1)")
            return true
        } catch HistoryStoreError.database(let code, let message) {
            let unsupported = message.contains("no such module") || message.contains("no such tokenizer")
                || message.contains("error in tokenizer constructor") || message.contains("unrecognized option")
            if code & 0xff == SQLITE_ERROR, unsupported { return false }
            throw HistoryStoreError.database(code: code, message: message)
        }
    }
}
