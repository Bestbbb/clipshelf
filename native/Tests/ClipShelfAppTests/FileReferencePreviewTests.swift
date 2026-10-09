import AppKit
import XCTest
@testable import ClipShelf
@testable import ClipShelfCore

@MainActor private final class FilePreviewHarness {
    let controller: FileReferencePreviewController
    let initial: ClipboardFileRepairSnapshot
    var reads: [(ClipboardSelectionReference, FileReferencePreviewController.SnapshotReply)] = []
    var choices: [(ClipboardFileReference, (URL?) -> Void)] = []
    var relocations: [(ClipboardFileRepairSnapshot, ClipboardFileReference, URL, FileReferencePreviewController.SnapshotReply)] = []
    var restorations: [(ClipboardFileRepairSnapshot, ClipboardFileReference, FileReferencePreviewController.SnapshotReply)] = []
    var opened: [URL] = [], previewed: [URL] = []
    var cancelledPickers = 0, closedPreviews = 0, dismissed = 0
    var context = true

    init(_ supplied: ClipboardFileRepairSnapshot? = nil, preferUnavailable: Bool = false) {
        let snapshot = supplied ?? Self.fixture()
        initial = snapshot
        var pick: FileReferencePreviewController.FilePicker!
        var opening: ((URL) -> Bool)!
        var previewing: ((URL) -> Void)!
        var closing: (() -> Void)!
        controller = FileReferencePreviewController(record: snapshot.record, preferUnavailable: preferUnavailable,
            window: UnshownTestPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540), styleMask: .borderless, backing: .buffered, defer: false),
            chooseFile: { pick($0, $1, $2) }, openURL: { opening($0) }, previewURL: { previewing($0) }, dismissPreview: { closing() })
        pick = { [weak self] _, file, reply in
            self?.choices.append((file, reply))
            return { [weak self] in self?.cancelledPickers += 1 }
        }
        opening = { [weak self] url in self?.opened.append(url); return true }
        previewing = { [weak self] in self?.previewed.append($0) }
        closing = { [weak self] in self?.closedPreviews += 1 }
        controller.onSnapshot = { [weak self] ref, reply in self?.reads.append((ref, reply)) }
        controller.onRelocate = { [weak self] snapshot, file, url, reply in self?.relocations.append((snapshot, file, url, reply)) }
        controller.onRestoreOwned = { [weak self] snapshot, file, reply in self?.restorations.append((snapshot, file, reply)) }
        controller.onDismiss = { [weak self] in self?.dismissed += 1 }
        controller.isContextCurrent = { [weak self] in self?.context == true }
        controller.present(relativeTo: nil)
    }
    func load(_ snapshot: ClipboardFileRepairSnapshot? = nil) { reads.last?.1(.success(snapshot ?? initial)) }
    func view<T: NSView>(_ type: T.Type, label: String? = nil, title: String? = nil) throws -> T {
        func find(_ view: NSView) -> T? {
            if let typed = view as? T, (label == nil || typed.accessibilityLabel() == label), (title == nil || (typed as? NSButton)?.title == title) { return typed }
            return view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(controller.window?.contentView.flatMap(find))
    }
    func select(_ row: Int) throws { try view(NSTableView.self).selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    static func fixture(statuses: [ClipboardFileAvailability] = [.available, .missing, .unreadable], owned: Bool = false, readOnly: Bool = false, revision: Int = 1) -> ClipboardFileRepairSnapshot {
        let files = statuses.enumerated().map { index, status in
            let url = status == .invalidURL ? nil : URL(fileURLWithPath: "/synthetic/folder-\(index)/same-name.txt")
            return ClipboardFileReference(partIndex: index, representationIndex: 0,
                rawURL: Data((url?.absoluteString ?? "invalid URL").utf8), url: url, status: status, isOwned: owned)
        }
        let record = ClipboardRecord(text: "Synthetic files", parts: files.map {
            .init(representations: [.init(typeIdentifier: "public.file-url", data: $0.rawURL)]) }, revision: revision)
        return snapshot(record: record, files: files, readOnly: readOnly)
    }
    static func snapshot(record: ClipboardRecord, files: [ClipboardFileReference], readOnly: Bool = false) -> ClipboardFileRepairSnapshot {
        .init(record: record, files: files, syncConfiguration: .init(accountID: nil, generation: 0),
              sharingConfiguration: .init(accountID: nil, generation: 0), isReadOnly: readOnly)
    }
}

@MainActor final class FileReferencePreviewTests: XCTestCase {
    func testAllSlotsAndInvalidRowsRemainVisibleWithoutOpeningOrPicking() throws {
        let h = FilePreviewHarness(FilePreviewHarness.fixture(statuses: [.available, .missing, .unreadable, .invalidURL, .unsafeProjection]), preferUnavailable: true)
        defer { h.controller.dismiss() }
        XCTAssertEqual(h.reads.count, 1); h.load()
        XCTAssertEqual(try h.view(NSTableView.self).numberOfRows, 5)
        XCTAssertEqual(h.controller.selectedFile?.partIndex, 1)
        XCTAssertEqual(h.controller.selectedFile?.representationIndex, 0)
        XCTAssertEqual(h.controller.selectedFile?.status, .missing)
        XCTAssertTrue(h.opened.isEmpty); XCTAssertTrue(h.previewed.isEmpty); XCTAssertTrue(h.choices.isEmpty)
        XCTAssertFalse(try h.view(NSButton.self, title: "打开所选文件").isEnabled)
        XCTAssertTrue(try h.view(NSButton.self, title: "重新定位…").isEnabled)
    }

    func testExplicitOpenRefreshesThenOpensOnlySelectedSlotAndNotSibling() throws {
        let h = FilePreviewHarness(FilePreviewHarness.fixture(statuses: [.available, .available])); defer { h.controller.dismiss() }
        h.load(); try h.select(1); h.controller.openSelected()
        XCTAssertEqual(h.reads.count, 2); XCTAssertTrue(h.opened.isEmpty)
        h.load()
        XCTAssertEqual(h.opened, [try XCTUnwrap(h.initial.files[1].url)])
        XCTAssertTrue(h.previewed.isEmpty)
    }

    func testFileDisappearingBetweenSelectionAndExplicitOutputDoesNotOpenSubset() throws {
        let h = FilePreviewHarness(); defer { h.controller.dismiss() }
        h.load(); h.controller.openSelected()
        let old = h.initial.files[0]
        let missing = ClipboardFileReference(partIndex: old.partIndex, representationIndex: old.representationIndex,
            rawURL: old.rawURL, url: old.url, status: .missing, isOwned: false)
        h.load(FilePreviewHarness.snapshot(record: h.initial.record, files: [missing] + h.initial.files.dropFirst()))
        XCTAssertTrue(h.opened.isEmpty)
        XCTAssertFalse(try h.view(NSButton.self, title: "打开所选文件").isEnabled)
    }

    func testFailureInvalidatesOldSnapshotAndRetryIsExplicit() throws {
        let h = FilePreviewHarness(); defer { h.controller.dismiss() }
        h.load(); h.controller.refresh()
        let message = "文件位置已更新且可撤销；条目随后发生变化，请关闭后重新打开。"
        h.reads.last?.1(.failure(NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])))
        XCTAssertFalse(h.controller.snapshotIsCurrent)
        XCTAssertFalse(try h.view(NSButton.self, title: "重新定位…").isEnabled)
        XCTAssertFalse(try h.view(NSButton.self, title: "打开所选文件").isEnabled)
        XCTAssertEqual(try h.view(NSTextField.self, label: "文件操作状态").stringValue, message)
        XCTAssertEqual(try h.view(NSTableView.self).numberOfRows, h.initial.files.count)
        h.controller.refresh(); h.load(); XCTAssertTrue(h.controller.snapshotIsCurrent)
    }

    func testReadOnlyExternalCannotRelocateButReadableFileCanOpen() throws {
        let h = FilePreviewHarness(FilePreviewHarness.fixture(statuses: [.available], readOnly: true)); defer { h.controller.dismiss() }
        h.load(); h.controller.repairSelected()
        XCTAssertTrue(h.choices.isEmpty)
        XCTAssertFalse(try h.view(NSButton.self, title: "重新定位…").isEnabled)
        XCTAssertTrue(try h.view(NSButton.self, title: "打开所选文件").isEnabled)
    }

    func testOwnedRestoreOnlyMissingAndReadOnlyStillAllowsLocalProjectionRecovery() throws {
        let h = FilePreviewHarness(FilePreviewHarness.fixture(statuses: [.available, .missing, .unsafeProjection, .unreadable], owned: true, readOnly: true)); defer { h.controller.dismiss() }
        h.load()
        for row in [0, 2, 3] {
            try h.select(row); h.controller.repairSelected()
            XCTAssertFalse(try h.view(NSButton.self, title: "从已保存原件重建打开副本").isEnabled)
        }
        XCTAssertTrue(h.restorations.isEmpty)
        try h.select(1); h.controller.repairSelected()
        XCTAssertEqual(h.restorations.count, 1); XCTAssertEqual(h.restorations[0].1, h.initial.files[1])
        XCTAssertTrue(h.choices.isEmpty); XCTAssertTrue(h.opened.isEmpty)
    }

    func testCancelledPickerDoesNotMutateOrLoseSlotAndRepeatClickCreatesOnePicker() throws {
        let h = FilePreviewHarness(preferUnavailable: true); defer { h.controller.dismiss() }
        h.load(); h.controller.repairSelected(); h.controller.repairSelected()
        XCTAssertEqual(h.choices.count, 1); XCTAssertEqual(h.choices[0].0, h.initial.files[1])
        h.choices[0].1(nil)
        XCTAssertTrue(h.relocations.isEmpty); XCTAssertTrue(h.controller.snapshotIsCurrent)
        XCTAssertEqual(h.controller.selectedFile, h.initial.files[1])
        XCTAssertTrue(try h.view(NSButton.self, title: "重新定位…").isEnabled)
    }

    func testRelocationTargetsExactSlotPreservesOthersAndSuccessDoesNotOutput() throws {
        let h = FilePreviewHarness(preferUnavailable: true); defer { h.controller.dismiss() }
        h.load(); h.controller.repairSelected()
        let replacement = URL(fileURLWithPath: "/synthetic/replacement.txt")
        h.choices[0].1(replacement); h.choices[0].1(replacement)
        XCTAssertEqual(h.relocations.count, 1)
        XCTAssertEqual(h.relocations[0].0, h.initial); XCTAssertEqual(h.relocations[0].1, h.initial.files[1]); XCTAssertEqual(h.relocations[0].2, replacement)
        var record = h.initial.record; record.revision += 1
        let old = h.initial.files[1]
        let updated = ClipboardFileReference(partIndex: old.partIndex, representationIndex: old.representationIndex,
            rawURL: Data(replacement.absoluteString.utf8), url: replacement, status: .available, isOwned: false)
        var files = h.initial.files; files[1] = updated
        let next = FilePreviewHarness.snapshot(record: record, files: files)
        h.relocations[0].3(.success(next))
        XCTAssertEqual(h.controller.snapshot, next); XCTAssertEqual(h.controller.selectedFile, updated)
        XCTAssertEqual(h.controller.snapshot?.files[0], h.initial.files[0])
        XCTAssertTrue(h.opened.isEmpty); XCTAssertTrue(h.previewed.isEmpty)
        h.controller.refresh(); XCTAssertEqual(h.reads.last?.0.revision, record.revision)
    }

    func testLatePickerCannotSubmitAfterDismissOrInvalidParentContext() throws {
        for dismiss in [false, true] {
            let h = FilePreviewHarness(); h.load(); h.controller.repairSelected()
            if dismiss { h.controller.dismiss(); XCTAssertEqual(h.cancelledPickers, 1) } else { h.context = false }
            h.choices[0].1(URL(fileURLWithPath: "/synthetic/new.txt"))
            XCTAssertTrue(h.relocations.isEmpty)
            h.controller.dismiss()
        }
    }

    func testRelinkReceiptCanCanonicalizeRepresentationIndexWithoutLosingSelectedFile() throws {
        let originalURL = URL(fileURLWithPath: "/synthetic/missing.txt")
        let bytes = Data(originalURL.absoluteString.utf8)
        let record = ClipboardRecord(text: "file", parts: [.init(representations: [
            .init(typeIdentifier: "public.utf8-plain-text", data: Data("label".utf8)),
            .init(typeIdentifier: "public.file-url", data: bytes), .init(typeIdentifier: "public.file-url", data: bytes)])])
        let original = [1, 2].map { ClipboardFileReference(partIndex: 0, representationIndex: $0, rawURL: bytes, url: originalURL, status: .missing, isOwned: false) }
        let h = FilePreviewHarness(FilePreviewHarness.snapshot(record: record, files: original)); defer { h.controller.dismiss() }
        h.load(); XCTAssertEqual(try h.view(NSTableView.self).numberOfRows, 2)
        try h.select(1); h.controller.repairSelected()
        let replacement = URL(fileURLWithPath: "/synthetic/located.txt")
        h.choices[0].1(replacement)
        XCTAssertEqual(h.relocations[0].1.representationIndex, 2)
        var updated = record; updated.revision += 1
        updated.parts = [.init(representations: [.init(typeIdentifier: "public.file-url", data: Data(replacement.absoluteString.utf8))])]
        let canonical = ClipboardFileReference(partIndex: 0, representationIndex: 0, rawURL: Data(replacement.absoluteString.utf8), url: replacement, status: .available, isOwned: false)
        h.relocations[0].3(.success(FilePreviewHarness.snapshot(record: updated, files: [canonical])))
        XCTAssertTrue(h.controller.snapshotIsCurrent)
        XCTAssertEqual(h.controller.selectedFile, canonical)
        XCTAssertTrue(h.opened.isEmpty); XCTAssertTrue(h.previewed.isEmpty)
    }

    func testLateReadAndMutationReceiptsDoNotUpdateDismissedWindow() throws {
        let h = FilePreviewHarness(); let reply = try XCTUnwrap(h.reads.last?.1)
        h.controller.dismiss(); reply(.success(h.initial))
        XCTAssertNil(h.controller.snapshot)
        let second = FilePreviewHarness(); second.load(); second.controller.repairSelected()
        second.choices[0].1(URL(fileURLWithPath: "/synthetic/new.txt"))
        let mutation = try XCTUnwrap(second.relocations.first?.3)
        second.controller.dismiss(); mutation(.success(second.initial))
        XCTAssertFalse(second.controller.snapshotIsCurrent)
        XCTAssertEqual(second.dismissed, 1)
    }

    func testExplicitQuickLookIsClosedOnDismissAndSpaceOnlyActsForTable() throws {
        let h = FilePreviewHarness(); h.load()
        let table = try h.view(NSTableView.self)
        h.controller.window?.makeFirstResponder(table)
        let space = key(49, " ", window: h.controller.window!)
        XCTAssertTrue(h.controller.handleKey(space)); h.load()
        XCTAssertEqual(h.previewed.count, 1); XCTAssertTrue(h.opened.isEmpty)
        h.controller.dismiss(); XCTAssertEqual(h.closedPreviews, 1)
        XCTAssertFalse(h.controller.handleKey(space))
    }

    func testEscapeClosesWindowWithoutMutationAndMinimumSizeKeepsActionsReachable() throws {
        let h = FilePreviewHarness(FilePreviewHarness.fixture(statuses: [.unsafeProjection], owned: true)); h.load()
        let window = try XCTUnwrap(h.controller.window)
        window.setContentSize(NSSize(width: 620, height: 450)); window.contentView?.layoutSubtreeIfNeeded()
        let root = try XCTUnwrap(window.contentView)
        for title in ["预览所选文件", "打开所选文件", "从已保存原件重建打开副本", "刷新状态", "返回列表"] {
            let button = try h.view(NSButton.self, title: title)
            XCTAssertTrue(root.bounds.contains(button.convert(button.bounds, to: root)), title)
        }
        XCTAssertTrue(h.controller.handleKey(key(53, "\u{1b}", window: window)))
        XCTAssertEqual(h.dismissed, 1); XCTAssertTrue(h.relocations.isEmpty); XCTAssertTrue(h.restorations.isEmpty)
    }

    private func key(_ code: UInt16, _ text: String, window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber,
                        context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }
}

@MainActor private final class FilePanelHarness {
    let panel = ClipboardPanelController()
    let initial = FilePreviewHarness.fixture(statuses: [.missing])
    var controllers: [FileReferencePreviewController] = []
    var reads: [FileReferencePreviewController.SnapshotReply] = []
    var choices: [(URL?) -> Void] = []
    var repairs: [FileReferencePreviewController.SnapshotReply] = []
    var pastes: [ClipboardRecord] = []
    var edits = 0, cancelled = 0
    init() {
        let window = UnshownTestPanel(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 430), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = panel.window?.contentView; window.delegate = panel; panel.window = window
        panel.makeFilePreview = { [weak self] record, preferUnavailable in
            let preview = FileReferencePreviewController(record: record, preferUnavailable: preferUnavailable,
                window: UnshownTestPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540), styleMask: .borderless, backing: .buffered, defer: false),
                chooseFile: { [weak self] _, _, reply in
                    self?.choices.append(reply)
                    return { [weak self] in self?.cancelled += 1 }
                }, openURL: { _ in XCTFail("Must not open external files"); return false },
                previewURL: { _ in XCTFail("Must not open Quick Look") })
            self?.controllers.append(preview)
            return preview
        }
        panel.onFileSnapshot = { [weak self] _, reply in self?.reads.append(reply) }
        panel.onRelocateFile = { [weak self] _, _, _, reply in self?.repairs.append(reply) }
        panel.onPaste = { [weak self] record, _ in self?.pastes.append(record) }
        panel.onEdit = { [weak self] _, _, _ in self?.edits += 1 }
        panel.show(records: [initial.record])
        _ = key(36, "\r")
    }
    @discardableResult func key(_ code: UInt16, _ text: String = "", flags: NSEvent.ModifierFlags = [], window: NSWindow? = nil) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1,
            windowNumber: (window ?? panel.window!).windowNumber, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        return panel.handleKey(event)
    }
    func load() { reads.last?(.success(initial)) }
    func card() throws -> ClipboardCardView {
        func find(_ view: NSView) -> NSCollectionView? { (view as? NSCollectionView) ?? view.subviews.lazy.compactMap(find).first }
        let collection = try XCTUnwrap(panel.window?.contentView.flatMap(find))
        let item = panel.collectionView(collection, itemForRepresentedObjectAt: IndexPath(item: 0, section: 0))
        return try XCTUnwrap(item.view.subviews.first as? ClipboardCardView)
    }
}

@MainActor final class PanelFileReferenceTests: XCTestCase {
    func testSpaceAndCommandEOpenFileListAndNeverTextEditorOrExternalOpen() throws {
        let h = FilePanelHarness(); defer { h.panel.dismiss() }
        XCTAssertTrue(h.key(49, " ")); XCTAssertEqual(h.controllers.count, 1)
        h.load(); h.controllers[0].dismiss()
        XCTAssertTrue(h.key(14, "e", flags: .command)); XCTAssertEqual(h.controllers.count, 2)
        XCTAssertEqual(h.edits, 0); XCTAssertTrue(h.pastes.isEmpty)
    }

    func testMenuRelocationOnlySelectsMissingFileWithoutStartingPicker() throws {
        let h = FilePanelHarness(); defer { h.panel.dismiss() }
        let menu = try XCTUnwrap(try h.card().menu)
        XCTAssertNotNil(menu.items.first { $0.title == "文件与位置…" })
        let action = try XCTUnwrap(menu.items.first { $0.title == "重新定位文件…" })
        h.panel.perform(try XCTUnwrap(action.action), with: action)
        h.load()
        XCTAssertEqual(h.controllers.count, 1); XCTAssertEqual(h.controllers[0].selectedFile?.status, .missing)
        XCTAssertTrue(h.choices.isEmpty); XCTAssertTrue(h.repairs.isEmpty)
    }

    func testFileWithEmbeddedPDFStillUsesFileManagementEntry() throws {
        let h = FilePanelHarness(); defer { h.panel.dismiss() }
        var mixed = h.initial.record
        mixed.parts[0].representations.append(.init(typeIdentifier: "com.adobe.pdf", data: Data("synthetic PDF".utf8)))
        h.panel.edit(mixed)
        XCTAssertEqual(h.controllers.count, 1); XCTAssertEqual(h.reads.count, 1)
        XCTAssertTrue(h.pastes.isEmpty)
    }

    func testChildReturnAndQuickPasteCannotFallThroughAndParentEscapeReturnsSelection() throws {
        let h = FilePanelHarness(); defer { h.panel.dismiss() }
        h.panel.showFileReferences(h.initial.record); h.load()
        let child = try XCTUnwrap(h.controllers.last?.window)
        XCTAssertTrue(h.panel.ownsWindow(child))
        XCTAssertTrue(h.panel.contains(screenPoint: NSPoint(x: child.frame.midX, y: child.frame.midY)))
        XCTAssertFalse(h.key(36, "\r", window: child))
        XCTAssertFalse(h.key(18, "1", flags: .command, window: child))
        XCTAssertTrue(h.key(36, "\r")); XCTAssertTrue(h.key(18, "1", flags: .command))
        XCTAssertTrue(h.pastes.isEmpty)
        XCTAssertTrue(h.key(53, "\u{1b}")); XCTAssertFalse(h.panel.ownsWindow(child))
        XCTAssertTrue(h.key(36, "\r")); XCTAssertEqual(h.pastes.map(\.id), [h.initial.record.id])
    }

    func testDismissAndNewQueryCancelChooserBeforeLateURLCanSubmit() throws {
        for newQuery in [true, false] {
            let h = FilePanelHarness()
            h.panel.showFileReferences(h.initial.record); h.load()
            let controller = try XCTUnwrap(h.controllers.last)
            controller.repairSelected(); XCTAssertEqual(h.choices.count, 1)
            if newQuery { h.panel.perform(NSSelectorFromString("clearFilters")) }
            else { h.panel.dismiss(); h.panel.show(records: [h.initial.record]) }
            XCTAssertEqual(h.cancelled, 1)
            h.choices[0](URL(fileURLWithPath: "/synthetic/new-location.txt"))
            XCTAssertTrue(h.repairs.isEmpty)
            XCTAssertFalse(controller.snapshotIsCurrent)
            h.panel.dismiss()
        }
    }

    func testOldSessionReceiptCannotChangeNewFileWindow() throws {
        let h = FilePanelHarness(); defer { h.panel.dismiss() }
        h.panel.showFileReferences(h.initial.record)
        let old = try XCTUnwrap(h.reads.last)
        let first = try XCTUnwrap(h.controllers.last)
        h.panel.dismiss(); h.panel.show(records: [h.initial.record])
        h.panel.showFileReferences(h.initial.record)
        old(.success(h.initial))
        XCTAssertNil(first.snapshot); XCTAssertNil(h.controllers.last?.snapshot)
        h.load(); XCTAssertEqual(h.controllers.last?.snapshot?.record.id, h.initial.record.id)
    }

    func testUnsafeOutputReaderBlocksAllOutputRoutesButFileManagementAndDeletionStillWork() throws {
        let h = FilePanelHarness(); defer { h.panel.dismiss() }
        var outputReads = 0, ordinaryReads = 0, deleted = 0
        h.panel.resolveOutputSelection = { _, reply in
            outputReads += 1
            reply(.failure(NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "打开副本路径不安全"])))
        }
        h.panel.resolveSelection = { _, reply in ordinaryReads += 1; reply(.success([h.initial.record])) }
        h.panel.onDelete = { _ in deleted += 1 }
        h.panel.onShareRecord = { _ in XCTFail("Unsafe file must not reach sharing") }
        h.panel.onCopy = { _ in XCTFail("Unsafe file must not reach copy") }
        h.key(36, "\r"); h.key(8, "c", flags: .command); h.key(18, "1", flags: .command)
        let card = try h.card()
        card.onOpen?([])
        let share = try XCTUnwrap(card.menu?.items.first { $0.title == "分享此项…" })
        h.panel.perform(try XCTUnwrap(share.action), with: share)
        XCTAssertEqual(outputReads, 5); XCTAssertTrue(h.pastes.isEmpty)
        XCTAssertTrue(h.key(49, " ")); XCTAssertEqual(ordinaryReads, 1)
        h.load(); XCTAssertEqual(h.controllers.count, 1)
        h.controllers[0].dismiss(); h.key(51)
        XCTAssertEqual(deleted, 1); XCTAssertEqual(ordinaryReads, 2)
    }
}
