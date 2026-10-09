import AppKit
import XCTest
@testable import ClipShelf
@testable import ClipShelfCore

@MainActor private final class RenameHarness {
    let panel = ClipboardPanelController()
    let record: ClipboardRecord
    let snapshot: ClipboardEditSnapshot
    var preparations: [(ClipboardSelectionReference, (Result<ClipboardEditSnapshot, Error>) -> Void)] = []
    var saves: [(ClipboardEditSnapshot, ClipboardRecord, (Result<ClipboardSelectionReference, Error>) -> Void)] = []
    var windows: [NSPanel] = []
    var confirmations: [(Bool) -> Void] = []
    var resolverCalls = 0, outputs = 0
    init(_ supplied: ClipboardRecord? = nil) {
        record = supplied ?? ClipboardRecord(text: "原始正文", sourceApp: "Synthetic", sourceBundleID: "io.synthetic.app",
            copiedAt: Date(timeIntervalSince1970: 123), rtf: Data([1, 2]), html: Data("<b>原始正文</b>".utf8),
            parts: [.init(representations: [.init(typeIdentifier: "org.example.opaque", data: Data([0, 1, 255]))]),
                    .init(representations: [.init(typeIdentifier: "public.utf8-plain-text", data: Data("second".utf8))])],
            renamedTitle: "旧名称", ocrText: "保留识别结果", originDeviceID: UUID(), originDeviceName: "Synthetic Mac")
        snapshot = .init(record: record, syncConfiguration: .init(accountID: "A", generation: 3), sharingConfiguration: .init(accountID: "B", generation: 5))
        let window = UnshownTestPanel(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 430), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = panel.window?.contentView; window.delegate = panel; panel.window = window
        panel.presentDetailPanel = { [weak self] window, _ in self?.windows.append(window) }
        panel.confirmDiscardEdits = { [weak self] _, reply in self?.confirmations.append(reply); return {} }
        panel.onPrepareEdit = { [weak self] ref, reply in self?.preparations.append((ref, reply)) }
        panel.onEdit = { [weak self] snapshot, edited, reply in self?.saves.append((snapshot, edited, reply)) }
        panel.resolveSelection = { [weak self] _, reply in self?.resolverCalls += 1; reply(.failure(HistoryStoreError.recordNotFound)) }
        panel.onPaste = { [weak self] _, _ in self?.outputs += 1 }
        panel.onCopy = { [weak self] _ in self?.outputs += 1 }
        panel.onImageFileOutput = { [weak self] _, _ in self?.outputs += 1 }
        panel.show(records: [record])
        _ = key(36, "\r") // Focus results for the real Cmd-R route.
    }
    var reference: ClipboardSelectionReference { .init(id: record.id, revision: record.revision) }
    func begin() { panel.rename(reference) }
    func load(_ snapshot: ClipboardEditSnapshot? = nil) { preparations.last?.1(.success(snapshot ?? self.snapshot)) }
    func view<T: NSView>(_ type: T.Type, label: String? = nil, title: String? = nil, in window: NSWindow? = nil) throws -> T {
        func find(_ candidate: NSView) -> T? {
            if let typed = candidate as? T, (label == nil || typed.accessibilityLabel() == label), (title == nil || (typed as? NSButton)?.title == title) { return typed }
            return candidate.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap((window ?? windows.last)?.contentView.flatMap(find))
    }
    func editor() throws -> NSTextView { try view(NSTextView.self, label: "条目名称") }
    func change(_ value: String) throws {
        let editor = try editor(); editor.breakUndoCoalescing()
        editor.insertText(value, replacementRange: NSRange(location: 0, length: editor.attributedString().length)); editor.breakUndoCoalescing()
    }
    func save() { panel.perform(NSSelectorFromString("saveDetail")) }
    func discard() { panel.perform(NSSelectorFromString("discardDetail")) }
    func close() { discard(); panel.dismiss() }
    var status: String { (try? view(NSTextField.self, label: "编辑状态"))?.stringValue ?? "" }
    @discardableResult func key(_ code: UInt16, _ text: String, flags: NSEvent.ModifierFlags = []) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1,
            windowNumber: panel.window!.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        return panel.handleKey(event)
    }
}

@MainActor final class RenameItemInteractionTests: XCTestCase {
    func testKeyboardAndMenuPrepareReferenceWithoutHydratingThroughResolver() throws {
        for menu in [false, true] {
            let h = RenameHarness(); defer { h.close() }
            if menu {
                let item = NSMenuItem(title: "重命名此项", action: NSSelectorFromString("renameFromMenu:"), keyEquivalent: "")
                item.representedObject = h.record.id
                h.panel.perform(NSSelectorFromString("renameFromMenu:"), with: item)
            } else { XCTAssertTrue(h.key(15, "r", flags: .command)) }
            XCTAssertEqual(h.resolverCalls, 0); XCTAssertEqual(h.preparations.count, 1)
            XCTAssertEqual(h.preparations[0].0, h.reference)
            XCTAssertFalse(try h.editor().isEditable); XCTAssertEqual(try h.editor().string, "")
            h.load(); XCTAssertEqual(try h.editor().string, h.record.title); XCTAssertTrue(try h.editor().isEditable)
            XCTAssertTrue(h.panel.hasOpenEditor)
        }
    }

    func testFailurePreservesNameSelectionUndoAndOnlyTitleChangesOnRetry() throws {
        let h = RenameHarness(); defer { h.close() }; h.begin(); h.load(); try h.change("  新名称  \n")
        let editor = try h.editor(), undo = try XCTUnwrap(try h.editor().undoManager)
        editor.setSelectedRange(NSRange(location: 2, length: 2))
        h.save(); XCTAssertEqual(h.saves.count, 1); XCTAssertEqual(h.saves[0].0, h.snapshot)
        var expected = h.record; expected.renamedTitle = "新名称"
        XCTAssertEqual(h.saves[0].1, expected, "Rich bytes, parts, OCR, source, identity and revision must all be untouched")
        h.saves[0].2(.failure(NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "账户已改变，原名称未覆盖"])))
        XCTAssertTrue(try h.editor() === editor); XCTAssertEqual(editor.string, "  新名称  \n")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 2)); XCTAssertTrue(editor.undoManager === undo)
        XCTAssertEqual(h.status, "账户已改变，原名称未覆盖")
        h.save(); XCTAssertEqual(h.saves.count, 2); XCTAssertEqual(h.preparations.count, 1)
        XCTAssertEqual(h.saves[1].0, h.snapshot)
        h.saves[1].2(.success(.init(id: h.record.id, revision: h.record.revision + 1)))
        XCTAssertFalse(h.panel.hasOpenEditor)
    }

    func testUnchangedNameClosesWithoutSaveAndEmptyNameKeepsLegacyAutomaticTitleBehavior() throws {
        let h = RenameHarness(); defer { h.close() }; h.begin(); h.load(); h.save()
        XCTAssertTrue(h.saves.isEmpty); XCTAssertFalse(h.panel.hasOpenEditor)
        h.begin(); h.load(); try h.change(" \n\t "); h.save()
        XCTAssertEqual(h.saves[0].1.renamedTitle, "")
        XCTAssertEqual(h.saves[0].1.title, h.record.text)
    }

    func testPendingRenameIsReadOnlyRejectsDuplicateAndLateReceiptCannotCloseNextEditor() throws {
        let h = RenameHarness(); defer { h.close() }; h.begin(); h.load(); try h.change("waiting")
        h.save(); h.save(); XCTAssertEqual(h.saves.count, 1)
        let editor = try h.editor(); XCTAssertFalse(editor.isEditable); XCTAssertNil(editor.undoManager)
        editor.insertText("overwrite", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertEqual(editor.string, "waiting")
        h.discard(); h.begin(); h.load(); try h.change("next draft")
        let next = try XCTUnwrap(h.windows.last)
        h.saves[0].2(.success(.init(id: h.record.id, revision: h.record.revision + 1)))
        XCTAssertTrue(h.panel.ownsWindow(next)); XCTAssertEqual(try h.editor().string, "next draft")
    }

    func testFailedAndLatePreparationCannotEnableWrongDraft() throws {
        let h = RenameHarness(); defer { h.close() }; h.begin()
        h.preparations[0].1(.failure(HistoryStoreError.staleRevision))
        XCTAssertFalse(try h.editor().isEditable); XCTAssertFalse(h.status.isEmpty)
        h.save(); XCTAssertEqual(h.preparations.count, 2); XCTAssertEqual(h.preparations[1].0, h.reference)
        let oldReply = h.preparations[1].1
        h.discard(); h.begin(); oldReply(.success(h.snapshot))
        XCTAssertFalse(try h.editor().isEditable)
        var changed = h.record; changed.revision += 1
        h.load(.init(record: changed)); XCTAssertFalse(try h.editor().isEditable)
        XCTAssertTrue(h.status.contains("条目已变化"))
    }

    func testRenameDraftUsesSharedDiscardHideAndExternalActionLifecycle() throws {
        let h = RenameHarness(); defer { h.close() }; h.begin(); h.load(); try h.change("dirty name")
        let editor = try h.editor(), window = try XCTUnwrap(h.windows.last)
        var performed = 0, cancelled = 0
        h.panel.dismissForAction({ performed += 1 }, onCancel: { cancelled += 1 })
        XCTAssertEqual(h.confirmations.count, 1); XCTAssertEqual(performed, 0)
        h.confirmations[0](false); XCTAssertEqual(cancelled, 1); XCTAssertEqual(editor.string, "dirty name")
        h.panel.hideForSuspension(); XCTAssertFalse(h.panel.isVisible); XCTAssertTrue(h.panel.hasPreservedDraft)
        h.panel.show(records: []); XCTAssertTrue(h.panel.hasOpenEditor)
        XCTAssertTrue(try h.editor() === editor); XCTAssertTrue(h.windows.last === window)
        XCTAssertEqual(h.preparations.count, 1)
        h.panel.dismissForAction({ performed += 1 }); h.confirmations[1](true)
        XCTAssertEqual(performed, 1); XCTAssertFalse(h.panel.hasOpenEditor)
    }

    func testRenameRejectsOutputAndCancelsPreparedGestureBeforeItOpens() throws {
        let h = RenameHarness(ClipboardRecord(text: "simple")); defer { h.close() }
        h.panel.resolveSelection = { _, reply in reply(.success([h.record])) }
        h.panel.window?.contentView?.layoutSubtreeIfNeeded()
        let card = try h.view(ClipboardCardView.self, in: h.panel.window)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 40, y: 40), modifierFlags: [], timestamp: 1,
            windowNumber: h.panel.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        card.mouseDown(with: event); XCTAssertEqual(card.draggedRecordIDs, [h.record.id])
        h.begin(); h.load(); XCTAssertNil(card.activeGestureID); XCTAssertTrue(card.draggedRecordIDs.isEmpty)
        card.onOpen?([]); XCTAssertTrue(h.key(36, "\r")); XCTAssertTrue(h.key(18, "1", flags: .command))
        let item = NSMenuItem(title: "copy", action: NSSelectorFromString("copyFromMenu:"), keyEquivalent: "")
        item.representedObject = h.record.id; h.panel.perform(NSSelectorFromString("copyFromMenu:"), with: item)
        XCTAssertEqual(h.outputs, 0)
    }

    func testRealCoreRenameCommitsOnlyTitleAndUndoRestoresExactOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-rename-core-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(databaseURL: root.appendingPathComponent("history.sqlite3"))
        let h = RenameHarness(); defer { h.close() }
        let original = try store.create(h.record)
        var undo: HistorySelectionEditUndo?
        h.panel.onPrepareEdit = { ref, reply in reply(Result { try store.prepareEdit(ref) }) }
        h.panel.onEdit = { snapshot, edited, reply in
            reply(Result { let receipt = try store.commitEdit(edited, snapshot: snapshot); undo = receipt; return receipt.committedReference })
        }
        h.begin(); try h.change("committed name"); h.save()
        XCTAssertFalse(h.panel.hasOpenEditor)
        var renamed = original; renamed.renamedTitle = "committed name"; renamed.revision += 1
        XCTAssertEqual(try store.item(id: original.id), renamed)
        let receipt = try XCTUnwrap(undo); XCTAssertEqual(receipt.original, original)
        _ = try store.undoSelectionEdit(receipt)
        var restored = original; restored.revision += 2
        XCTAssertEqual(try store.item(id: original.id), restored)
    }

    func testRealCoreAccountRoundTripRejectsRetryWithoutReauthorizingTypedName() throws {
        for sharing in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-rename-account-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try HistoryStore(databaseURL: root.appendingPathComponent("history.sqlite3"))
            let h = RenameHarness(); defer { h.close() }; let original = try store.create(h.record)
            var prepares = 0, commits = 0
            h.panel.onPrepareEdit = { ref, reply in prepares += 1; reply(Result { try store.prepareEdit(ref) }) }
            h.panel.onEdit = { snapshot, edited, reply in commits += 1; reply(Result { try store.commitEdit(edited, snapshot: snapshot).committedReference }) }
            h.begin(); try h.change("must remain a draft")
            if sharing { try store.configureSharing(accountID: "B"); try store.configureSharing(accountID: nil) }
            else { try store.configureSync(accountID: "B"); try store.configureSync(accountID: nil) }
            h.save(); h.save()
            XCTAssertEqual(prepares, 1); XCTAssertEqual(commits, 2)
            XCTAssertEqual(try h.editor().string, "must remain a draft"); XCTAssertFalse(h.status.isEmpty)
            XCTAssertEqual(try store.item(id: original.id), original)
        }
    }

    func testRealCoreOldRevisionCannotPrepareOrOverwriteLaterName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-rename-stale-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(databaseURL: root.appendingPathComponent("history.sqlite3"))
        let h = RenameHarness(); defer { h.close() }; let original = try store.create(h.record)
        h.panel.onPrepareEdit = { ref, reply in reply(Result { try store.prepareEdit(ref) }) }
        var updated = original; updated.renamedTitle = "outside update"; let saved = try store.update(record: updated)
        h.begin(); XCTAssertFalse(try h.editor().isEditable); XCTAssertFalse(h.status.isEmpty)
        XCTAssertEqual(try store.item(id: original.id), saved)
    }

    func testImagePreviewEditingCallbacksUseCurrentSessionAndAdoptCommittedVersion() throws {
        let image = ClipboardRecord(text: "Synthetic image", parts: [.init(representations: [
            .init(typeIdentifier: "public.png", data: Data([1, 2, 3]))])])
        let h = RenameHarness(image); defer { h.close() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-image-wiring-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var created: ImagePreviewController?
        h.panel.makeImagePreview = { record, query in
            let preview = ImagePreviewController(record: record, searchQuery: query, cache: OCRDerivedCache(directory: root))
            preview.presentWindow = { _, _ in }
            preview.recognizeImage = { _ in throw CancellationError() }
            created = preview; return preview
        }
        h.panel.edit(image)
        let preview = try XCTUnwrap(created)
        XCTAssertTrue(preview.isContextCurrent?() == true)
        var prepared: ClipboardEditSnapshot?
        preview.onPrepareEdit?(h.reference) { prepared = try? $0.get() }
        XCTAssertEqual(h.preparations.count, 1); h.load(); XCTAssertEqual(prepared, h.snapshot)
        var edited = image; edited.text = "Rotated image"
        var receipt: ClipboardSelectionReference?
        preview.onEdit?(h.snapshot, edited) { receipt = try? $0.get() }
        XCTAssertEqual(h.saves.count, 1); XCTAssertEqual(h.saves[0].1, edited)
        let committed = ClipboardSelectionReference(id: image.id, revision: image.revision + 1)
        h.saves[0].2(.success(committed)); XCTAssertEqual(receipt, committed)
        edited.revision = committed.revision
        preview.onCommitted?(h.reference, edited)
        preview.dismiss(); XCTAssertFalse(preview.isContextCurrent?() == true)
        XCTAssertTrue(h.key(15, "r", flags: .command))
        XCTAssertEqual(h.preparations.last?.0, committed)
        let count = h.preparations.count
        preview.onPrepareEdit?(committed) { _ in XCTFail("A retired preview cannot prepare another edit") }
        XCTAssertEqual(h.preparations.count, count)
    }
}
