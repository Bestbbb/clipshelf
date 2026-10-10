import AppKit
import XCTest
@testable import ClipShelf
@testable import ClipShelfCore

/// Keeps ordinary cases small; only the deep-page case crosses the real 300-item boundary.
@MainActor private final class UndoPresentationHarness {
    let panel = ClipboardPanelController()
    let directory: URL
    let store: HistoryStore
    var requests: [(PanelPageRequest, (Result<PanelHistoryPage, Error>) -> Void)] = []

    init(count: Int = 7) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-undo-presentation-\(UUID())")
        store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        try store.configureSync(accountID: "test-account")
        try store.transaction {
            for index in 0..<count { try store.insert(ClipboardRecord(text: "undo fixture \(index)")) }
        }
        let unshown = UnshownTestPanel(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 430),
                                       styleMask: .borderless, backing: .buffered, defer: false)
        unshown.contentView = panel.window?.contentView
        unshown.delegate = panel
        panel.window = unshown
        panel.onPageRequest = { [weak self] request, completion in self?.requests.append((request, completion)) }
        panel.onSelectionSnapshot = { [store] query, completion in completion(Result { try store.selectionSnapshot(query) }) }
        panel.onValidateSelection = { [store] refs, completion in completion(Result { try store.validateSelection(refs) }) }
        panel.resolveSelection = { [store] refs, completion in completion(Result { try store.resolveSelection(refs) }) }
        panel.resolveRecord = { [store] id, completion in completion(try? store.item(id: id)) }
        panel.show(metadata: [])
        try completeLastPage()
        try focusResults()
    }

    func view<T: NSView>(label: String) throws -> T {
        func find(_ candidate: NSView) -> T? {
            if let typed = candidate as? T, typed.accessibilityLabel() == label { return typed }
            return candidate.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(panel.window?.contentView.flatMap(find))
    }

    func focusResults() throws { panel.window?.makeFirstResponder(try view(label: "剪贴板搜索结果") as NSCollectionView) }

    func page(_ request: PanelPageRequest) throws -> PanelHistoryPage {
        let page = try store.metadataPage(request.query, offset: request.offset,
                                          anchorID: request.anchor?.recordID, displacement: request.anchor?.displacement ?? 0,
                                          boundary: request.boundary)
        return PanelHistoryPage(records: page.records, offset: page.offset, hasMore: page.hasMore, focusID: page.focusID)
    }

    func completeLastPage() throws {
        let (request, reply) = try XCTUnwrap(requests.last)
        reply(Result { try page(request) })
    }

    func references() throws -> [ClipboardSelectionReference] {
        try store.selectionSnapshot(try XCTUnwrap(requests.last?.0.query)).references
    }

    func copiedIDs() -> [UUID] {
        var received: [UUID] = []
        panel.onCopyRecords = { received = $0.map(\.id) }
        panel.onCopy = { received = [$0.id] }
        key(8, characters: "c", flags: .command)
        return received
    }

    func search(_ text: String) throws {
        let search: NSSearchField = try view(label: "搜索剪贴板历史")
        search.stringValue = text
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }

    func key(_ code: UInt16, characters: String = "", flags: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1,
                                    windowNumber: panel.window!.windowNumber, context: nil, characters: characters,
                                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        _ = panel.handleKey(event)
    }

    func close() { panel.dismiss(); try? FileManager.default.removeItem(at: directory) }
}

final class PanelUndoPresentationTests: XCTestCase {
    @MainActor func testCommittedRestoreSelectsEveryReplacementIdentityInCurrentQueryOrder() throws {
        let h = try UndoPresentationHarness(); defer { h.close() }
        let originalReferences = try h.references()
        let deleted = try h.store.resolveSelection([originalReferences[4], originalReferences[2]])
        let undo = try h.store.deleteSelection(deleted.map { .init(id: $0.id, revision: $0.revision) })
        let present = h.panel.captureUndoPresentation()
        let receipt = try h.store.restoreDeletedSelection(deleted, undo: undo)
        present(receipt.references)
        let expected = try h.references().filter { Set(receipt.references.map(\.id)).contains($0.id) }
        XCTAssertEqual(h.requests.last?.0.anchor?.recordID, expected.first?.id)
        XCTAssertEqual(h.requests.last?.0.anchor?.displacement, 0)
        try h.completeLastPage()
        XCTAssertEqual(h.copiedIDs(), expected.map(\.id))
        XCTAssertEqual(expected.count, 2)
        XCTAssertTrue(Set(expected.map(\.id)).isDisjoint(with: Set(deleted.map(\.id))))
    }

    @MainActor func testRestoredDeepHistoryUsesIdentityAnchorInsteadOfReturningToFirstPage() throws {
        let h = try UndoPresentationHarness(count: 307); defer { h.close() }
        let all = try h.references()
        let original = try XCTUnwrap(h.store.resolveSelection([all[303]]).first)
        let undo = try h.store.deleteSelection([.init(id: original.id, revision: original.revision)])
        let present = h.panel.captureUndoPresentation()
        let receipt = try h.store.restoreDeletedSelection([original], undo: undo)
        present(receipt.references)
        let request = try XCTUnwrap(h.requests.last?.0)
        let replacement = try XCTUnwrap(receipt.references.first)
        XCTAssertEqual(request.anchor?.recordID, replacement.id)
        XCTAssertEqual(request.anchor?.displacement, 0)
        let page = try h.page(request)
        XCTAssertGreaterThan(page.offset, 0)
        XCTAssertEqual(page.focusID, replacement.id)
        XCTAssertTrue(page.records.contains { $0.id == replacement.id })
        try h.completeLastPage()
        XCTAssertEqual(h.copiedIDs(), [replacement.id])
        XCTAssertEqual(try h.references().firstIndex { $0.id == replacement.id }, 303)
    }

    @MainActor func testObsoletePresentationCannotRefreshNewQuerySelectionOrReopenedSession() throws {
        for change in ["query", "selection", "reopen"] {
            let h = try UndoPresentationHarness(); defer { h.close() }
            let all = try h.references()
            let present = h.panel.captureUndoPresentation()
            switch change {
            case "query": try h.search("undo fixture 1"); try h.completeLastPage(); try h.focusResults()
            case "selection": h.key(124)
            default: h.panel.dismiss(); h.panel.show(metadata: []); try h.completeLastPage(); try h.focusResults()
            }
            let before = h.copiedIDs()
            let requestCount = h.requests.count
            var snapshots = 0
            h.panel.onSelectionSnapshot = { _, _ in snapshots += 1 }
            present([all[4]])
            XCTAssertEqual(h.requests.count, requestCount, "Stale \(change) callback must not refresh a newer view")
            XCTAssertEqual(snapshots, 0)
            XCTAssertEqual(h.copiedIDs(), before)
        }
    }

    @MainActor func testPresentationSnapshotAndPageCallbacksAreConsumedOnlyOnce() throws {
        let h = try UndoPresentationHarness(); defer { h.close() }
        let all = try h.references(), selected = [all[3], all[5]]
        var snapshots: [(Result<HistorySelectionSnapshot, Error>) -> Void] = []
        h.panel.onSelectionSnapshot = { _, completion in snapshots.append(completion) }
        let present = h.panel.captureUndoPresentation(), initialRequests = h.requests.count
        present(selected)
        present([all[1]])
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(h.requests.count, initialRequests)
        let reply = try XCTUnwrap(snapshots.first)
        reply(.success(.init(references: all)))
        XCTAssertEqual(h.requests.count, initialRequests + 1)
        let request = try XCTUnwrap(h.requests.last)
        reply(.success(.init(references: [all[1]])))
        XCTAssertEqual(h.requests.count, initialRequests + 1)
        request.1(.success(try h.page(request.0)))
        XCTAssertEqual(h.copiedIDs(), selected.map(\.id))
        h.key(124)
        let changed = h.copiedIDs()
        XCTAssertNotEqual(changed, selected.map(\.id))
        request.1(.success(try h.page(request.0)))
        present(selected)
        XCTAssertEqual(h.copiedIDs(), changed)
        XCTAssertEqual(h.requests.count, initialRequests + 1)
    }

    @MainActor func testLateSnapshotCannotOverrideNewQueryOrSelection() throws {
        for change in ["query", "selection", "dismiss"] {
            let h = try UndoPresentationHarness(); defer { h.close() }
            let all = try h.references()
            var reply: ((Result<HistorySelectionSnapshot, Error>) -> Void)?
            h.panel.onSelectionSnapshot = { _, completion in reply = completion }
            h.panel.captureUndoPresentation()([all[4]])
            switch change {
            case "query": try h.search("undo fixture 2"); try h.completeLastPage(); try h.focusResults()
            case "selection": h.key(124)
            default: h.panel.dismiss()
            }
            let before = h.copiedIDs(), requests = h.requests.count
            try XCTUnwrap(reply)(.success(.init(references: all)))
            XCTAssertEqual(h.requests.count, requests)
            XCTAssertEqual(h.copiedIDs(), before)
        }
    }

    @MainActor func testLateAnchoredPageCannotOverrideNewSearchOrReopenedSession() throws {
        for change in ["query", "reopen"] {
            let h = try UndoPresentationHarness(); defer { h.close() }
            let all = try h.references()
            h.panel.captureUndoPresentation()([all[4]])
            let old = try XCTUnwrap(h.requests.last)
            let oldPage = try h.page(old.0)
            if change == "query" { try h.search("undo fixture 3") }
            else { h.panel.dismiss(); h.panel.show(metadata: []) }
            try h.completeLastPage(); try h.focusResults()
            let before = h.copiedIDs(), request = try XCTUnwrap(h.requests.last?.0.id)
            old.1(.success(oldPage))
            XCTAssertEqual(h.requests.last?.0.id, request)
            XCTAssertEqual(h.copiedIDs(), before)
        }
    }

    @MainActor func testMissingMemberRejectsWholeRestoredSelectionAndConsumesPresentation() throws {
        let h = try UndoPresentationHarness(); defer { h.close() }
        let all = try h.references()
        var snapshots = 0
        h.panel.onSelectionSnapshot = { _, completion in
            snapshots += 1
            completion(.success(.init(references: all.filter { $0.id != all[5].id })))
        }
        let present = h.panel.captureUndoPresentation()
        present([all[3], all[5]])
        XCTAssertEqual(snapshots, 1)
        XCTAssertNotEqual(h.requests.last?.0.anchor?.recordID, all[3].id, "A surviving subset must not be staged")
        try h.completeLastPage()
        XCTAssertTrue(h.copiedIDs().isEmpty)
        let count = h.requests.count
        present([all[3]])
        XCTAssertEqual(snapshots, 1)
        XCTAssertEqual(h.requests.count, count)
    }

    @MainActor func testSnapshotPageAndValidationFailureNeverAdoptPartialOrLateSuccess() throws {
        for stage in ["snapshot", "page", "validation"] {
            let h = try UndoPresentationHarness(); defer { h.close() }
            let all = try h.references(), selected = [all[2], all[4]]
            var snapshot: ((Result<HistorySelectionSnapshot, Error>) -> Void)?
            var validation: ((Result<Void, Error>) -> Void)?
            if stage == "snapshot" { h.panel.onSelectionSnapshot = { _, reply in snapshot = reply } }
            if stage == "validation" { h.panel.onValidateSelection = { _, reply in validation = reply } }
            let previous = h.copiedIDs()
            let present = h.panel.captureUndoPresentation()
            present(selected)
            if stage == "snapshot" {
                let reply = try XCTUnwrap(snapshot)
                reply(.failure(HistoryStoreError.database(code: 10, message: "synthetic snapshot IO error")))
                let count = h.requests.count
                reply(.success(.init(references: all)))
                XCTAssertEqual(h.requests.count, count)
                try h.completeLastPage()
            } else if stage == "page" {
                let request = try XCTUnwrap(h.requests.last)
                request.1(.failure(HistoryStoreError.recordNotFound))
                request.1(.success(try h.page(request.0)))
            } else {
                try h.completeLastPage()
                let reply = try XCTUnwrap(validation)
                reply(.failure(HistoryStoreError.staleRevision))
                reply(.success(()))
            }
            let selectedAfterFailure = h.copiedIDs()
            if stage == "page" {
                XCTAssertEqual(selectedAfterFailure, previous, "A failed page read keeps the prior validated selection")
            } else {
                XCTAssertTrue(selectedAfterFailure.isEmpty, "Failed \(stage) must not output a surviving selected subset")
            }
            XCTAssertTrue(Set(selectedAfterFailure).isDisjoint(with: Set(selected.map(\.id))))
            let count = h.requests.count
            present(selected)
            XCTAssertEqual(h.requests.count, count)
        }
    }
}
