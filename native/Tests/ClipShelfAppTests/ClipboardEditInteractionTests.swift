import AppKit
import XCTest
@testable import ClipShelf
@testable import ClipShelfCore

@MainActor private final class EditHarness {
    let panel = ClipboardPanelController()
    let original: ClipboardRecord
    let snapshot: ClipboardEditSnapshot
    var prepared: [(ClipboardSelectionReference, (Result<ClipboardEditSnapshot, Error>) -> Void)] = []
    var saves: [(ClipboardEditSnapshot, ClipboardRecord, (Result<ClipboardSelectionReference, Error>) -> Void)] = []
    var windows: [NSPanel] = []
    var confirmations: [(Bool) -> Void] = []
    var cancelledConfirmations = 0, outputs = 0, dismissals = 0
    init(record: ClipboardRecord = ClipboardRecord(text: "original text")) {
        original = record
        snapshot = .init(record: record, syncConfiguration: .init(accountID: "synthetic", generation: 11),
                         sharingConfiguration: .init(accountID: nil, generation: 7))
        let parent = UnshownTestPanel(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 430), styleMask: .borderless, backing: .buffered, defer: false)
        parent.contentView = panel.window?.contentView; parent.delegate = panel; panel.window = parent
        panel.presentDetailPanel = { [weak self] window, _ in self?.windows.append(window) }
        panel.onPrepareEdit = { [weak self] ref, reply in self?.prepared.append((ref, reply)) }
        panel.onEdit = { [weak self] snapshot, edited, reply in self?.saves.append((snapshot, edited, reply)) }
        panel.confirmDiscardEdits = { [weak self] _, reply in
            self?.confirmations.append(reply)
            return { [weak self] in self?.cancelledConfirmations += 1; reply(false) }
        }
        panel.onPaste = { [weak self] _, _ in self?.outputs += 1 }
        panel.onCopy = { [weak self] _ in self?.outputs += 1 }
        panel.onShareRecord = { [weak self] _ in self?.outputs += 1 }
        panel.onImageFileOutput = { [weak self] _, _ in self?.outputs += 1 }
        panel.onDismiss = { [weak self] in self?.dismissals += 1 }
        panel.show(records: [record]); panel.edit(record)
    }
    func load(_ value: ClipboardEditSnapshot? = nil) { prepared.last?.1(.success(value ?? snapshot)) }
    func window() throws -> NSPanel { try XCTUnwrap(windows.last) }
    func view<T: NSView>(_ type: T.Type, label: String? = nil, title: String? = nil, in window: NSWindow? = nil) throws -> T {
        func find(_ view: NSView) -> T? {
            if let typed = view as? T, (label == nil || typed.accessibilityLabel() == label), (title == nil || (typed as? NSButton)?.title == title) { return typed }
            return view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap((window ?? windows.last)?.contentView.flatMap(find))
    }
    func editor() throws -> NSTextView { try view(NSTextView.self, label: "编辑内容") }
    func replace(_ value: String) throws {
        let editor = try editor(); editor.breakUndoCoalescing()
        editor.insertText(value, replacementRange: NSRange(location: 0, length: editor.attributedString().length))
        editor.breakUndoCoalescing()
    }
    func invoke(_ selector: String) { panel.perform(NSSelectorFromString(selector)) }
    func save() { invoke("saveDetail") }
    var status: String { (try? view(NSTextField.self, label: "编辑状态"))?.stringValue ?? "" }
    func close() { invoke("discardDetail"); panel.dismiss() }
}

@MainActor final class ClipboardEditInteractionTests: XCTestCase {
    func testPrepareBindsOpenVersionAndAccountSnapshotAndNoChangePreservesOriginalFormats() throws {
        let record = ClipboardRecord(text: "original", html: Data("<b>original</b>".utf8))
        let h = EditHarness(record: record); defer { h.close() }
        XCTAssertEqual(h.prepared[0].0, .init(id: record.id, revision: record.revision))
        XCTAssertFalse(try h.editor().isEditable); XCTAssertTrue(h.saves.isEmpty)
        h.load(); XCTAssertTrue(try h.editor().isEditable)
        XCTAssertTrue(try h.view(NSTextField.self, label: "编辑状态").stringValue.isEmpty)
        let detail = try h.window(); h.save()
        XCTAssertFalse(h.panel.ownsWindow(detail)); XCTAssertTrue(h.saves.isEmpty)
    }

    func testSaveFailurePreservesEditorTextAttributesSelectionUndoAndOriginalSnapshotForRetry() throws {
        let h = EditHarness(); defer { h.close() }; h.load(); try h.replace("updated text")
        let editor = try h.editor()
        editor.textStorage?.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 7))
        editor.didChangeText(); editor.setSelectedRange(NSRange(location: 2, length: 4))
        let contents = NSAttributedString(attributedString: editor.attributedString())
        let undo = try XCTUnwrap(editor.undoManager)
        XCTAssertTrue(undo.canUndo)
        h.save(); XCTAssertEqual(h.saves.count, 1); XCTAssertEqual(h.saves[0].0, h.snapshot)
        h.saves[0].2(.failure(NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "保存失败，草稿仍在"])))
        XCTAssertTrue(try h.editor() === editor); XCTAssertTrue(editor.attributedString().isEqual(to: contents))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 4))
        XCTAssertTrue(editor.undoManager === undo); XCTAssertTrue(undo.canUndo)
        XCTAssertEqual(h.status, "保存失败，草稿仍在")
        h.save(); XCTAssertEqual(h.saves.count, 2); XCTAssertEqual(h.saves[1].0, h.snapshot)
        h.saves[1].2(.success(.init(id: h.original.id, revision: h.original.revision + 1)))
        XCTAssertFalse(h.panel.ownsWindow(try h.window()))
    }

    func testPendingSubmissionBlocksRepeatTextAndUndoButExplicitDiscardAllowsLateReceipt() throws {
        let h = EditHarness(); defer { h.close() }; h.load(); try h.replace("pending draft")
        let editor = try h.editor(); let contents = editor.string
        h.save(); h.save(); XCTAssertEqual(h.saves.count, 1)
        XCTAssertFalse(editor.isEditable); XCTAssertNil(editor.undoManager)
        editor.insertText("must not change", replacementRange: NSRange(location: 0, length: editor.attributedString().length))
        XCTAssertEqual(editor.string, contents)
        let old = try h.window(); h.invoke("discardDetail")
        h.panel.edit(h.original); h.load(); try h.replace("new draft")
        let new = try h.window(); XCTAssertFalse(new === old)
        h.saves[0].2(.success(.init(id: h.original.id, revision: h.original.revision + 1)))
        XCTAssertTrue(h.panel.ownsWindow(new)); XCTAssertEqual(try h.editor().string, "new draft")
    }

    func testPreparationFailureRetryAndMismatchedRevisionStayReadOnly() throws {
        let h = EditHarness(); defer { h.close() }
        h.prepared[0].1(.failure(NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "读取失败"])))
        XCTAssertEqual(h.status, "读取失败"); XCTAssertFalse(try h.editor().isEditable)
        XCTAssertTrue(try h.view(NSButton.self, title: "重试读取").isEnabled)
        h.save(); XCTAssertEqual(h.prepared.count, 2)
        var changed = h.original; changed.revision += 1
        h.load(.init(record: changed)); XCTAssertFalse(try h.editor().isEditable); XCTAssertTrue(h.status.contains("条目已变化"))
        h.save(); h.load(); XCTAssertTrue(try h.editor().isEditable)
    }

    func testLatePrepareCannotPopulateReplacedOrClosedEditor() throws {
        let h = EditHarness(); defer { h.close() }; let first = h.prepared[0].1
        h.invoke("discardDetail"); h.panel.edit(h.original)
        let second = try h.editor(); first(.success(h.snapshot))
        XCTAssertFalse(second.isEditable)
        h.load(); XCTAssertTrue(second.isEditable)
        h.invoke("discardDetail"); h.prepared.last?.1(.success(h.snapshot))
        XCTAssertFalse(h.panel.ownsWindow(try h.window()))
    }

    func testRTFEncodingFailureDoesNotCallSaveOrFlattenDraft() throws {
        let h = EditHarness(); defer { h.close() }; h.load(); try h.replace("keep rich draft")
        let editor = try h.editor(); editor.setSelectedRange(NSRange(location: 3, length: 2))
        h.panel.makeEditedRecord = { _, _ in throw ClipboardEditPlanError.richTextEncodingFailed }
        h.save(); XCTAssertTrue(h.saves.isEmpty); XCTAssertEqual(editor.string, "keep rich draft")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 2)); XCTAssertTrue(h.status.contains("草稿已保留"))
        XCTAssertTrue(try h.view(NSButton.self, title: "保存修改").isEnabled)
        h.panel.makeEditedRecord = nil; h.save(); XCTAssertEqual(h.saves.count, 1)
    }

    func testSinglePartRTFLoadsItsFormattingEvenWithoutLegacyRTFField() throws {
        let contents = NSAttributedString(string: "rich content", attributes: [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.red])
        let data = try contents.data(from: NSRange(location: 0, length: contents.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let original = ClipboardRecord(text: contents.string, parts: [.init(representations: [.init(typeIdentifier: NSPasteboard.PasteboardType.rtf.rawValue, data: data)])])
        let h = EditHarness(record: original); defer { h.close() }; h.load()
        let editor = try h.editor()
        XCTAssertEqual(editor.string, contents.string)
        let font = try XCTUnwrap(editor.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold)); XCTAssertEqual(font.pointSize, 18)
    }

    func testMultiObjectAndMalformedRichTextAreExplicitlyReadOnly() throws {
        for record in [ClipboardRecord(text: "two objects", parts: [
            .init(representations: [.init(typeIdentifier: "public.utf8-plain-text", data: Data("one".utf8))]),
            .init(representations: [.init(typeIdentifier: "public.utf8-plain-text", data: Data("two".utf8))])]),
            ClipboardRecord(text: "broken", rtf: Data("not RTF".utf8))] {
            let h = EditHarness(record: record); defer { h.close() }; h.load()
            XCTAssertFalse(try h.editor().isEditable); XCTAssertFalse(h.status.isEmpty)
            XCTAssertFalse(try h.view(NSButton.self, title: "保存修改").isEnabled)
            h.save(); XCTAssertTrue(h.saves.isEmpty)
        }
    }

    func testColorTextAndWellSynchronizeBothDirectionsAndUndoRestoresBoth() throws {
        let h = EditHarness(record: ClipboardRecord(text: "#123456")); defer { h.close() }; h.load()
        let editor = try h.editor(), well = try h.view(NSColorWell.self, label: "选择颜色")
        try h.replace("abcdef")
        XCTAssertEqual(ClipboardEditPlan.hexString(for: well.color), "#ABCDEF")
        // These are separate user events. Let NSUndoManager itself end each
        // event group; manually ending it leaves its scheduled run-loop end
        // callback behind and corrupts the next test that pumps the run loop.
        let undo = try XCTUnwrap(editor.undoManager)
        finishUndoEvent(undo)
        well.color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(well.action), to: well.target, from: well))
        XCTAssertEqual(editor.string, "#FF0000")
        finishUndoEvent(undo)
        undo.undo()
        XCTAssertEqual(editor.string, "abcdef"); XCTAssertEqual(ClipboardEditPlan.hexString(for: well.color), "#ABCDEF")
    }

    private func finishUndoEvent(_ undo: UndoManager, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(1)
        while undo.groupingLevel > 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        XCTAssertEqual(undo.groupingLevel, 0, "The native event group must close on its scheduled run-loop boundary", file: file, line: line)
    }

    func testInvalidColorBlocksSaveButCanBeCorrectedAndNormalTextAcceptsNewline() throws {
        let h = EditHarness(record: ClipboardRecord(text: "#123456")); defer { h.close() }; h.load()
        for invalid in ["#123", "##123456", "#12345678", "12ZZ34"] {
            try h.replace(invalid); XCTAssertFalse(try h.view(NSButton.self, title: "保存修改").isEnabled)
            XCTAssertTrue(h.status.contains("六位 RGB")); h.save(); XCTAssertTrue(h.saves.isEmpty)
        }
        try h.replace("123abc"); XCTAssertTrue(try h.view(NSButton.self, title: "保存修改").isEnabled)
        h.save(); XCTAssertEqual(h.saves[0].1.text, "#123ABC")
        let text = EditHarness(); defer { text.close() }; text.load(); try text.replace("first\nsecond")
        XCTAssertEqual(try text.editor().string, "first\nsecond"); XCTAssertTrue(try text.view(NSButton.self, title: "保存修改").isEnabled)
        XCTAssertEqual(try text.view(NSButton.self, title: "保存修改").keyEquivalent, "")
    }

    func testQueryAndBackgroundRefreshDoNotDiscardOrReauthorizeDraft() throws {
        let h = EditHarness(); defer { h.close() }; h.load(); try h.replace("independent draft")
        let detail = try h.window(), editor = try h.editor()
        let search = try h.view(NSSearchField.self, label: "搜索剪贴板历史", in: h.panel.window)
        search.stringValue = "unrelated filter"; h.panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        h.panel.update(records: [h.original])
        XCTAssertTrue(h.panel.ownsWindow(detail)); XCTAssertTrue(try h.editor() === editor)
        XCTAssertEqual(editor.string, "independent draft"); XCTAssertEqual(h.prepared.count, 1)
        h.save(); XCTAssertEqual(h.saves.count, 1); XCTAssertEqual(h.saves[0].0, h.snapshot)
    }

    func testCloseAndSwitchDetailsOfferContinueOrDiscardWithoutLosingDraft() throws {
        let h = EditHarness(); defer { h.close() }; h.load(); try h.replace("dirty")
        let detail = try h.window(); XCTAssertFalse(h.panel.windowShouldClose(detail))
        XCTAssertEqual(h.confirmations.count, 1); h.confirmations[0](false)
        XCTAssertTrue(h.panel.ownsWindow(detail)); XCTAssertEqual(try h.editor().string, "dirty")
        h.panel.edit(ClipboardRecord(text: "second")); XCTAssertEqual(h.confirmations.count, 2)
        h.confirmations[1](true)
        XCTAssertFalse(h.panel.ownsWindow(detail)); XCTAssertEqual(h.prepared.count, 2)
    }

    func testDismissForActionWaitsAndCancelsDuplicateOrDeclinedContinuation() throws {
        let h = EditHarness(); defer { h.close() }; h.load(); try h.replace("dirty")
        var actions = 0, cancelled = 0
        h.panel.dismissForAction({ actions += 1 }, onCancel: { cancelled += 1 })
        h.panel.dismissForAction({ actions += 10 }, onCancel: { cancelled += 1 })
        XCTAssertEqual(h.confirmations.count, 1); XCTAssertEqual(actions, 0); XCTAssertEqual(cancelled, 1)
        h.confirmations[0](false); XCTAssertEqual(actions, 0); XCTAssertEqual(cancelled, 2)
        h.panel.dismissForAction({ actions += 1 }); h.confirmations[1](true)
        XCTAssertEqual(actions, 1); XCTAssertFalse(h.panel.isVisible)
    }

    func testSuspensionHidesImmediatelyCancelsConfirmationAndExplicitShowRestoresSameDraft() throws {
        let h = EditHarness(); defer { h.close() }; h.load(); try h.replace("keep while locked")
        let editor = try h.editor(), detail = try h.window(); let undo = editor.undoManager
        var cancelled = 0, action = false
        h.panel.dismissForAction({ action = true }, onCancel: { cancelled += 1 })
        h.panel.hideForSuspension()
        XCTAssertFalse(h.panel.isVisible); XCTAssertTrue(h.panel.hasPreservedDraft)
        XCTAssertEqual(cancelled, 1); XCTAssertEqual(h.cancelledConfirmations, 1); XCTAssertFalse(action)
        h.confirmations[0](true); XCTAssertFalse(action)
        h.panel.show(records: [ClipboardRecord(text: "incoming")])
        XCTAssertTrue(h.panel.isVisible); XCTAssertFalse(h.panel.hasPreservedDraft)
        XCTAssertTrue(try h.window() === detail); XCTAssertTrue(try h.editor() === editor)
        XCTAssertEqual(editor.string, "keep while locked"); XCTAssertTrue(editor.undoManager === undo); XCTAssertEqual(h.prepared.count, 1)
    }

    func testActionFromHiddenDraftPresentsConfirmationAndDecliningPreservesEditor() throws {
        let h = EditHarness(); defer { h.close() }; h.load(); try h.replace("hidden draft")
        let detail = try h.window(); h.panel.hidePreservingDraft()
        var action = false, cancelled = false
        let presentations = h.windows.count
        h.panel.dismissForAction({ action = true }, onCancel: { cancelled = true })
        XCTAssertTrue(h.panel.isVisible); XCTAssertGreaterThan(h.windows.count, presentations)
        XCTAssertTrue(try h.window() === detail); XCTAssertEqual(h.confirmations.count, 1)
        h.confirmations[0](false)
        XCTAssertTrue(cancelled); XCTAssertFalse(action); XCTAssertEqual(try h.editor().string, "hidden draft")
    }

    func testSaveReceiptWhileHiddenNeverReopensAndFailureRetainsDraft() throws {
        for success in [false, true] {
            let h = EditHarness(); defer { h.close() }; h.load(); try h.replace("saving")
            h.save(); h.panel.hideForSuspension(); let count = h.windows.count
            h.saves[0].2(success ? .success(.init(id: h.original.id, revision: h.original.revision + 1)) : .failure(NSError(domain: "fixture", code: 1)))
            XCTAssertFalse(h.panel.isVisible); XCTAssertEqual(h.windows.count, count)
            XCTAssertEqual(h.panel.hasPreservedDraft, !success)
            if !success { h.panel.show(records: []); XCTAssertEqual(try h.editor().string, "saving"); XCTAssertTrue(try h.editor().isEditable) }
        }
    }

    func testDetailBlocksHistoryCopyPasteAndDoubleClickOutputBeforeAnyClipboardCallback() throws {
        let h = EditHarness(); defer { h.close() }; h.load(); try h.replace("dirty")
        for (code, text, flags) in [(UInt16(36), "\r", NSEvent.ModifierFlags()), (18, "1", .command), (8, "c", .command)] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1,
                windowNumber: h.panel.window!.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
            XCTAssertTrue(h.panel.handleKey(event))
        }
        h.panel.window?.contentView?.layoutSubtreeIfNeeded()
        if let card = try? h.view(ClipboardCardView.self, in: h.panel.window) {
            card.onOpen?([])
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 40, y: 40), modifierFlags: .option,
                timestamp: 1, windowNumber: h.panel.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            card.mouseDown(with: down)
            XCTAssertTrue(card.draggedRecordIDs.isEmpty)
            card.cancelPendingDrag()
        }
        for selector in ["pasteFromMenu:", "copyFromMenu:", "shareFromMenu:"] {
            let item = NSMenuItem(title: "synthetic", action: NSSelectorFromString(selector), keyEquivalent: "")
            item.representedObject = h.original.id
            h.panel.perform(NSSelectorFromString(selector), with: item)
        }
        XCTAssertEqual(h.outputs, 0); XCTAssertTrue(h.panel.ownsWindow(try h.window()))
    }

    func testOpeningEditorRetiresPayloadDragPreparedBeforeEditorAppeared() throws {
        let h = EditHarness(); defer { h.close() }; h.invoke("discardDetail")
        h.panel.window?.contentView?.layoutSubtreeIfNeeded()
        let card = try h.view(ClipboardCardView.self, in: h.panel.window)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 40, y: 40), modifierFlags: [],
            timestamp: 1, windowNumber: h.panel.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        card.mouseDown(with: down)
        XCTAssertNotNil(card.activeGestureID); XCTAssertEqual(card.draggedRecordIDs, [h.original.id])
        let output = h.panel.captureOutputContext()
        h.panel.edit(h.original)
        XCTAssertNil(card.activeGestureID); XCTAssertTrue(card.draggedRecordIDs.isEmpty); XCTAssertFalse(output())
        let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 90, y: 40), modifierFlags: [],
            timestamp: 2, windowNumber: h.panel.window!.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
        card.mouseDragged(with: drag)
        XCTAssertNil(card.activeGestureID); XCTAssertEqual(h.outputs, 0)
    }

    func testMinimumLayoutLeavesSaveDiscardAndInlineErrorReachable() throws {
        let h = EditHarness(); defer { h.close() }
        h.prepared[0].1(.failure(NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: String(repeating: "中文错误说明", count: 30)])))
        let detail = try h.window(); detail.setContentSize(NSSize(width: 440, height: 320)); detail.contentView?.layoutSubtreeIfNeeded()
        let root = try XCTUnwrap(detail.contentView)
        for title in ["放弃修改", "重试读取"] {
            let button = try h.view(NSButton.self, title: title)
            XCTAssertTrue(root.bounds.contains(button.convert(button.bounds, to: root)), title)
        }
        let status = try h.view(NSTextField.self, label: "编辑状态")
        XCTAssertTrue(root.bounds.contains(status.convert(status.bounds, to: root))); XCTAssertGreaterThan(status.frame.height, 0)
    }
}
