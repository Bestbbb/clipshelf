import AppKit
import XCTest
@testable import ClipShelf
@testable import ClipShelfCore

final class PanelGlobalSelectionTests: XCTestCase {
    @MainActor private func selectAll(_ h: PanelCallbackHarness) throws -> [ClipboardSelectionReference] {
        _ = try h.firstPageAndSelectLast()
        let all = try h.store.selectionSnapshot(try XCTUnwrap(h.requests.last?.0.query)).references
        h.key(0, characters: "a", flags: .command)
        return all
    }

    @MainActor func testAllQueryCopyAndMenuPasteDeleteUseEveryFrozenRecordAcrossPages() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        let all = try selectAll(h)
        XCTAssertEqual(all.count, 1_000)
        try h.store.create(ClipboardRecord(text: "new capture must not join", copiedAt: Date().addingTimeInterval(500)))
        h.panel.refreshPage(); try h.completeLastPage()
        h.panel.perform(NSSelectorFromString("loadMore")); try h.completeLastPage()
        var copied: [UUID] = [], pasted: [UUID] = [], deleted: [UUID] = []
        h.panel.onCopyRecords = { copied = $0.map(\.id) }
        h.panel.onPasteRecords = { records, _ in pasted = records.map(\.id) }
        h.panel.onDeleteRecords = { deleted = $0.map(\.id) }
        h.key(8, characters: "c", flags: .command)
        XCTAssertEqual(copied, all.map(\.id))
        let item = NSMenuItem(); item.representedObject = all[600].id
        h.panel.perform(NSSelectorFromString("pasteFromMenu:"), with: item)
        XCTAssertEqual(pasted, all.map(\.id))
        h.panel.perform(NSSelectorFromString("deleteFromMenu:"), with: item)
        XCTAssertEqual(deleted, all.map(\.id))
    }

    @MainActor func testShiftArrowCrosses300BoundaryAndShrinksFrozenRange() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        let initial = try h.firstPageAndSelectLast()
        let all = try h.store.selectionSnapshot(try XCTUnwrap(h.requests.last?.0.query)).references
        XCTAssertEqual(initial, all[299].id)
        for _ in 0..<351 {
            let count = h.requests.count
            h.key(124, flags: .shift)
            if h.requests.count > count { try h.completeLastPage() }
        }
        var copied: [UUID] = []
        h.panel.onCopyRecords = { copied = $0.map(\.id) }
        h.key(8, characters: "c", flags: .command)
        XCTAssertEqual(copied, Array(all[299...650]).map(\.id))
        for _ in 0..<20 { h.key(123, flags: .shift) }
        h.key(8, characters: "c", flags: .command)
        XCTAssertEqual(copied, Array(all[299...630]).map(\.id))
    }

    @MainActor func testChangedOffscreenMemberRejectsWholeCopyWithoutSubsetOutput() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        let all = try selectAll(h)
        try h.store.delete(id: all[900].id)
        var invoked = false
        h.panel.onCopyRecords = { _ in invoked = true }
        h.panel.onCopy = { _ in invoked = true }
        h.key(8, characters: "c", flags: .command)
        XCTAssertFalse(invoked)
        h.panel.refreshPage(); try h.completeLastPage()
        h.key(36, characters: "\r")
        XCTAssertFalse(invoked)
    }

    @MainActor func testPartialResolverReplyIsRejectedAndLateReplyCannotPasteAfterNewSelection() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        let all = try selectAll(h)
        var reply: ((Result<[ClipboardRecord], Error>) -> Void)?
        h.panel.resolveSelection = { _, completion in reply = completion }
        var invoked = false
        h.panel.onPasteRecords = { _, _ in invoked = true }
        h.key(36, characters: "\r")
        try XCTUnwrap(reply)(.success(try h.store.resolveSelection(Array(all.prefix(300)))))
        XCTAssertFalse(invoked)
        _ = try h.firstPageAndSelectLast()
        h.key(36, characters: "\r")
        let old = try XCTUnwrap(reply)
        h.key(123) // Explicit new choice invalidates the deferred output.
        old(.success(try h.store.resolveSelection([all[299]])))
        XCTAssertFalse(invoked)
    }

    @MainActor func testSelectionSnapshotCannotRestoreOldQueryOrClosedSession() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        _ = try h.firstPageAndSelectLast()
        let all = try h.store.selectionSnapshot(try XCTUnwrap(h.requests.last?.0.query))
        var reply: ((Result<HistorySelectionSnapshot, Error>) -> Void)?
        h.panel.onSelectionSnapshot = { _, completion in reply = completion }
        h.key(0, characters: "a", flags: .command)
        let old = try XCTUnwrap(reply)
        let search: NSSearchField = try h.view(label: "搜索剪贴板历史")
        search.stringValue = "callback item 999"
        h.panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        old(.success(all))
        try h.completeLastPage()
        var received: [ClipboardSelectionReference] = []
        h.panel.resolveSelection = { refs, _ in received = refs }
        h.key(36, characters: "\r"); h.key(36, characters: "\r")
        XCTAssertEqual(received.count, 1)
        h.key(0, characters: "a", flags: .command)
        let closing = try XCTUnwrap(reply)
        h.panel.dismiss(); h.panel.show(metadata: []); try h.completeLastPage()
        closing(.success(all))
        h.key(36, characters: "\r"); h.key(36, characters: "\r")
        XCTAssertEqual(received.count, 1)
    }

    @MainActor func testMoveAndStepUseAllReferencesWithoutHydratingPayloads() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        h.key(0, characters: "a", flags: .command) // Board scope, not the global search.
        let all = try h.store.selectionSnapshot(try XCTUnwrap(h.requests.last?.0.query)).references
        var hydrated = false, stepped: [ClipboardSelectionReference] = [], moved: [ClipboardSelectionReference] = []
        h.panel.resolveSelection = { _, _ in hydrated = true }
        h.panel.onStepSelection = { refs, board, forward, completion in
            stepped = refs
            completion(Result { try h.store.stepSelection(refs, boardID: board, forward: forward).references })
        }
        h.key(124, flags: [.command, .option])
        XCTAssertEqual(stepped, all)
        try h.completeLastPage()
        h.panel.onMoveSelection = { refs, _, _ in moved = refs }
        let item = NSMenuItem(); item.representedObject = ["recordID": all[0].id.uuidString, "boardID": ""]
        h.panel.perform(NSSelectorFromString("moveFromMenu:"), with: item)
        XCTAssertEqual(moved.map(\.id), all.map(\.id))
        XCTAssertFalse(hydrated)
    }

    @MainActor func testLateStepResultCannotReplaceNewQueryPage() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        var reply: ((Result<[ClipboardSelectionReference], Error>) -> Void)?
        var original: [ClipboardSelectionReference] = []
        h.panel.onStepSelection = { refs, _, _, completion in original = refs; reply = completion }
        h.key(124, flags: [.command, .option])
        let old = try XCTUnwrap(reply)
        let search: NSSearchField = try h.view(label: "搜索剪贴板历史")
        search.stringValue = "callback item 999"
        h.panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        let request = try XCTUnwrap(h.requests.last?.0)
        let count = h.requests.count
        old(.success(original))
        XCTAssertEqual(h.requests.count, count)
        XCTAssertEqual(h.requests.last?.0.id, request.id)
        try h.completeLastPage()
    }

    @MainActor func testCardPreparesOneInternalDragWith1000ReferencesWithoutReadingAttachments() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        h.key(0, characters: "a", flags: .command)
        let all = try h.store.selectionSnapshot(try XCTUnwrap(h.requests.last?.0.query)).references
        let collection: NSCollectionView = try h.view(label: "剪贴板搜索结果")
        let item = h.panel.collectionView(collection, itemForRepresentedObjectAt: IndexPath(item: 0, section: 0))
        let card = try XCTUnwrap(item.view.subviews.compactMap { $0 as? ClipboardCardView }.first)
        var hydrated = false
        h.panel.resolveSelection = { _, _ in hydrated = true }
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 40, y: 60), modifierFlags: [], timestamp: 1,
                                      windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        card.mouseDown(with: event)
        XCTAssertEqual(card.draggedReferences, all)
        XCTAssertEqual(ClipboardCardView.orderingDragItems(for: card.draggedReferences).count, 1)
        XCTAssertFalse(hydrated)
        XCTAssertTrue(card.dragOperationMask(for: .outsideApplication).isEmpty)
        card.cancelPendingDrag()
    }

    @MainActor func testSuccessfulReorderUpdatesReferencesAndRebuildsRangeBeforeNextShift() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        let query = try XCTUnwrap(h.requests.last?.0.query)
        let before = try h.store.selectionSnapshot(query).references
        let focus = before[600]
        var snapshots = 0
        h.panel.onSelectionSnapshot = { query, reply in snapshots += 1; reply(Result { try h.store.selectionSnapshot(query) }) }
        h.key(124, flags: .shift)
        XCTAssertEqual(snapshots, 1)
        h.panel.onStepSelection = { refs, board, forward, reply in
            reply(Result { try h.store.stepSelection(refs, boardID: board, forward: forward).references })
        }
        h.key(124, flags: [.command, .option])
        try h.completeLastPage()
        h.key(124, flags: .shift)
        XCTAssertEqual(snapshots, 2, "A successful reorder must not reuse the old universe positions")
        let after = try h.store.selectionSnapshot(query).references
        let anchorIndex = try XCTUnwrap(after.firstIndex { $0.id == focus.id })
        var copied: [ClipboardRecord] = []
        h.panel.onCopyRecords = { copied = $0 }
        h.key(8, characters: "c", flags: .command)
        XCTAssertEqual(copied.map(\.id), Array(after[anchorIndex...anchorIndex + 2]).map(\.id))
        XCTAssertEqual(copied.map(\.revision), Array(after[anchorIndex...anchorIndex + 2]).map(\.revision))
    }

    @MainActor func testExplicitRangeOutsideFrozenUniverseValidatesExistingSelectionFirst() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        let all = try selectAll(h)
        let added = try h.store.create(ClipboardRecord(text: "explicit new capture", copiedAt: Date().addingTimeInterval(500)))
        // A normal refresh preserves the old membership; fetch the new first page explicitly.
        h.panel.refreshPage(); try h.completeLastPage()
        let firstQuery = try XCTUnwrap(h.requests.last?.0.query)
        let fresh = try h.store.selectionSnapshot(firstQuery)
        XCTAssertEqual(fresh.references.first?.id, added.id)
        // Expanding to a new capture validates all existing members before rebuilding the universe.
        var validates = 0
        h.panel.onValidateSelection = { refs, reply in validates += 1; reply(Result { try h.store.validateSelection(refs) }) }
        h.panel.onSelectionSnapshot = { _, reply in reply(.success(fresh)) }
        // Shift to the first visible item is a range action on a new item outside the frozen set.
        h.panel.perform(NSSelectorFromString("loadPreviousPage")); try h.completeLastPage()
        h.key(126, flags: [.command, .shift])
        XCTAssertGreaterThanOrEqual(validates, 1)
        var selected: [ClipboardSelectionReference] = []
        h.panel.resolveSelection = { refs, _ in selected = refs }
        h.key(8, characters: "c", flags: .command)
        XCTAssertTrue(selected.contains { $0.id == added.id })
        XCTAssertTrue(selected.contains { $0.id == all[299].id })
    }

    @MainActor func testStartingNewSelectionSnapshotRetiresPendingMutationReceiptImmediately() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        var mutationReply: ((Result<[ClipboardSelectionReference], Error>) -> Void)?
        var refs: [ClipboardSelectionReference] = []
        h.panel.onStepSelection = { selected, _, _, reply in refs = selected; mutationReply = reply }
        h.key(124, flags: [.command, .option])
        var selectionReply: ((Result<HistorySelectionSnapshot, Error>) -> Void)?
        h.panel.onSelectionSnapshot = { _, reply in selectionReply = reply }
        h.key(0, characters: "a", flags: .command)
        let count = h.requests.count
        try XCTUnwrap(mutationReply)(.success(refs))
        XCTAssertEqual(h.requests.count, count)
        let all = try h.store.selectionSnapshot(try XCTUnwrap(h.requests.last?.0.query))
        try XCTUnwrap(selectionReply)(.success(all))
        var received: [ClipboardSelectionReference] = []
        h.panel.resolveSelection = { selected, _ in received = selected }
        h.key(8, characters: "c", flags: .command)
        XCTAssertEqual(received, all.references)
    }

    @MainActor func testStaleContextMenuNeverOperatesOnUnrelatedCurrentSelection() throws {
        let h = try PanelCallbackHarness(); defer { h.close() }
        _ = try selectAll(h)
        let stale = NSMenuItem(); stale.representedObject = UUID()
        var invoked = false
        h.panel.onPasteRecords = { _, _ in invoked = true }
        h.panel.onCopyRecords = { _ in invoked = true }
        h.panel.onDeleteRecords = { _ in invoked = true }
        h.panel.onMoveSelection = { _, _, _ in invoked = true }
        for action in ["pasteFromMenu:", "copyFromMenu:", "deleteFromMenu:"] {
            h.panel.perform(NSSelectorFromString(action), with: stale)
        }
        stale.representedObject = ["recordID": UUID().uuidString, "boardID": ""]
        h.panel.perform(NSSelectorFromString("moveFromMenu:"), with: stale)
        XCTAssertFalse(invoked)
    }

    func testCrossPageInsertionNeverTreatsWindowHeadOrTailAsWholeBoardBoundary() throws {
        let refs = (0..<1_000).map { _ in ClipboardSelectionReference(id: UUID(), revision: 1) }
        let visible = Array(refs[300..<600]).map(\.id)
        let selection = Array(refs[100..<200])
        XCTAssertThrowsError(try PanelReorderPlan.insertion(references: selection, visibleIDs: visible, at: 0, hasMore: true, hasPrevious: true))
        XCTAssertThrowsError(try PanelReorderPlan.insertion(references: selection, visibleIDs: visible, at: 300, hasMore: true, hasPrevious: true))
        let plan = try PanelReorderPlan.insertion(references: selection, visibleIDs: visible, at: 10, hasMore: true, hasPrevious: true)
        XCTAssertEqual(plan.movingIDs, selection.map(\.id)); XCTAssertEqual(plan.beforeID, refs[310].id)
    }
}
