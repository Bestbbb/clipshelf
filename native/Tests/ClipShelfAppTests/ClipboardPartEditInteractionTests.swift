import AppKit
import XCTest
@testable import ClipShelf
@testable import ClipShelfCore

@MainActor private final class PartEditHarness {
    typealias Receipt = (Result<ClipboardSelectionReference, Error>) -> Void
    let panel = ClipboardPanelController()
    let original: ClipboardRecord
    let snapshot: ClipboardEditSnapshot
    var preparations: [(ClipboardSelectionReference, (Result<ClipboardEditSnapshot, Error>) -> Void)] = []
    var saves: [(snapshot: ClipboardEditSnapshot, edit: ClipboardPartEdit, reply: Receipt)] = []
    var wholeSaves: [(ClipboardRecord, Receipt)] = []
    var windows: [NSPanel] = []
    var confirmations: [(Bool) -> Void] = []
    var cancelledConfirmations = 0, fileRoutes = 0, imageRoutes = 0

    init(_ record: ClipboardRecord = PartEditHarness.mixed(), open: Bool = true) {
        original = record
        snapshot = .init(record: record, syncConfiguration: .init(accountID: "part-fixture", generation: 3),
                         sharingConfiguration: .init(accountID: nil, generation: 8))
        let parent = UnshownTestPanel(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 430),
                                     styleMask: .borderless, backing: .buffered, defer: false)
        parent.contentView = panel.window?.contentView; parent.delegate = panel; panel.window = parent
        panel.presentDetailPanel = { [weak self] detail, _ in self?.windows.append(detail) }
        panel.onPrepareEdit = { [weak self] reference, reply in self?.preparations.append((reference, reply)) }
        panel.onEditPart = { [weak self] snapshot, edit, reply in self?.saves.append((snapshot, edit, reply)) }
        panel.onEdit = { [weak self] _, record, reply in self?.wholeSaves.append((record, reply)) }
        panel.confirmDiscardEdits = { [weak self] _, reply in
            self?.confirmations.append(reply)
            return { [weak self] in self?.cancelledConfirmations += 1; reply(false) }
        }
        panel.makeFilePreview = { [weak self] record, prefer in
            self?.fileRoutes += 1
            return FileReferencePreviewController(record: record, preferUnavailable: prefer,
                window: UnshownTestPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
                                         styleMask: .borderless, backing: .buffered, defer: false),
                openURL: { _ in XCTFail("Editing must not open a file"); return false },
                previewURL: { _ in XCTFail("Editing must not open Quick Look") })
        }
        panel.makeImagePreview = { [weak self] record, query in
            self?.imageRoutes += 1
            let preview = ImagePreviewController(record: record, searchQuery: query)
            preview.presentWindow = { _, _ in }
            preview.recognizeImage = { _ in throw CancellationError() }
            return preview
        }
        panel.show(records: [record])
        if open { panel.edit(record) }
    }

    nonisolated static func text(_ value: String) -> ClipboardPart {
        .init(representations: [.init(typeIdentifier: "public.utf8-plain-text", data: Data(value.utf8))])
    }
    nonisolated static func link() -> ClipboardPart {
        .init(representations: [
            .init(typeIdentifier: "public.utf8-plain-text", data: Data("A website title".utf8)),
            .init(typeIdentifier: "public.url", data: Data("https://example.test/original".utf8))
        ])
    }
    nonisolated static func mixed() -> ClipboardRecord {
        ClipboardRecord(text: "aggregate title", html: Data("<b>aggregate</b>".utf8), parts: [
            .init(representations: [.init(typeIdentifier: "public.file-url", data: Data("file:///tmp/part-edit-fixture.txt".utf8))]),
            text("first editable"), link(), text("#123456"),
            .init(representations: [
                .init(typeIdentifier: "public.utf8-plain-text", data: Data("HTML body".utf8)),
                .init(typeIdentifier: "public.html", data: Data("<b>HTML body</b>".utf8))
            ]),
            .init(representations: [.init(typeIdentifier: "public.png", data: Data([137, 80, 78, 71]))])
        ])
    }
    func load(_ result: Result<ClipboardEditSnapshot, Error>? = nil) {
        preparations.last?.1(result ?? .success(snapshot))
    }
    func view<T: NSView>(_ type: T.Type, label: String? = nil, identifier: String? = nil, title: String? = nil) throws -> T {
        func find(_ view: NSView) -> T? {
            if let value = view as? T, (label == nil || value.accessibilityLabel() == label),
               (identifier == nil || value.accessibilityIdentifier() == identifier),
               (title == nil || (value as? NSButton)?.title == title) { return value }
            return view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(windows.last?.contentView.flatMap(find))
    }
    func editor() throws -> NSTextView { try view(NSTextView.self, label: "编辑内容") }
    func picker() throws -> NSPopUpButton { try view(NSPopUpButton.self, identifier: "editor.part") }
    func replace(_ value: String) throws {
        let editor = try editor(); editor.breakUndoCoalescing()
        editor.insertText(value, replacementRange: NSRange(location: 0, length: editor.attributedString().length))
        editor.breakUndoCoalescing()
    }
    func choose(_ index: Int) throws {
        let picker = try picker(); picker.selectItem(withTag: index)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker))
    }
    func save() { panel.perform(NSSelectorFromString("saveDetail")) }
    func discard() { panel.perform(NSSelectorFromString("discardDetail")) }
    func close() { discard(); panel.dismiss() }
    var status: String { (try? view(NSTextField.self, label: "编辑状态"))?.stringValue ?? "" }
    var note: String { (try? view(NSTextField.self, identifier: "editor.note"))?.stringValue ?? "" }
}

@MainActor final class ClipboardPartEditInteractionTests: XCTestCase {
    func testDirectMenuAndCommandERouteMixedFileAndImageRecordsToObjectEditor() throws {
        let image = ClipboardRecord(text: "mixed image", parts: [PartEditHarness.mixed().parts[5], PartEditHarness.text("editable beside image")])
        for original in [PartEditHarness.mixed(), image] {
            for entry in 0..<3 {
                let h = PartEditHarness(original, open: false); defer { h.close() }
                if entry == 0 { h.panel.edit(original) }
                else if entry == 1 {
                    let menu = NSMenuItem(); menu.representedObject = original.id
                    h.panel.perform(NSSelectorFromString("editFromMenu:"), with: menu)
                } else {
                    let parent = try XCTUnwrap(h.panel.window)
                    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                        timestamp: 1, windowNumber: parent.windowNumber, context: nil,
                        characters: "e", charactersIgnoringModifiers: "e", isARepeat: false, keyCode: 14))
                    // Presentation intentionally starts in the search editor. Cmd-E
                    // must stay in its native responder chain until results gain focus.
                    XCTAssertFalse(h.panel.handleKey(event))
                    XCTAssertTrue(h.preparations.isEmpty)
                    let focusResults = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: 2, windowNumber: parent.windowNumber, context: nil,
                        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                    XCTAssertTrue(h.panel.handleKey(focusResults))
                    XCTAssertTrue(parent.firstResponder is NSCollectionView)
                    XCTAssertTrue(h.panel.handleKey(event))
                }
                XCTAssertEqual(h.fileRoutes, 0); XCTAssertEqual(h.imageRoutes, 0)
                XCTAssertTrue(h.panel.hasOpenEditor); XCTAssertEqual(h.preparations.count, 1)
                let picker = try h.picker()
                XCTAssertFalse(picker.isEnabled); h.load()
                XCTAssertEqual(picker.numberOfItems, original.parts.count)
                XCTAssertEqual(picker.selectedTag(), 1)
                XCTAssertTrue(picker.itemTitle(at: 0).contains("只读"))
                XCTAssertTrue(picker.itemTitle(at: 1).contains("对象 2"))
                XCTAssertTrue(picker.itemTitle(at: 1).contains("可编辑"))
                XCTAssertEqual(try h.editor().string, original.kind == .file ? "first editable" : "editable beside image")
            }
        }
    }

    func testUnsupportedObjectIsReadOnlyAndSelectionCanReturnToEditableText() throws {
        let h = PartEditHarness(); defer { h.close() }; h.load()
        try h.choose(0); h.load()
        XCTAssertEqual(try h.picker().selectedTag(), 0)
        XCTAssertFalse(try h.editor().isEditable); XCTAssertFalse(h.status.isEmpty)
        XCTAssertFalse(try h.view(NSButton.self, title: "保存修改").isEnabled)
        h.save(); XCTAssertTrue(h.saves.isEmpty); XCTAssertTrue(h.wholeSaves.isEmpty)
        try h.choose(1); h.load()
        XCTAssertTrue(try h.editor().isEditable); XCTAssertEqual(try h.editor().string, "first editable")
        XCTAssertEqual(h.snapshot.record.parts, h.original.parts)
    }

    func testSwitchConfirmationPreservesDraftAttributesSelectionAndUndoUntilExplicitDiscard() throws {
        let h = PartEditHarness(); defer { h.close() }; h.load(); try h.replace("keep this draft")
        let editor = try h.editor(), window = try XCTUnwrap(h.windows.last)
        editor.textStorage?.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 4))
        editor.didChangeText(); editor.setSelectedRange(NSRange(location: 2, length: 3))
        let draft = NSAttributedString(attributedString: editor.attributedString()), undo = try XCTUnwrap(editor.undoManager)
        try h.choose(2)
        XCTAssertEqual(h.confirmations.count, 1); XCTAssertEqual(try h.picker().selectedTag(), 1)
        XCTAssertFalse(try h.picker().isEnabled); XCTAssertEqual(h.preparations.count, 1)
        h.confirmations[0](false)
        XCTAssertTrue(try h.editor() === editor); XCTAssertTrue(editor.attributedString().isEqual(to: draft))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 3)); XCTAssertTrue(editor.undoManager === undo)
        XCTAssertTrue(undo.canUndo); XCTAssertTrue(h.panel.ownsWindow(window))
        try h.choose(2); h.confirmations[1](true)
        XCTAssertFalse(h.panel.ownsWindow(window)); XCTAssertEqual(h.preparations.count, 2)
        h.load(); XCTAssertEqual(try h.picker().selectedTag(), 2)
        XCTAssertEqual(try h.editor().string, "https://example.test/original")
        XCTAssertTrue(h.saves.isEmpty)
    }

    func testOneSaveChangesOnlySelectedPartAndFreezesSelectionUntilReceipt() throws {
        let h = PartEditHarness(); defer { h.close() }; h.load(); try h.replace("replacement")
        h.save(); h.save(); try h.choose(2)
        XCTAssertEqual(h.saves.count, 1); XCTAssertTrue(h.wholeSaves.isEmpty)
        XCTAssertFalse(try h.picker().isEnabled); XCTAssertEqual(try h.picker().selectedTag(), 1)
        XCTAssertFalse(try h.editor().isEditable); XCTAssertNil(try h.editor().undoManager)
        XCTAssertEqual(h.saves[0].snapshot, h.snapshot); XCTAssertEqual(h.saves[0].edit.partIndex, 1)
        let result = try h.saves[0].edit.applying(to: h.original)
        for index in h.original.parts.indices where index != 1 { XCTAssertEqual(result.parts[index], h.original.parts[index]) }
        XCTAssertNotEqual(result.parts[1], h.original.parts[1])
        let detail = try XCTUnwrap(h.windows.last)
        h.saves[0].reply(.success(.init(id: h.original.id, revision: h.original.revision + 1)))
        XCTAssertFalse(h.panel.ownsWindow(detail))
    }

    func testPrepareFailureRetriesSameObjectAndNeverEnablesSwitchingEarly() throws {
        let h = PartEditHarness(); defer { h.close() }
        try h.choose(2); XCTAssertEqual(try h.picker().selectedTag(), 1); XCTAssertEqual(h.preparations.count, 1)
        h.load(.failure(NSError(domain: "part-fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "retry preparation"])))
        XCTAssertFalse(try h.picker().isEnabled); XCTAssertFalse(try h.editor().isEditable)
        XCTAssertTrue(try h.view(NSButton.self, title: "重试读取").isEnabled)
        h.save(); XCTAssertEqual(h.preparations.count, 2); h.load()
        XCTAssertEqual(try h.picker().selectedTag(), 1); XCTAssertTrue(try h.editor().isEditable)
    }

    func testSaveFailureRetainsSamePartSnapshotDraftSelectionAndUndoForRetry() throws {
        let h = PartEditHarness(); defer { h.close() }; h.load(); try h.choose(2); h.load()
        try h.replace("https://example.test/edited")
        let editor = try h.editor(); editor.setSelectedRange(NSRange(location: 8, length: 7))
        let undo = try XCTUnwrap(editor.undoManager)
        h.save(); h.saves[0].reply(.failure(NSError(domain: "part-fixture", code: 2)))
        XCTAssertEqual(try h.picker().selectedTag(), 2); XCTAssertTrue(try h.editor() === editor)
        XCTAssertEqual(editor.string, "https://example.test/edited")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 8, length: 7)); XCTAssertTrue(editor.undoManager === undo)
        h.save(); XCTAssertEqual(h.saves.count, 2); XCTAssertEqual(h.saves[1].snapshot, h.saves[0].snapshot)
        XCTAssertEqual(h.saves[1].edit.partIndex, h.saves[0].edit.partIndex)
        XCTAssertEqual(h.saves[1].edit.text, h.saves[0].edit.text)
    }

    func testEncodingFailureRetainsPartDraftAndDoesNotCallEitherCommitPath() throws {
        let h = PartEditHarness(); defer { h.close() }; h.load(); try h.replace("unencoded draft")
        let editor = try h.editor(); editor.setSelectedRange(NSRange(location: 1, length: 3))
        h.panel.makeEditedPart = { _, _, _ in throw ClipboardEditPlanError.richTextEncodingFailed }
        h.save(); XCTAssertTrue(h.saves.isEmpty); XCTAssertTrue(h.wholeSaves.isEmpty)
        XCTAssertEqual(editor.string, "unencoded draft"); XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 3))
        XCTAssertTrue(h.status.contains("草稿已保留"))
        h.panel.makeEditedPart = nil; h.save(); XCTAssertEqual(h.saves.count, 1)
    }

    func testHideCancelsSwitchConfirmationAndRestoresSamePartDraft() throws {
        let h = PartEditHarness(); defer { h.close() }; h.load(); try h.replace("private draft")
        let editor = try h.editor(), detail = try XCTUnwrap(h.windows.last), undo = editor.undoManager
        editor.setSelectedRange(NSRange(location: 2, length: 4))
        try h.choose(2); h.panel.hideForSuspension()
        XCTAssertEqual(h.cancelledConfirmations, 1); XCTAssertTrue(h.panel.hasPreservedDraft)
        h.confirmations[0](true); XCTAssertEqual(h.preparations.count, 1)
        h.panel.show(records: [])
        XCTAssertTrue(h.windows.last === detail); XCTAssertTrue(try h.editor() === editor)
        XCTAssertEqual(try h.picker().selectedTag(), 1); XCTAssertEqual(editor.string, "private draft")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 4)); XCTAssertTrue(editor.undoManager === undo)
    }

    func testHiddenSaveReceiptNeverReopensAndFailureCanRetryChosenPart() throws {
        for succeeds in [false, true] {
            let h = PartEditHarness(); defer { h.close() }; h.load(); try h.choose(2); h.load()
            try h.replace("https://example.test/hidden"); h.save(); h.panel.hideForSuspension()
            let presented = h.windows.count
            h.saves[0].reply(succeeds ? .success(.init(id: h.original.id, revision: h.original.revision + 1))
                : .failure(NSError(domain: "part-fixture", code: 3)))
            XCTAssertFalse(h.panel.isVisible); XCTAssertEqual(h.windows.count, presented)
            XCTAssertEqual(h.panel.hasPreservedDraft, !succeeds)
            if !succeeds {
                h.panel.show(records: []); XCTAssertEqual(try h.picker().selectedTag(), 2)
                XCTAssertEqual(try h.editor().string, "https://example.test/hidden")
                h.save(); XCTAssertEqual(h.saves.count, 2)
            }
        }
    }

    func testLatePrepareAndSaveCannotReplaceNewObjectEditor() throws {
        let h = PartEditHarness(); defer { h.close() }; let oldPrepare = h.preparations[0].1
        h.discard(); h.panel.edit(h.original); let fresh = try h.editor()
        oldPrepare(.success(h.snapshot)); XCTAssertFalse(fresh.isEditable)
        h.load(); try h.replace("old submission"); h.save(); h.discard()
        h.panel.edit(h.original); h.load(); try h.choose(2); h.load()
        let newWindow = try XCTUnwrap(h.windows.last)
        h.saves[0].reply(.success(.init(id: h.original.id, revision: h.original.revision + 1)))
        XCTAssertTrue(h.panel.ownsWindow(newWindow)); XCTAssertEqual(try h.picker().selectedTag(), 2)
        XCTAssertEqual(try h.editor().string, "https://example.test/original")
    }

    func testSelectedColorAndHTMLUseObjectPropertiesRatherThanMixedRecordKind() throws {
        let h = PartEditHarness(); defer { h.close() }; h.load()
        XCTAssertFalse(h.note.contains("HTML")); XCTAssertTrue(try h.view(NSColorWell.self).isHidden)
        try h.choose(4); h.load(); XCTAssertTrue(h.note.contains("HTML"))
        XCTAssertEqual(try h.editor().string, "HTML body")
        try h.choose(3); h.load(); XCTAssertFalse(h.note.contains("HTML"))
        let well = try h.view(NSColorWell.self); XCTAssertFalse(well.isHidden)
        XCTAssertEqual(ClipboardEditPlan.hexString(for: well.color), "#123456")
        try h.replace("#123"); h.save(); XCTAssertTrue(h.saves.isEmpty)
        try h.replace("abcdef"); XCTAssertEqual(ClipboardEditPlan.hexString(for: well.color), "#ABCDEF")
        h.save(); XCTAssertEqual(h.saves[0].edit.partIndex, 3)
    }

    func testSingleURLLoadsAddressAndStillUsesWholeRecordCallback() throws {
        let original = ClipboardRecord(text: "A website title", parts: [PartEditHarness.link()])
        let h = PartEditHarness(original); defer { h.close() }; h.load()
        XCTAssertEqual(try h.editor().string, "https://example.test/original")
        func containsPicker(_ view: NSView) -> Bool {
            view.accessibilityIdentifier() == "editor.part" || view.subviews.contains(where: containsPicker)
        }
        XCTAssertFalse(containsPicker(try XCTUnwrap(h.windows.last?.contentView)))
        try h.replace("not a URL"); h.save(); XCTAssertTrue(h.wholeSaves.isEmpty)
        XCTAssertTrue(h.status.contains("链接"))
        try h.replace("https://example.test/single"); h.save()
        XCTAssertTrue(h.saves.isEmpty); XCTAssertEqual(h.wholeSaves.count, 1)
        XCTAssertEqual(h.wholeSaves[0].0.text, "https://example.test/single")
    }

    func testMinimumMixedEditorLayoutKeepsSelectorErrorAndActionsInsideWindow() throws {
        let h = PartEditHarness(); defer { h.close() }; h.load()
        let window = try XCTUnwrap(h.windows.last)
        window.setContentSize(NSSize(width: 440, height: 360)); window.contentView?.layoutSubtreeIfNeeded()
        let root = try XCTUnwrap(window.contentView)
        let controls: [NSView] = [try h.picker(), try h.view(NSButton.self, title: "保存修改"),
            try h.view(NSButton.self, title: "放弃修改"), try h.view(NSTextField.self, label: "编辑状态")]
        for control in controls { XCTAssertTrue(root.bounds.contains(control.convert(control.bounds, to: root))) }
    }
}
