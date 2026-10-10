import AppKit
import XCTest
@testable import ClipShelf
@testable import ClipShelfCore

@MainActor private final class MultipartRoutingHarness {
    let panel = ClipboardPanelController()
    let original: ClipboardRecord
    var previews: [MultipartPreviewController] = []
    var previewRecords: [ClipboardRecord] = []
    var details: [NSPanel] = []
    var prepared: [ClipboardSelectionReference] = []
    var files: [ClipboardRecord] = []
    var images: [ClipboardRecord] = []
    var copies: [ClipboardRecord] = []
    var pastes: [ClipboardRecord] = []

    init(record: ClipboardRecord? = nil) {
        original = record ?? ClipboardRecord(text: "aggregate must not become a selected object's body", parts: [
            .init(representations: [.init(typeIdentifier: "public.file-url", data: Data("file:///synthetic/one.txt".utf8))]),
            .init(representations: [.init(typeIdentifier: "public.utf8-plain-text", data: Data("second object".utf8))]),
            .init(representations: [.init(typeIdentifier: "public.png", data: Data([0, 1, 2]))])
        ])
        let parent = Self.window()
        parent.contentView = panel.window?.contentView; parent.delegate = panel; panel.window = parent
        panel.makeMultipartPreview = { [weak self] record in
            let preview = MultipartPreviewController(record: record, window: Self.window())
            preview.presentWindow = { _, _ in }
            self?.previews.append(preview); self?.previewRecords.append(record)
            return preview
        }
        panel.makeFilePreview = { [weak self] record, prefer in
            self?.files.append(record)
            return FileReferencePreviewController(record: record, preferUnavailable: prefer, window: Self.window(),
                openURL: { _ in XCTFail("Routing must not open a file"); return false },
                previewURL: { _ in XCTFail("Routing must not launch Quick Look") })
        }
        panel.makeImagePreview = { [weak self] record, query in
            self?.images.append(record)
            let preview = ImagePreviewController(record: record, searchQuery: query)
            preview.presentWindow = { _, _ in }
            preview.recognizeImage = { _ in throw CancellationError() }
            return preview
        }
        panel.presentDetailPanel = { [weak self] detail, _ in self?.details.append(detail) }
        panel.onPrepareEdit = { [weak self] ref, reply in
            guard let self else { return }
            self.prepared.append(ref)
            reply(.success(.init(record: self.original, syncConfiguration: .init(accountID: nil, generation: 0),
                                 sharingConfiguration: .init(accountID: nil, generation: 0))))
        }
        panel.onCopy = { [weak self] in self?.copies.append($0) }
        panel.onPaste = { [weak self] record, _ in self?.pastes.append(record) }
        panel.show(records: [original])
    }

    static func window() -> UnshownTestPanel {
        UnshownTestPanel(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 430),
                         styleMask: .borderless, backing: .buffered, defer: false)
    }
    func menu(_ action: String) {
        let item = NSMenuItem(); item.representedObject = original.id
        panel.perform(NSSelectorFromString(action), with: item)
    }
    func key(_ code: UInt16, characters: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: try XCTUnwrap(panel.window).windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
    func close() {
        panel.perform(NSSelectorFromString("discardDetail")); panel.dismiss()
    }
}

@MainActor final class MultipartPreviewRoutingTests: XCTestCase {
    func testSpaceAndContextPreviewRouteFullMixedRecordWithoutEditingOrOutput() throws {
        for useMenu in [true, false] {
            let h = MultipartRoutingHarness(); defer { h.close() }
            if useMenu { h.menu("previewFromMenu:") }
            else {
                XCTAssertTrue(h.panel.handleKey(try h.key(36, characters: "\r")))
                XCTAssertTrue(h.panel.handleKey(try h.key(49, characters: " ")))
            }
            XCTAssertEqual(h.previewRecords.count, 1)
            XCTAssertEqual(h.previewRecords.first?.parts, h.original.parts)
            XCTAssertTrue(h.prepared.isEmpty); XCTAssertTrue(h.files.isEmpty)
            XCTAssertTrue(h.copies.isEmpty); XCTAssertTrue(h.pastes.isEmpty)
            XCTAssertTrue(h.panel.ownsWindow(h.previews.first?.window))
            XCTAssertFalse(h.panel.captureOutputContext()())
        }
    }

    func testEditUsesOriginalIndexAndFreshCompleteSnapshot() throws {
        let h = MultipartRoutingHarness(); defer { h.close() }
        h.menu("previewFromMenu:")
        let preview = try XCTUnwrap(h.previews.first)
        preview.onEdit?(1)
        XCTAssertEqual(h.prepared, [.init(id: h.original.id, revision: h.original.revision)])
        XCTAssertFalse(h.panel.ownsWindow(preview.window)); XCTAssertTrue(h.panel.hasOpenEditor)
        func find(_ view: NSView) -> NSPopUpButton? {
            if let picker = view as? NSPopUpButton, picker.accessibilityIdentifier() == "editor.part" { return picker }
            return view.subviews.lazy.compactMap(find).first
        }
        let picker = try XCTUnwrap(h.details.last?.contentView.flatMap(find))
        XCTAssertEqual(picker.selectedTag(), 1); XCTAssertEqual(picker.numberOfItems, h.original.parts.count)
        preview.onEdit?(0)
        XCTAssertEqual(h.prepared.count, 1, "A retired preview cannot start another editor")
    }

    func testFileManagementKeepsCompleteRecordAndOriginalSlots() throws {
        let h = MultipartRoutingHarness(); defer { h.close() }
        h.menu("previewFromMenu:")
        let preview = try XCTUnwrap(h.previews.first)
        preview.onFileReferences?()
        XCTAssertEqual(h.files.count, 1); XCTAssertEqual(h.files.first?.parts, h.original.parts)
        XCTAssertFalse(h.panel.ownsWindow(preview.window))
        preview.onFileReferences?(); XCTAssertEqual(h.files.count, 1)
    }

    func testExistingImageToolsReceiveFullRecordWithoutReopeningMultipartSelector() throws {
        let record = ClipboardRecord(text: "image and text", parts: [
            .init(representations: [.init(typeIdentifier: "public.png", data: Data([0, 1, 2]))]),
            .init(representations: [.init(typeIdentifier: "public.utf8-plain-text", data: Data("keep sibling".utf8))])
        ])
        let h = MultipartRoutingHarness(record: record); defer { h.close() }
        h.menu("previewFromMenu:")
        let preview = try XCTUnwrap(h.previews.first)
        preview.onImageTools?()
        XCTAssertEqual(h.images.count, 1); XCTAssertEqual(h.images.first?.parts, record.parts)
        XCTAssertEqual(h.previews.count, 1); XCTAssertFalse(h.panel.ownsWindow(preview.window))
        preview.onImageTools?(); XCTAssertEqual(h.images.count, 1)
    }

    func testParentKeysCannotPasteBehindPreviewAndEscapeOnlyClosesChild() throws {
        let h = MultipartRoutingHarness(); defer { h.close() }
        h.menu("previewFromMenu:")
        let preview = try XCTUnwrap(h.previews.first)
        XCTAssertTrue(h.panel.handleKey(try h.key(36, characters: "\r")))
        h.menu("copyFromMenu:"); h.menu("pasteFromMenu:")
        XCTAssertTrue(h.copies.isEmpty); XCTAssertTrue(h.pastes.isEmpty)
        XCTAssertTrue(h.panel.handleKey(try h.key(53, characters: "\u{1b}")))
        XCTAssertTrue(h.panel.isVisible); XCTAssertFalse(h.panel.ownsWindow(preview.window))
        h.menu("copyFromMenu:")
        XCTAssertEqual(h.copies.first?.parts, h.original.parts)
    }

    func testHideReopenRetiresOldCallbacksAndWindow() throws {
        let h = MultipartRoutingHarness(); defer { h.close() }
        h.menu("previewFromMenu:")
        let old = try XCTUnwrap(h.previews.first)
        h.panel.hideForSuspension()
        XCTAssertFalse(h.panel.ownsWindow(old.window))
        h.panel.show(records: [h.original]); h.menu("previewFromMenu:")
        XCTAssertEqual(h.previews.count, 2)
        old.onEdit?(1); old.onFileReferences?()
        XCTAssertTrue(h.prepared.isEmpty); XCTAssertTrue(h.files.isEmpty)
        XCTAssertTrue(h.panel.ownsWindow(h.previews.last?.window))
    }
}
