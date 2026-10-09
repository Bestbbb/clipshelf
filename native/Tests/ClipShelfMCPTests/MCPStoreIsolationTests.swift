import ClipShelfCore
import XCTest

final class MCPStoreIsolationTests: XCTestCase {
    func testFixturesUseIndependentTemporaryHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClipShelfMCPTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("test.sqlite3"))
        let item = try store.record(ClipboardRecord(text: "synthetic MCP fixture"))
        XCTAssertEqual(try store.item(id: item.id)?.text, "synthetic MCP fixture")
        XCTAssertTrue(store.databaseURL.path.hasPrefix(directory.path))
    }
}
