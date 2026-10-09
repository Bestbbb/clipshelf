import AppKit
import ClipShelfCore
import XCTest
@testable import ClipShelf

final class SystemIntegrationTests: XCTestCase {
    @MainActor func testShortcutsDoNotReturnAPDFDisplayTitleAsDocumentText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let runtime = ClipboardIntentRuntime(); runtime.store = store; runtime.enabled = true
        _ = try store.create(ClipboardRecord(text: "PDF display title", parts: [.init(representations: [
            .init(typeIdentifier: "com.adobe.pdf", data: Data("synthetic opaque PDF".utf8))])]))
        XCTAssertThrowsError(try runtime.get(board: nil)) { error in
            guard case ClipboardIntentError.unsupportedContent = error else { return XCTFail("Expected unsupported content") }
        }
    }

    @MainActor func testShortcutsExcludeOldAccountBoardsAndUnpinnedHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"))
        try store.configureSync(accountID: "A")
        let oldBoard = try store.createPinboard(name: "Project")
        let oldOnly = try store.createPinboard(name: "Old account only")
        try store.create(ClipboardRecord(text: "old private pinned", pinboardID: oldBoard.id))
        try store.create(ClipboardRecord(text: "old private unpinned"))
        let beforeA = try store.pendingSyncOperations(accountID: "A")
        try store.configureSync(accountID: "B")
        let current = try store.createPinboard(name: "Project")
        let runtime = ClipboardIntentRuntime(); runtime.store = store; runtime.enabled = true
        _ = try runtime.add(text: "current B input", board: "Project")
        XCTAssertEqual(try runtime.get(board: "Project"), "current B input")
        XCTAssertEqual(try store.search(HistoryQuery(pinboardIDs: [current.id])).count, 1)
        XCTAssertThrowsError(try runtime.add(text: "must not queue for A", board: oldOnly.name))
        XCTAssertThrowsError(try runtime.get(query: "old private", board: nil))
        XCTAssertThrowsError(try runtime.get(board: oldOnly.name))
        try store.configureSync(accountID: "A")
        XCTAssertEqual(try store.pendingSyncOperations(accountID: "A"), beforeA)
    }

    @MainActor func testShortcutsReadCurrentReadOnlyShareButRejectWritesAndRevokedCache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"))
        try store.configureSharing(accountID: "reader")
        let board = Pinboard(name: "Shared read-only")
        let descriptor = SharedBoardDescriptor(boardID: board.id, accountID: "reader", containerIdentifier: "iCloud.test.synthetic",
                                                zoneName: "synthetic", zoneOwnerName: "owner", shareRecordName: "share")
        try store.registerSharedBoard(descriptor, access: .readOnly)
        let item = ClipboardRecord(text: "readable shared fixture", pinboardID: board.id, isInHistory: false)
        let operations = [
            SyncOperation(accountID: descriptor.namespace, entityID: board.id, entityKind: .pinboard, action: .upsert, baseRevision: 0, revision: 1, pinboard: board),
            SyncOperation(accountID: descriptor.namespace, entityID: item.id, entityKind: .clipboard, action: .upsert, baseRevision: 0, revision: 1, record: item),
        ]
        try store.applySharedChanges(boardID: board.id, accountID: "reader", changes: operations, nextCursor: nil)
        let runtime = ClipboardIntentRuntime(); runtime.store = store; runtime.enabled = true
        XCTAssertEqual(try runtime.get(board: board.name), item.text)
        XCTAssertThrowsError(try runtime.add(text: "forbidden write", board: board.name))
        try store.updateSharedAccess(boardID: board.id, accountID: "reader", access: .revoked)
        XCTAssertNotNil(try store.item(id: item.id), "Fixture intentionally retains a revoked cache to verify the read boundary")
        XCTAssertThrowsError(try runtime.get(query: "readable shared", board: nil))
        XCTAssertThrowsError(try runtime.get(board: board.name))
    }

    @MainActor func testShortcutsRequireIndependentOptInAndNeverCreateAmbiguousBoard() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let runtime = ClipboardIntentRuntime()
        runtime.store = store
        XCTAssertThrowsError(try runtime.add(text: "private fixture", board: nil))
        XCTAssertEqual(try store.load().count, 0)
        runtime.enabled = true
        let board = try store.createPinboard(name: "Project", color: "#123456")
        _ = try runtime.add(text: "Find this Chinese 中文 value", board: "Project")
        XCTAssertEqual(try runtime.get(query: "中文", board: "Project"), "Find this Chinese 中文 value")
        XCTAssertEqual(try store.searchMetadata(HistoryQuery(pinboardIDs: [board.id])).count, 1)
        XCTAssertThrowsError(try runtime.add(text: "never inserted", board: "Missing"))
        XCTAssertThrowsError(try runtime.get(board: nil, index: 0))
        runtime.enabled = false
        XCTAssertThrowsError(try runtime.get(board: "Project"))
    }

    @MainActor func testServiceImportsSuppliedPrivatePasteboardAndRejectsConfidentialContent() throws {
        let service = SystemIntegrationController()
        var records: [ClipboardRecord] = []
        service.onImport = { records.append($0) }
        let pasteboard = NSPasteboard(name: .init("clipshelf-service-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("only synthetic text", forType: .string)
        var error: NSString?
        service.addToClipShelf(pasteboard, userData: nil, error: &error)
        XCTAssertNil(error)
        XCTAssertEqual(records.map(\.text), ["only synthetic text"])
        let secret = NSPasteboardItem()
        secret.setString("fixture must be ignored", forType: .string)
        secret.setString("", forType: .init("org.nspasteboard.ConcealedType"))
        pasteboard.clearContents(); pasteboard.writeObjects([secret])
        service.addToClipShelf(pasteboard, userData: nil, error: &error)
        XCTAssertNotNil(error)
        XCTAssertEqual(records.count, 1)
    }

    @MainActor func testExportedImageIsUsableAfterRecordAndHelperAreReleased() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let record = ClipboardRecord(text: "test image", parts: [ClipboardPart(representations: [ClipboardRepresentation(typeIdentifier: "public.png", data: png)])])
        let url = try SystemIntegrationController.exportImage(record, directory: directory)
        XCTAssertEqual(NSImage(contentsOf: url)?.size, NSSize(width: 8, height: 8))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertNotEqual(try SystemIntegrationController.exportImage(record, directory: directory), url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
