import AppKit
import XCTest
import ClipShelfLocalization
@testable import ClipShelf
@testable import ClipShelfCore

@MainActor private final class PresentationHarness {
    let panel = ClipboardPanelController()
    var visibleFrame = NSRect(x: 0, y: 30, width: 1440, height: 870)
    var requests: [(PanelPageRequest, (Result<PanelHistoryPage, Error>) -> Void)] = []
    var savedHeights: [(Bool, CGFloat)] = []

    init(remote: Bool = true) {
        let window = UnshownTestPanel(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 430),
            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.contentView = panel.window?.contentView; window.delegate = panel; panel.window = window
        panel.resolveVisibleScreenFrame = { [weak self] _ in self?.visibleFrame ?? .zero }
        panel.onPreferredHeightChange = { [weak self] compact, height in self?.savedHeights.append((compact, height)) }
        if remote { panel.onPageRequest = { [weak self] request, reply in self?.requests.append((request, reply)) } }
    }

    func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
    var views: [NSView] { panel.window?.contentView.map(descendants) ?? [] }
    var texts: [String] { views.compactMap { ($0 as? NSTextField)?.stringValue } }
    func view<T: NSView>(_ type: T.Type, label: String? = nil) throws -> T {
        try XCTUnwrap(views.compactMap { $0 as? T }.first { label == nil || $0.accessibilityLabel() == label })
    }
    func retryButton() throws -> NSButton {
        try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == L10n.text("重试读取") })
    }
    func reply(_ records: [ClipboardRecordMetadata] = []) throws {
        try XCTUnwrap(requests.last).1(.success(.init(records: records, offset: 0, hasMore: false, focusID: nil)))
    }
    func search(_ text: String) throws {
        let field = try view(NSSearchField.self)
        field.stringValue = text
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }
    func resize(height: CGFloat) throws {
        let window = try XCTUnwrap(panel.window)
        var frame = window.frame; frame.size.height = height
        window.setFrame(frame, display: false)
        panel.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
    }
    func close() { panel.perform(NSSelectorFromString("discardDetail")); panel.dismiss() }
}

@MainActor final class PanelPresentationTests: XCTestCase {
    func testInitialRemoteLoadingFailureRetryAndConfirmedEmptyHaveDistinctPresentation() throws {
        let h = PresentationHarness(); defer { h.close() }
        h.panel.show(metadata: [])
        XCTAssertEqual(h.requests.count, 1)
        XCTAssertTrue(h.texts.contains(L10n.text("正在读取条目…")))
        XCTAssertFalse(h.texts.contains(L10n.text("复制一点内容，从这里开始")))
        XCTAssertFalse(h.texts.contains(L10n.text("没有找到相关内容")))
        XCTAssertTrue(try h.retryButton().isHidden)
        h.requests[0].1(.failure(HistoryStoreError.recordNotFound))
        XCTAssertTrue(h.texts.contains(L10n.text("读取未完成，原因见下方。")))
        XCTAssertFalse(try h.retryButton().isHidden)
        XCTAssertTrue(try h.retryButton().isEnabled)
        h.panel.perform(NSSelectorFromString("retryPageLoading"))
        XCTAssertEqual(h.requests.count, 2)
        XCTAssertTrue(h.texts.contains(L10n.text("正在读取条目…")))
        XCTAssertTrue(try h.retryButton().isHidden)
        try h.reply()
        XCTAssertTrue(h.texts.contains(L10n.text("复制一点内容，从这里开始")))
        XCTAssertFalse(h.texts.contains(L10n.text("正在读取条目…")))
    }

    func testSearchEmptyStateWaitsForCurrentResponseAndIgnoresOldFailure() throws {
        let h = PresentationHarness(); defer { h.close() }
        h.panel.show(metadata: [])
        let oldReply = try XCTUnwrap(h.requests.first).1
        try h.search("synthetic missing text")
        XCTAssertEqual(h.requests.count, 2)
        XCTAssertFalse(h.texts.contains(L10n.text("没有找到相关内容")))
        oldReply(.failure(HistoryStoreError.recordNotFound))
        XCTAssertTrue(h.texts.contains(L10n.text("正在读取条目…")))
        XCTAssertTrue(try h.retryButton().isHidden)
        try h.reply()
        XCTAssertTrue(h.texts.contains(L10n.text("没有找到相关内容")))
        XCTAssertFalse(h.texts.contains(L10n.text("复制一点内容，从这里开始")))
        XCTAssertFalse(h.texts.contains(L10n.text("正在读取条目…")))
    }

    func testFailedRefreshKeepsCardsAndOffersRetryWithoutAcceptingObsoleteResults() throws {
        let h = PresentationHarness(); defer { h.close() }
        h.panel.show(metadata: [])
        let record = ClipboardRecordMetadata(id: UUID(), text: "synthetic history", sourceApp: nil,
            sourceBundleID: nil, copiedAt: Date(), renamedTitle: nil, ocrText: nil, pinboardID: nil,
            pinboardOrder: nil, isInHistory: true, revision: 1, kind: .text,
            representationTypes: [], originDeviceID: nil, originDeviceName: nil, originDeviceConflict: false)
        try h.reply([record])
        let collection = try h.view(NSCollectionView.self)
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 1)
        try h.search("new condition")
        h.requests.last?.1(.failure(HistoryStoreError.recordNotFound))
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 1)
        XCTAssertFalse(try h.retryButton().isHidden)
        h.panel.perform(NSSelectorFromString("retryPageLoading"))
        XCTAssertEqual(h.requests.last?.0.query.text, "new condition")
        XCTAssertEqual(h.requests.last?.0.offset, 0)
        try h.reply()
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 0)
        XCTAssertTrue(h.texts.contains(L10n.text("没有找到相关内容")))
    }

    func testNormalAndCompactHeightsSurviveReopenAndProgrammaticClampingDoesNotOverwriteThem() throws {
        let h = PresentationHarness(remote: false); defer { h.close() }
        h.panel.setPreferredHeights(normal: 510, compact: 360)
        h.panel.show(records: [])
        XCTAssertEqual(h.panel.window?.frame.height, 510)
        try h.resize(height: 590)
        XCTAssertEqual(h.savedHeights.last?.0, false)
        XCTAssertEqual(h.savedHeights.last?.1, 590)
        h.panel.setCompactMode(true)
        XCTAssertEqual(h.panel.window?.frame.height, 360)
        try h.resize(height: 390)
        XCTAssertEqual(h.savedHeights.last?.0, true)
        XCTAssertEqual(h.savedHeights.last?.1, 390)
        let count = h.savedHeights.count
        h.panel.setCompactMode(false)
        XCTAssertEqual(h.panel.window?.frame.height, 590)
        h.panel.dismiss()
        h.visibleFrame = NSRect(x: -1400, y: -40, width: 1024, height: 500)
        h.panel.show(records: [])
        let clamped = try XCTUnwrap(h.panel.window?.frame)
        XCTAssertEqual(clamped.height, 464)
        XCTAssertTrue(h.visibleFrame.contains(clamped))
        XCTAssertEqual(h.savedHeights.count, count, "Moving to a smaller screen must not save the clamped height")
        h.panel.dismiss()
        h.visibleFrame = NSRect(x: 1800, y: 20, width: 1440, height: 870)
        h.panel.show(records: [])
        XCTAssertEqual(h.panel.window?.frame.height, 590)
        h.panel.setCompactMode(true)
        XCTAssertEqual(h.panel.window?.frame.height, 390)
        XCTAssertEqual(h.savedHeights.count, count)
    }

    func testPreservedDraftMovesToNewScreenWithoutReloadingOrLosingSelectionAndUndo() throws {
        let h = PresentationHarness(remote: false); defer { h.close() }
        let record = ClipboardRecord(text: "original draft")
        var detail: NSPanel?, preparations = 0, outputs = 0
        h.panel.presentDetailPanel = { window, _ in detail = window }
        h.panel.onPrepareEdit = { _, reply in preparations += 1; reply(.success(.init(record: record))) }
        h.panel.onPaste = { _, _ in outputs += 1 }
        h.panel.show(records: [record]); h.panel.edit(record)
        let draft = try XCTUnwrap(detail)
        let root = try XCTUnwrap(draft.contentView)
        let editor = try XCTUnwrap(h.descendants(root).compactMap { $0 as? NSTextView }.first)
        editor.breakUndoCoalescing()
        editor.insertText("preserved draft", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        editor.breakUndoCoalescing()
        editor.setSelectedRange(NSRange(location: 2, length: 3))
        let undo = try XCTUnwrap(editor.undoManager)
        XCTAssertTrue(undo.canUndo)
        h.panel.hidePreservingDraft()
        XCTAssertTrue(h.panel.hasPreservedDraft)
        h.visibleFrame = NSRect(x: 1800, y: 60, width: 1280, height: 760)
        h.panel.show(records: [])
        XCTAssertTrue(h.visibleFrame.contains(try XCTUnwrap(h.panel.window?.frame)))
        XCTAssertTrue(h.visibleFrame.contains(draft.frame))
        XCTAssertTrue(detail === draft)
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(editor.string, "preserved draft")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 3))
        XCTAssertTrue(draft.firstResponder === editor)
        XCTAssertTrue(editor.undoManager === undo)
        XCTAssertTrue(undo.canUndo)
        XCTAssertEqual(outputs, 0)
        undo.undo()
        XCTAssertEqual(editor.string, "original draft")
    }

    func testGeometryUsesVisibleOriginsAndBoundsAndRejectsInvalidSavedHeights() {
        XCTAssertEqual(PanelPresentationGeometry.preferredHeight(.nan, compact: false), 330)
        XCTAssertEqual(PanelPresentationGeometry.preferredHeight(-1, compact: true), 240)
        XCTAssertEqual(PanelPresentationGeometry.preferredHeight(180, compact: true), 240)
        for visible in [NSRect(x: -1200, y: 45, width: 1024, height: 650),
                        NSRect(x: 2400, y: -700, width: 600, height: 390)] {
            let shelf = PanelPresentationGeometry.shelf(in: visible, preferredHeight: 900)
            XCTAssertTrue(visible.contains(shelf))
            XCTAssertEqual(shelf.midX, visible.midX)
            XCTAssertEqual(shelf.minY, visible.minY + 18)
            XCTAssertTrue(visible.contains(PanelPresentationGeometry.detail(size: NSSize(width: 800, height: 800), in: visible)))
        }
    }

    func testCancelledPageDuringHiddenDraftRestartsOnResumeAndCannotApplyOldReply() throws {
        let h = PresentationHarness(remote: false); defer { h.close() }
        let record = ClipboardRecord(text: "synthetic original")
        let metadata = ClipboardRecordMetadata(id: record.id, text: record.text, sourceApp: nil,
            sourceBundleID: nil, copiedAt: record.copiedAt, renamedTitle: nil, ocrText: nil,
            pinboardID: nil, pinboardOrder: nil, isInHistory: true, revision: record.revision,
            kind: .text, representationTypes: [], originDeviceID: nil, originDeviceName: nil,
            originDeviceConflict: false)
        var pending: ((Result<PanelHistoryPage, Error>) -> Void)?
        var requests = 0, cancellations = 0, copies = 0
        h.panel.onPageRequest = { _, reply in requests += 1; pending = reply }
        // The production coordinator deliberately discards a cancelled completion.
        h.panel.onDismiss = { cancellations += 1; pending = nil }
        h.panel.resolveSelection = { _, reply in reply(.success([record])) }
        h.panel.onCopyRecords = { _ in copies += 1 }
        h.panel.onCopy = { _ in copies += 1 }
        var detail: NSPanel?
        h.panel.presentDetailPanel = { window, _ in detail = window }
        h.panel.onPrepareEdit = { _, reply in reply(.success(.init(record: record))) }
        h.panel.show(metadata: [])
        try XCTUnwrap(pending)(.success(.init(records: [metadata], offset: 0, hasMore: false, focusID: nil)))
        pending = nil
        h.panel.edit(record)
        let editor = try XCTUnwrap(detail?.contentView.flatMap { root in
            h.descendants(root).compactMap { $0 as? NSTextView }.first
        })
        editor.insertText("preserved edit", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        h.panel.refreshPage()
        XCTAssertEqual(requests, 2)
        let retiredReply = try XCTUnwrap(pending)
        h.panel.hidePreservingDraft()
        XCTAssertEqual(cancellations, 1)
        XCTAssertNil(pending)
        h.panel.show(metadata: [])
        XCTAssertEqual(requests, 3, "Restoring a draft must restart its cancelled background page read")
        XCTAssertEqual(editor.string, "preserved edit")
        XCTAssertTrue(detail?.firstResponder === editor)
        retiredReply(.failure(HistoryStoreError.recordNotFound))
        XCTAssertTrue(try h.retryButton().isHidden)
        try XCTUnwrap(pending)(.success(.init(records: [metadata], offset: 0, hasMore: false, focusID: record.id)))
        XCTAssertFalse(h.texts.contains(L10n.text("正在读取条目…")))
        h.panel.perform(NSSelectorFromString("discardDetail"))
        let item = NSMenuItem(title: "copy fixture", action: nil, keyEquivalent: "")
        item.representedObject = record.id
        h.panel.perform(NSSelectorFromString("copyFromMenu:"), with: item)
        XCTAssertEqual(copies, 1, "The restored list must permit a fresh validated action after the draft closes")
    }
}
