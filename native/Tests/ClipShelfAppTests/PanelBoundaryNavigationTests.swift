import AppKit
import XCTest
@testable import ClipShelf
@testable import ClipShelfCore

final class PanelBoundaryNavigationTests: XCTestCase {
    @MainActor private func selected(_ h: PanelCallbackHarness) -> [ClipboardSelectionReference] {
        var received: [ClipboardSelectionReference] = []
        h.panel.resolveSelection = { refs, _ in received = refs }
        h.key(8, characters: "c", flags: .command)
        return received
    }

    @MainActor private func complete(_ h: PanelCallbackHarness,
                                     _ pending: (PanelPageRequest, (Result<PanelHistoryPage, Error>) -> Void)) throws {
        let request = pending.0
        let page = try h.store.metadataPage(request.query, offset: request.offset,
                                          anchorID: request.anchor?.recordID,
                                          displacement: request.anchor?.displacement ?? 0, boundary: request.boundary)
        pending.1(.success(PanelHistoryPage(records: page.records, offset: page.offset,
                                          hasMore: page.hasMore, focusID: page.focusID)))
    }

    @MainActor func testPlainBoundariesSelectWholeQueryEndsWithoutSelectionSnapshot() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        let all = try h.store.selectionSnapshot(try XCTUnwrap(h.requests.last?.0.query)).references
        var snapshots = 0
        h.panel.onSelectionSnapshot = { _, _ in snapshots += 1 }
        h.key(125, flags: .command)
        XCTAssertEqual(h.requests.last?.0.boundary, .last)
        XCTAssertEqual(h.requests.last?.0.offset, 0)
        try h.completeLastPage()
        XCTAssertEqual(selected(h), [all[999]])
        h.key(126, flags: .command)
        XCTAssertEqual(h.requests.last?.0.boundary, .first)
        try h.completeLastPage()
        XCTAssertEqual(selected(h), [all[0]])
        XCTAssertEqual(snapshots, 0)
    }

    @MainActor func testShiftBoundaryKeepsAnchorAndFrozenUniverseWhenNewCaptureArrives() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        _ = try h.firstPageAndSelectLast()
        let all = try h.store.selectionSnapshot(try XCTUnwrap(h.requests.last?.0.query)).references
        h.key(125, flags: [.command, .shift]); try h.completeLastPage()
        XCTAssertEqual(selected(h), Array(all[299...999]))
        let added = try h.store.create(ClipboardRecord(text: "later capture", copiedAt: Date().addingTimeInterval(100)))
        h.key(126, flags: [.command, .shift]); try h.completeLastPage()
        XCTAssertEqual(selected(h), Array(all[0...299]))
        XCTAssertFalse(selected(h).contains { $0.id == added.id })
        h.key(124, flags: .shift)
        XCTAssertEqual(selected(h), Array(all[1...299]), "Range shrinks against the original item 299 anchor")
    }

    @MainActor func testChangedOffscreenRangeMemberRejectsEntireStagedSelection() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        _ = try h.firstPageAndSelectLast()
        let all = try h.store.selectionSnapshot(try XCTUnwrap(h.requests.last?.0.query)).references
        h.key(125, flags: [.command, .shift])
        try h.store.delete(id: all[700].id)
        try h.completeLastPage()
        XCTAssertTrue(selected(h).isEmpty, "No surviving subset may become an output selection")
        let label: NSTextField = try h.view(label: "结果数量与选中项")
        XCTAssertTrue(label.stringValue.contains("已变化"))
    }

    @MainActor func testSecondBoundaryRetiresFirstReplyAndSearchRetiresPendingJump() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        let all = try h.store.selectionSnapshot(try XCTUnwrap(h.requests.last?.0.query)).references
        h.key(125, flags: .command)
        let old = try XCTUnwrap(h.requests.last)
        h.key(126, flags: .command)
        try h.completeLastPage()
        try complete(h, old)
        XCTAssertEqual(selected(h), [all[0]])
        h.key(125, flags: .command)
        let searching = try XCTUnwrap(h.requests.last)
        h.key(3, characters: "f", flags: .command)
        let search: NSSearchField = try h.view(label: "搜索剪贴板历史")
        let responder = h.panel.window?.firstResponder
        try complete(h, searching)
        XCTAssertTrue(h.panel.window?.firstResponder === responder)
        XCTAssertTrue(responder === search || responder === search.currentEditor())
        h.key(36, characters: "\r")
        XCTAssertEqual(selected(h), [all[0]])
    }

    @MainActor func testPendingJumpCannotPasteCopyDeleteOrReorderOldSelection() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        let all = try h.store.selectionSnapshot(try XCTUnwrap(h.requests.last?.0.query)).references
        var pasted: [UUID] = [], deleted = 0, copied = 0, reordered = 0
        h.panel.onPaste = { record, _ in pasted.append(record.id) }
        h.panel.onCopy = { _ in copied += 1 }
        h.panel.onDeleteRecords = { _ in deleted += 1 }
        h.panel.onStepSelection = { _, _, _, _ in reordered += 1 }
        h.key(125, flags: .command)
        let pending = h.requests.last?.0.id
        h.key(36, characters: "\r"); h.key(51)
        h.key(8, characters: "c", flags: .command)
        h.key(18, characters: "1", flags: .command)
        h.key(124, flags: [.command, .option])
        XCTAssertTrue(pasted.isEmpty); XCTAssertEqual(deleted + copied + reordered, 0)
        XCTAssertEqual(h.requests.last?.0.id, pending)
        try h.completeLastPage()
        h.key(36, characters: "\r")
        XCTAssertEqual(pasted, [all[999].id])
    }

    @MainActor func testMouseFocusIntoSearchRetiresJumpBeforeNativeEditingKeys() throws {
        for (code, text, flags) in [(UInt16(49), " ", NSEvent.ModifierFlags()), (51, "", []),
                                    (8, "c", .command), (6, "z", .command)] {
            let h = try PanelCallbackHarness(); defer { h.close() }
            h.key(125, flags: .command)
            let old = try XCTUnwrap(h.requests.last)
            let search: NSSearchField = try h.view(label: "搜索剪贴板历史")
            h.panel.window?.makeFirstResponder(search)
            let responder = h.panel.window?.firstResponder
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                                     timestamp: 1, windowNumber: h.panel.window!.windowNumber, context: nil,
                                                     characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            XCTAssertFalse(h.panel.handleKey(event), "Search editor owns spaces, deletion, copy and undo")
            try complete(h, old)
            XCTAssertTrue(responder === h.panel.window?.firstResponder)
        }
    }

    @MainActor func testLateRangeValidationCannotCommitAfterFocusMovesToSearch() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        _ = try h.firstPageAndSelectLast()
        let original = selected(h)
        var validations = 0, delayed: ((Result<Void, Error>) -> Void)?
        h.panel.onValidateSelection = { _, reply in
            validations += 1
            if validations == 1 { reply(.success(())) } else { delayed = reply }
        }
        h.key(125, flags: [.command, .shift]); try h.completeLastPage()
        let reply = try XCTUnwrap(delayed)
        h.key(3, characters: "f", flags: .command)
        let responder = h.panel.window?.firstResponder
        reply(.success(()))
        XCTAssertTrue(responder === h.panel.window?.firstResponder)
        h.key(36, characters: "\r")
        XCTAssertEqual(selected(h), original)
    }

    @MainActor func testCancellingJumpRetainsQueuedBackgroundRefreshWithoutStealingSearchFocus() async throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        let original = selected(h)
        h.key(125, flags: .command)
        let old = try XCTUnwrap(h.requests.last)
        h.panel.refreshPage()
        let refreshed = expectation(description: "Queued background refresh survives cancellation")
        h.panel.onPageRequest = { [weak h] request, reply in h?.requests.append((request, reply)); refreshed.fulfill() }
        h.key(3, characters: "f", flags: .command)
        let responder = h.panel.window?.firstResponder
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertNil(h.requests.last?.0.boundary)
        XCTAssertEqual(h.requests.last?.0.anchor?.recordID, original.first?.id)
        try h.completeLastPage()
        try complete(h, old)
        XCTAssertTrue(responder === h.panel.window?.firstResponder)
        h.key(36, characters: "\r")
        XCTAssertEqual(selected(h), original)
    }

    @MainActor func testSnapshotWaitingCannotOverrideManualPageNavigation() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        _ = try h.firstPageAndSelectLast()
        let all = try h.store.selectionSnapshot(try XCTUnwrap(h.requests.last?.0.query))
        var reply: ((Result<HistorySelectionSnapshot, Error>) -> Void)?
        h.panel.onSelectionSnapshot = { _, completion in reply = completion }
        h.key(125, flags: [.command, .shift])
        let pending = try XCTUnwrap(reply)
        h.panel.perform(NSSelectorFromString("loadMore"))
        let request = try XCTUnwrap(h.requests.last?.0)
        XCTAssertEqual(request.offset, 300)
        let count = h.requests.count
        pending(.success(all))
        XCTAssertEqual(h.requests.count, count)
        XCTAssertEqual(h.requests.last?.0.id, request.id)
        try h.completeLastPage()
        XCTAssertEqual(selected(h), [all.references[299]])
    }

    @MainActor func testEndpointReplyCannotRestorePreviousSessionOrChangedFilter() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        h.key(125, flags: .command)
        let old = try XCTUnwrap(h.requests.last)
        let search: NSSearchField = try h.view(label: "搜索剪贴板历史")
        search.stringValue = "callback item 42"
        h.panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        try h.completeLastPage()
        let requestID = h.requests.last?.0.id
        try complete(h, old)
        XCTAssertEqual(h.requests.last?.0.id, requestID)
        h.panel.window?.makeFirstResponder(try h.view(label: "剪贴板搜索结果") as NSCollectionView)
        h.key(125, flags: .command)
        let closing = try XCTUnwrap(h.requests.last)
        h.panel.dismiss(); h.panel.show(metadata: []); try h.completeLastPage()
        let reopened = h.requests.last?.0.id
        try complete(h, closing)
        XCTAssertEqual(h.requests.last?.0.id, reopened)
        XCTAssertEqual(search.stringValue, "")
    }

    @MainActor func testEmptyBoundaryClearsOldSelectionAndMalformedFocusLeavesOldPage() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        let initial = selected(h)
        h.key(125, flags: .command)
        let pending = try XCTUnwrap(h.requests.last)
        let incorrect = try h.store.metadataPage(pending.0.query)
        pending.1(.success(PanelHistoryPage(records: incorrect.records, offset: 0, hasMore: true,
                                          focusID: incorrect.records.last?.id)))
        XCTAssertEqual(selected(h), initial)
        h.key(125, flags: .command)
        try XCTUnwrap(h.requests.last).1(.success(PanelHistoryPage(records: [], offset: 0, hasMore: false, focusID: nil)))
        XCTAssertTrue(selected(h).isEmpty)
    }

    @MainActor func testAllFiltersOpensOnSecondSearchAndCancelMakesNoQuery() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        h.panel.presentFilterPopover = { _, _ in }
        let chosen = selected(h), count = h.requests.count
        h.key(3, characters: "f", flags: .command)
        XCTAssertNil(h.panel.allFiltersController)
        h.key(3, characters: "f", flags: .command)
        let filters = try XCTUnwrap(h.panel.allFiltersController)
        XCTAssertEqual(filters.draft.query.pinboardIDs, [h.board.id])
        XCTAssertEqual(h.requests.count, count)
        filters.onCancel?()
        XCTAssertNil(h.panel.allFiltersController)
        XCTAssertEqual(h.requests.count, count)
        h.key(36, characters: "\r")
        XCTAssertEqual(selected(h), chosen)
    }

    @MainActor func testAllFiltersApplyUpdatesAllDimensionsInOneQueryAndRetiresOldDraft() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        h.panel.presentFilterPopover = { _, _ in }
        let search: NSSearchField = try h.view(label: "搜索剪贴板历史")
        search.stringValue = "callback"
        h.panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification)); try h.completeLastPage()
        h.panel.showAllFilters()
        let filters = try XCTUnwrap(h.panel.allFiltersController)
        var draft = filters.draft.query
        draft.kind = .text; draft.sourceBundleID = "synthetic.source"
        draft.deviceFilter = .unknown
        draft.copiedAfter = Date(timeIntervalSince1970: 100); draft.copiedBefore = Date(timeIntervalSince1970: 200)
        draft.pinboardIDs = [h.board.id]; draft.sortOrder = .pinboard
        let count = h.requests.count
        filters.onApply?(draft)
        XCTAssertEqual(h.requests.count, count + 1)
        let query = try XCTUnwrap(h.requests.last?.0.query)
        XCTAssertEqual(query.text, "callback"); XCTAssertEqual(query.kind, .text)
        XCTAssertEqual(query.sourceBundleID, "synthetic.source"); XCTAssertEqual(query.deviceFilter, .unknown)
        XCTAssertEqual(query.copiedAfter, draft.copiedAfter); XCTAssertEqual(query.copiedBefore, draft.copiedBefore)
        XCTAssertEqual(query.pinboardIDs, [h.board.id]); XCTAssertEqual(query.sortOrder, .pinboard)
        XCTAssertEqual(h.requests.last?.0.offset, 0)
        filters.onApply?(HistoryQuery())
        XCTAssertEqual(h.requests.count, count + 1, "A closed draft may never apply twice")
        try h.completeLastPage()
        h.panel.showAllFilters()
        let stale = try XCTUnwrap(h.panel.allFiltersController)
        search.stringValue = "new scope"
        h.panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        let newerCount = h.requests.count
        stale.onApply?(draft)
        XCTAssertEqual(h.requests.count, newerCount)
        XCTAssertEqual(h.requests.last?.0.query.text, "new scope")
    }
}
