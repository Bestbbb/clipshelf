import AppKit
import XCTest
@testable import ClipShelf
@testable import ClipShelfCore

/// Exercises real controller callbacks without ordering a window onto the desktop.
@MainActor final class UnshownTestPanel: NSPanel {
    private var logicallyVisible = false
    override var isVisible: Bool { logicallyVisible }
    override func makeKeyAndOrderFront(_ sender: Any?) { logicallyVisible = true }
    override func makeKey() {}
    override func orderOut(_ sender: Any?) { logicallyVisible = false }
}

@MainActor final class PanelCallbackHarness {
    let panel: ClipboardPanelController
    let directory: URL
    let store: HistoryStore
    let board: Pinboard
    var requests: [(PanelPageRequest, (Result<PanelHistoryPage, Error>) -> Void)] = []
    var reorderReplies: [(Result<Void, Error>) -> Void] = []

    init(layoutDirection: NSUserInterfaceLayoutDirection? = nil) throws {
        panel = ClipboardPanelController(layoutDirection: layoutDirection)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-panel-callback-\(UUID().uuidString)")
        store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        board = try store.createPinboard(name: "Synthetic callbacks")
        try store.transaction {
            for index in 0..<1_000 {
                try store.insert(ClipboardRecord(text: "callback item \(index)", pinboardID: board.id, pinboardOrder: Int64(index)))
            }
        }
        let unshown = UnshownTestPanel(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 430),
                                       styleMask: .borderless, backing: .buffered, defer: false)
        unshown.contentView = panel.window?.contentView
        unshown.delegate = panel
        panel.window = unshown
        panel.onPageRequest = { [weak self] request, reply in self?.requests.append((request, reply)) }
        panel.onReorderRecords = { [weak self] _, _, _, _, reply in self?.reorderReplies.append(reply) }
        panel.resolveRecord = { [weak self] id, reply in reply(try? self?.store.item(id: id)) }
        panel.onSelectionSnapshot = { [store] query, reply in reply(Result { try store.selectionSnapshot(query) }) }
        panel.onValidateSelection = { [store] refs, reply in reply(Result { try store.validateSelection(refs) }) }
        panel.resolveSelection = { [store] refs, reply in reply(Result { try store.resolveSelection(refs) }) }
        panel.setPinboards([board])
        panel.setDevices([], localDeviceID: UUID())
        panel.show(metadata: [])
        try completeLastPage()
        let boards: NSPopUpButton = try view(label: "分组")
        boards.selectItem(at: 1)
        panel.perform(NSSelectorFromString("boardChanged"))
        try completeLastPage()
        for _ in 0..<2 {
            panel.perform(NSSelectorFromString("loadMore"))
            try completeLastPage()
        }
        XCTAssertEqual(requests.last?.0.offset, 600)
        panel.window?.makeFirstResponder(try view(label: "剪贴板搜索结果") as NSCollectionView)
        key(layoutDirection == .rightToLeft ? 123 : 124) // Select the first logical card in the new window.
    }

    func view<T: NSView>(label: String) throws -> T {
        func find(_ candidate: NSView) -> T? {
            if let typed = candidate as? T, typed.accessibilityLabel() == label { return typed }
            return candidate.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(panel.window?.contentView.flatMap(find))
    }

    func completeLastPage() throws {
        let (request, reply) = try XCTUnwrap(requests.last)
        do {
            let page = try store.metadataPage(request.query, offset: request.offset,
                                              anchorID: request.anchor?.recordID, displacement: request.anchor?.displacement ?? 0,
                                              boundary: request.boundary)
            reply(.success(PanelHistoryPage(records: page.records, offset: page.offset, hasMore: page.hasMore, focusID: page.focusID)))
        } catch { reply(.failure(error)) }
    }

    func startReorder() throws -> (Result<Void, Error>) -> Void {
        panel.perform(NSSelectorFromString("moveItemsLater"))
        return try XCTUnwrap(reorderReplies.last)
    }

    func key(_ code: UInt16, characters: String = "", flags: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1,
                                    windowNumber: panel.window!.windowNumber, context: nil,
                                    characters: characters, charactersIgnoringModifiers: characters,
                                    isARepeat: false, keyCode: code)!
        _ = panel.handleKey(event)
    }

    func firstPageAndSelectLast() throws -> UUID {
        panel.perform(NSSelectorFromString("clearFilters"))
        try completeLastPage()
        let page = try store.metadataPage(try XCTUnwrap(requests.last?.0.query))
        panel.window?.makeFirstResponder(try view(label: "剪贴板搜索结果") as NSCollectionView)
        for _ in 1..<page.records.count { key(124) } // Fixture selects item 299 without a global boundary jump.
        return try XCTUnwrap(page.records.last?.id)
    }

    func close() {
        panel.dismiss()
        try? FileManager.default.removeItem(at: directory)
    }
}

final class PanelCallbackOrderingTests: XCTestCase {
    @MainActor func testOldReorderCannotReplaceNewSearchWithDeepOffset() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        let reorder = try h.startReorder()
        let search: NSSearchField = try h.view(label: "搜索剪贴板历史")
        search.stringValue = "callback item 750"
        h.panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        let pending = try XCTUnwrap(h.requests.last?.0)
        XCTAssertEqual(pending.offset, 0)
        let count = h.requests.count
        reorder(.success(()))
        XCTAssertEqual(h.requests.count, count, "Old reorder completion must not issue a replacement request")
        XCTAssertEqual(h.requests.last?.0.id, pending.id)
        try h.completeLastPage()
        XCTAssertEqual(h.requests.count, count)
    }

    @MainActor func testOldReorderFailureCannotReplaceNewDeviceQuery() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        let reorder = try h.startReorder()
        let device: NSPopUpButton = try h.view(label: "按最初采集设备筛选")
        device.select(try XCTUnwrap(device.itemArray.first { $0.representedObject as? String == "unknown" }))
        h.panel.perform(NSSelectorFromString("deviceChanged"))
        let pending = try XCTUnwrap(h.requests.last?.0)
        XCTAssertEqual(pending.offset, 0)
        let count = h.requests.count
        reorder(.failure(HistoryStoreError.staleRevision))
        XCTAssertEqual(h.requests.count, count)
        XCTAssertEqual(h.requests.last?.0.id, pending.id)
        try h.completeLastPage()
    }

    @MainActor func testOldReorderCannotInterruptNavigationWithinSameQuery() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        let reorder = try h.startReorder()
        h.panel.perform(NSSelectorFromString("loadMore"))
        let pending = try XCTUnwrap(h.requests.last?.0)
        XCTAssertEqual(pending.offset, 900)
        let count = h.requests.count
        reorder(.success(()))
        XCTAssertEqual(h.requests.count, count)
        XCTAssertEqual(h.requests.last?.0.id, pending.id)
        try h.completeLastPage()
    }

    @MainActor func testOldReorderAfterDismissAndReopenCannotRefreshNewSession() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        let reorder = try h.startReorder()
        h.panel.dismiss()
        h.panel.show(metadata: [])
        let pending = try XCTUnwrap(h.requests.last?.0)
        XCTAssertEqual(pending.offset, 0)
        let count = h.requests.count
        reorder(.success(()))
        XCTAssertEqual(h.requests.count, count)
        XCTAssertEqual(h.requests.last?.0.id, pending.id)
        try h.completeLastPage()
    }

    @MainActor func testBackgroundRefreshKeepsPageEndSelectionWhenNewRecordIsPrepended() async throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        let selectedID = try h.firstPageAndSelectLast()
        try h.store.create(ClipboardRecord(text: "new first item", copiedAt: Date().addingTimeInterval(100)))
        h.panel.refreshPage()
        XCTAssertEqual(h.requests.last?.0.anchor?.recordID, selectedID)
        try h.completeLastPage()
        let pasted = expectation(description: "Return resolves the same original selection")
        h.panel.onPaste = { record, _ in XCTAssertEqual(record.id, selectedID); pasted.fulfill() }
        h.key(36, characters: "\r")
        await fulfillment(of: [pasted], timeout: 2)
    }

    @MainActor func testBackgroundRefreshPreservesGlobalMultiSelectionAndSearchFocus() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        _ = try h.firstPageAndSelectLast()
        let expected = Set(try h.store.metadataPage(try XCTUnwrap(h.requests.last?.0.query)).records.map(\.id))
        h.key(0, characters: "a", flags: .command)
        h.key(3, characters: "f", flags: .command)
        let focused = h.panel.window?.firstResponder
        try h.store.create(ClipboardRecord(text: "new first item", copiedAt: Date().addingTimeInterval(100)))
        h.panel.refreshPage()
        XCTAssertEqual(h.requests.last?.0.anchor?.displacement, -149)
        try h.completeLastPage()
        XCTAssertTrue(h.panel.window?.firstResponder === focused, "Background page loading must not steal search focus")
        let request = try XCTUnwrap(h.requests.last?.0)
        let current = try h.store.metadataPage(request.query, offset: request.offset,
                                               anchorID: request.anchor?.recordID, displacement: request.anchor?.displacement ?? 0)
        XCTAssertEqual(Set(current.records.map(\.id)), expected)
        func labels(_ view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels)
        }
        XCTAssertTrue(try XCTUnwrap(h.panel.window?.contentView).subviews.flatMap(labels).contains { $0.contains("已选 1000 条") })
    }

    @MainActor func testDeletedBackgroundAnchorFallsBackOnceAndCancelsSelection() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        let selectedID = try h.firstPageAndSelectLast()
        try h.store.delete(id: selectedID)
        h.panel.refreshPage()
        let count = h.requests.count
        try h.completeLastPage()
        XCTAssertEqual(h.requests.count, count + 1)
        XCTAssertNil(h.requests.last?.0.anchor)
        try h.completeLastPage()
        XCTAssertEqual(h.requests.count, count + 1)
        var invoked = false
        h.panel.onPaste = { _, _ in invoked = true }
        h.key(36, characters: "\r")
        XCTAssertFalse(invoked)
        // No selection means Cmd-G cannot create a misleading replacement target either.
        h.key(5, characters: "g", flags: .command)
        XCTAssertEqual(h.requests.count, count + 1)
    }

    @MainActor func testStrictLocateDoesNotUseBackgroundFallbackWhenAnchorDisappears() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        let selectedID = try h.firstPageAndSelectLast()
        h.key(5, characters: "g", flags: .command)
        XCTAssertEqual(h.requests.last?.0.anchor?.recordID, selectedID)
        try h.store.delete(id: selectedID)
        let count = h.requests.count
        try h.completeLastPage()
        XCTAssertEqual(h.requests.count, count)
        h.panel.refreshPage()
        XCTAssertEqual(h.requests.count, count, "A failed new query must not anchor old selection into the new conditions")
    }
}
