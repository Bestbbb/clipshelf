import AppKit
import ClipShelfCore
import PDFKit
import XCTest
@testable import ClipShelf

private actor ControlledMultipartDecoder {
    struct Request {
        let record: ClipboardRecord
        let index: Int
        let reply: CheckedContinuation<ClipboardPartPreviewPlan, Error>
    }
    private var pending: [Request] = []
    private(set) var indices: [Int] = []
    func load(_ record: ClipboardRecord, index: Int) async throws -> ClipboardPartPreviewPlan {
        try await withCheckedThrowingContinuation { reply in
            indices.append(index); pending.append(Request(record: record, index: index, reply: reply))
        }
    }
    func complete(_ result: Result<ClipboardPartPreviewPlan, Error>? = nil) throws {
        let request = pending.removeFirst()
        let outcome = result ?? Result { try ClipboardPartPreviewPlan.make(original: request.record, partIndex: request.index) }
        request.reply.resume(with: outcome)
    }
}

@MainActor private final class MultipartPreviewHarness {
    let record: ClipboardRecord
    let decoder = ControlledMultipartDecoder()
    let controller: MultipartPreviewController
    var context = true
    var edits: [Int] = []
    var fileActions = 0, imageActions = 0, dismissals = 0

    init(_ supplied: ClipboardRecord? = nil, initialPartIndex: Int = 0) {
        let record = supplied ?? Self.fixture()
        self.record = record
        let decoder = decoder
        let window = UnshownTestPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 660),
                                     styleMask: .borderless, backing: .buffered, defer: false)
        controller = MultipartPreviewController(record: record, initialPartIndex: initialPartIndex, window: window,
            loader: { record, index in try await decoder.load(record, index: index) })
        controller.presentWindow = { window, _ in window.makeKeyAndOrderFront(nil) }
        controller.isContextCurrent = { [weak self] in self?.context == true }
        controller.onEdit = { [weak self] in self?.edits.append($0) }
        controller.onFileReferences = { [weak self] in self?.fileActions += 1 }
        controller.onImageTools = { [weak self] in self?.imageActions += 1 }
        controller.onDismiss = { [weak self] in self?.dismissals += 1 }
        controller.present(relativeTo: nil)
    }

    func waitForRequests(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if await decoder.indices.count == count { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Decoder did not receive expected request count \(count)", file: file, line: line)
    }

    func finish(_ result: Result<ClipboardPartPreviewPlan, Error>? = nil,
                file: StaticString = #filePath, line: UInt = #line) async throws {
        try await decoder.complete(result)
        for _ in 0..<500 {
            if !controller.isLoading { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Preview did not finish loading", file: file, line: line)
    }

    func view<T: NSView>(_ type: T.Type, identifier: String? = nil, title: String? = nil) throws -> T {
        func find(_ view: NSView) -> T? {
            if let typed = view as? T,
               identifier == nil || typed.accessibilityIdentifier() == identifier,
               title == nil || (typed as? NSButton)?.title == title { return typed }
            return view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(controller.window?.contentView.flatMap(find))
    }

    static func fixture() -> ClipboardRecord {
        ClipboardRecord(text: "Aggregate must never be preview content", parts: [
            part("public.utf8-plain-text", "first"), part("test.vendor.opaque", "binary"),
            part("public.utf8-plain-text", "third")
        ], ocrText: "Aggregate OCR must not appear")
    }
    static func part(_ type: String, _ text: String) -> ClipboardPart {
        .init(representations: [.init(typeIdentifier: type, data: Data(text.utf8))])
    }
}

@MainActor final class MultipartPreviewControllerTests: XCTestCase {
    func testAllObjectsRemainInOriginalOrderAndOnlySelectedObjectLoads() async throws {
        let h = MultipartPreviewHarness(); defer { h.controller.dismiss() }
        try await h.waitForRequests(1)
        let selector = try h.view(NSPopUpButton.self, identifier: "preview.part")
        XCTAssertEqual(selector.numberOfItems, 3)
        for index in 0..<3 { XCTAssertTrue(selector.itemTitle(at: index).contains("\(index + 1)")) }
        let requested = await h.decoder.indices
        XCTAssertEqual(requested, [0]); XCTAssertTrue(h.controller.isLoading)
        XCTAssertFalse(try h.view(NSButton.self, title: "编辑").isEnabled)
        try await h.finish()
        XCTAssertEqual(try h.view(NSTextView.self, identifier: "preview.contents").string, "first")
        XCTAssertFalse(try h.view(NSTextView.self, identifier: "preview.contents").isEditable)
        XCTAssertEqual(h.controller.displayedPlan?.partIndex, 0)
    }

    func testUnsupportedObjectShowsBytesWithoutDroppingItsRowAndEditUsesOriginalThirdIndex() async throws {
        let h = MultipartPreviewHarness(initialPartIndex: 1); defer { h.controller.dismiss() }
        try await h.waitForRequests(1); try await h.finish()
        XCTAssertEqual(h.controller.displayedPlan?.partIndex, 1)
        XCTAssertTrue(try h.view(NSTextView.self, identifier: "preview.formats").string.contains("test.vendor.opaque"))
        XCTAssertFalse(try h.view(NSButton.self, title: "编辑").isEnabled)
        h.controller.editSelected(); XCTAssertTrue(h.edits.isEmpty)
        h.controller.selectPart(at: 2); try await h.waitForRequests(2); try await h.finish()
        XCTAssertEqual(try h.view(NSTextView.self, identifier: "preview.contents").string, "third")
        XCTAssertTrue(try h.view(NSButton.self, title: "编辑").isEnabled)
        h.controller.editSelected(); XCTAssertEqual(h.edits, [2])
        XCTAssertEqual(try h.view(NSPopUpButton.self, identifier: "preview.part").numberOfItems, 3)
    }

    func testRapidSwitchesCancelOldDecoderAndCoalesceToLatestWithoutParallelDecoding() async throws {
        let h = MultipartPreviewHarness(); defer { h.controller.dismiss() }
        try await h.waitForRequests(1)
        h.controller.selectPart(at: 1); h.controller.selectPart(at: 2)
        XCTAssertNil(h.controller.displayedPlan)
        XCTAssertEqual(try h.view(NSTextView.self, identifier: "preview.contents").string, "")
        let before = await h.decoder.indices; XCTAssertEqual(before, [0])
        try await h.decoder.complete()
        try await h.waitForRequests(2)
        let after = await h.decoder.indices; XCTAssertEqual(after, [0, 2])
        XCTAssertNil(h.controller.displayedPlan)
        try await h.finish()
        XCTAssertEqual(h.controller.displayedPlan?.partIndex, 2)
        XCTAssertEqual(try h.view(NSTextView.self, identifier: "preview.contents").string, "third")
    }

    func testDismissAndReopenRejectOldSessionAndRunOnlyNewSelection() async throws {
        let h = MultipartPreviewHarness(); defer { h.controller.dismiss() }
        try await h.waitForRequests(1)
        h.controller.dismiss(); h.controller.dismiss()
        XCTAssertEqual(h.dismissals, 1)
        h.controller.present(relativeTo: nil); h.controller.selectPart(at: 2)
        try await h.decoder.complete(); try await h.waitForRequests(2)
        XCTAssertNil(h.controller.displayedPlan)
        try await h.finish()
        XCTAssertEqual(h.controller.displayedPlan?.partIndex, 2)
        let requested = await h.decoder.indices; XCTAssertEqual(requested, [0, 2])
    }

    func testContextInvalidationDuringDecodeDismissesAndRejectsLateContent() async throws {
        let h = MultipartPreviewHarness(); try await h.waitForRequests(1)
        h.context = false
        try await h.finish()
        XCTAssertNil(h.controller.displayedPlan); XCTAssertEqual(h.dismissals, 1)
        XCTAssertFalse(h.controller.window?.isVisible == true)
        XCTAssertEqual(try h.view(NSTextView.self, identifier: "preview.contents").string, "")
        h.controller.editSelected(); XCTAssertTrue(h.edits.isEmpty)
    }

    func testExplicitInvalidationDoesNotAwaitUncooperativeDecoder() async throws {
        let h = MultipartPreviewHarness(); try await h.waitForRequests(1)
        h.controller.invalidateContext()
        XCTAssertEqual(h.dismissals, 1); XCTAssertFalse(h.controller.isLoading)
        XCTAssertFalse(h.controller.window?.isVisible == true)
        try await h.finish()
        XCTAssertNil(h.controller.displayedPlan)
    }

    func testFailedOrWrongPartResultClearsOldContentAndKeepsSelectedMetadata() async throws {
        let h = MultipartPreviewHarness(); defer { h.controller.dismiss() }
        try await h.waitForRequests(1); try await h.finish()
        h.controller.selectPart(at: 1); try await h.waitForRequests(2)
        try await h.finish(.failure(NSError(domain: "Synthetic decode", code: 1)))
        XCTAssertNil(h.controller.displayedPlan)
        XCTAssertEqual(try h.view(NSTextView.self, identifier: "preview.contents").string, "")
        XCTAssertTrue(try h.view(NSTextView.self, identifier: "preview.formats").string.contains("test.vendor.opaque"))
        XCTAssertFalse(try h.view(NSButton.self, title: "编辑").isEnabled)
        h.controller.selectPart(at: 2); try await h.waitForRequests(3)
        let wrong = try ClipboardPartPreviewPlan.make(original: h.record, partIndex: 0)
        try await h.finish(.success(wrong))
        XCTAssertNil(h.controller.displayedPlan)
        XCTAssertFalse(try h.view(NSButton.self, title: "编辑").isEnabled)
    }

    func testNativeRichTextRetainsAttributesAndAttachmentWhileReadOnlyActionsStayDisabled() async throws {
        let attachment = NSTextAttachment()
        attachment.image = NSImage(size: NSSize(width: 2, height: 2))
        let rich = NSMutableAttributedString(string: "Native ", attributes: [.font: NSFont.boldSystemFont(ofSize: 19)])
        rich.append(NSAttributedString(attachment: attachment))
        rich.addAttribute(.link, value: URL(string: "https://example.invalid/")!, range: NSRange(location: 0, length: 6))
        let record = ClipboardRecord(text: "Aggregate", parts: [MultipartPreviewHarness.part("com.apple.flat-rtfd", "synthetic")])
        let h = MultipartPreviewHarness(record); defer { h.controller.dismiss() }
        try await h.waitForRequests(1)
        let plan = ClipboardPartPreviewPlan(partIndex: 0, representations: [], content: .richText(rich), isTruncated: false)
        try await h.finish(.success(plan))
        let text = try h.view(NSTextView.self, identifier: "preview.contents")
        XCTAssertEqual(text.string, rich.string); XCTAssertFalse(text.isEditable)
        XCTAssertNotNil(text.textStorage?.attribute(.attachment, at: rich.length - 1, effectiveRange: nil))
        XCTAssertEqual((text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 19)
        XCTAssertTrue(h.controller.textView(text, clickedOnLink: "https://example.invalid/", at: 0))
        XCTAssertNil(h.controller.textView(text, urlForContentsOf: attachment, at: rich.length - 1))
        XCTAssertTrue(text.quickLookPreviewableItems(inRanges: [NSValue(range: NSRange(location: 0, length: rich.length))]).isEmpty)
        XCTAssertFalse(try h.view(NSButton.self, title: "编辑").isEnabled)
    }

    func testHTMLStaysLiteralSourceAndTruncationNoticeIsVisible() async throws {
        let html = "<img src='https://example.invalid/tracker'><script>alert(1)</script>"
        let h = MultipartPreviewHarness(ClipboardRecord(text: "aggregate", parts: [MultipartPreviewHarness.part("public.html", html)]))
        defer { h.controller.dismiss() }
        try await h.waitForRequests(1)
        let plan = ClipboardPartPreviewPlan(partIndex: 0, representations: [], content: .htmlSource(html), isTruncated: true)
        try await h.finish(.success(plan))
        XCTAssertEqual(try h.view(NSTextView.self, identifier: "preview.contents").string, html)
        XCTAssertEqual(try h.view(NSTextField.self, identifier: "preview.status").stringValue, "预览仅显示部分内容；原始内容保持完整。")
        XCTAssertFalse(try h.view(NSButton.self, title: "编辑").isEnabled)
    }

    func testFileMetadataActionStaysSeparateAndReportsParentIntentOnly() async throws {
        let url = URL(fileURLWithPath: "/does-not-exist/ClipShelf-synthetic/file.txt")
        let record = ClipboardRecord(text: "aggregate", parts: [MultipartPreviewHarness.part("public.file-url", url.absoluteString),
                                                               MultipartPreviewHarness.part("public.utf8-plain-text", "sibling")])
        let h = MultipartPreviewHarness(record); defer { h.controller.dismiss() }
        try await h.waitForRequests(1); try await h.finish()
        XCTAssertEqual(try h.view(NSTextView.self, identifier: "preview.contents").string, url.path)
        XCTAssertTrue(try h.view(NSButton.self, title: "文件与位置…").isEnabled)
        h.controller.showFileReferences(); XCTAssertEqual(h.fileActions, 1)
        h.controller.selectPart(at: 1); try await h.waitForRequests(2); try await h.finish()
        h.controller.showFileReferences(); XCTAssertEqual(h.fileActions, 1)
        XCTAssertTrue(try h.view(NSButton.self, title: "文件与位置…").isHidden)
    }

    func testImageToolsAreAvailableOnlyForOriginalFirstImage() async throws {
        let record = ClipboardRecord(text: "aggregate", parts: [MultipartPreviewHarness.part("public.utf8-plain-text", "text"),
            MultipartPreviewHarness.part("public.png", "first"), MultipartPreviewHarness.part("public.png", "second")])
        let h = MultipartPreviewHarness(record, initialPartIndex: 1); defer { h.controller.dismiss() }
        let image = NSImage(size: NSSize(width: 2, height: 2))
        try await h.waitForRequests(1)
        try await h.finish(.success(.init(partIndex: 1, representations: [], content: .image(image), isTruncated: false)))
        XCTAssertTrue(try h.view(NSButton.self, title: "图片与识别文字").isEnabled)
        h.controller.showImageTools(); XCTAssertEqual(h.imageActions, 1)
        XCTAssertFalse(try h.view(NSImageView.self, identifier: "preview.image").isHidden)
        h.controller.selectPart(at: 2); try await h.waitForRequests(2)
        try await h.finish(.success(.init(partIndex: 2, representations: [], content: .image(image), isTruncated: false)))
        XCTAssertTrue(try h.view(NSButton.self, title: "图片与识别文字").isHidden)
        h.controller.showImageTools(); XCTAssertEqual(h.imageActions, 1)
    }

    func testMalformedFileURLRetainsFileManagementAfterPreviewFallback() async throws {
        let record = ClipboardRecord(text: "aggregate", parts: [MultipartPreviewHarness.part("public.file-url", "invalid URL")])
        let h = MultipartPreviewHarness(record); defer { h.controller.dismiss() }
        try await h.waitForRequests(1); try await h.finish()
        guard case .unavailable? = h.controller.displayedPlan?.content else { return XCTFail("Expected format-only fallback") }
        XCTAssertTrue(try h.view(NSButton.self, title: "文件与位置…").isEnabled)
        h.controller.showFileReferences(); XCTAssertEqual(h.fileActions, 1)
    }

    func testImageDecodeFailureRetainsExistingImageToolsAndFileRecordNeverOffersThem() async throws {
        let record = ClipboardRecord(text: "aggregate", parts: [MultipartPreviewHarness.part("public.png", "unreadable image")])
        let h = MultipartPreviewHarness(record); defer { h.controller.dismiss() }
        try await h.waitForRequests(1); try await h.finish(.failure(NSError(domain: "Synthetic bounded decode", code: 1)))
        XCTAssertNil(h.controller.displayedPlan)
        XCTAssertTrue(try h.view(NSButton.self, title: "图片与识别文字").isEnabled)
        h.controller.showImageTools(); XCTAssertEqual(h.imageActions, 1)

        var fileRecord = record
        fileRecord.parts.append(MultipartPreviewHarness.part("public.file-url", "file:///synthetic/path"))
        let fileHarness = MultipartPreviewHarness(fileRecord); defer { fileHarness.controller.dismiss() }
        try await fileHarness.waitForRequests(1); try await fileHarness.finish()
        XCTAssertTrue(try fileHarness.view(NSButton.self, title: "图片与识别文字").isHidden)
        fileHarness.controller.showImageTools(); XCTAssertEqual(fileHarness.imageActions, 0)
    }

    func testPDFDisplaysSelectedDocumentAndIsReleasedOnSwitch() async throws {
        let record = ClipboardRecord(text: "aggregate", parts: [MultipartPreviewHarness.part("com.adobe.pdf", "synthetic"),
                                                               MultipartPreviewHarness.part("public.utf8-plain-text", "next")])
        let h = MultipartPreviewHarness(record); defer { h.controller.dismiss() }
        let document = PDFDocument(); document.insert(PDFPage(), at: 0)
        try await h.waitForRequests(1)
        try await h.finish(.success(.init(partIndex: 0, representations: [], content: .pdf(document), isTruncated: false)))
        let view = try h.view(PDFView.self, identifier: "preview.pdf")
        XCTAssertTrue(view.document === document); XCTAssertFalse(view.isHidden)
        XCTAssertFalse(try h.view(NSButton.self, title: "编辑").isEnabled)
        h.controller.selectPart(at: 1)
        XCTAssertNil(view.document); XCTAssertTrue(view.isHidden)
        try await h.waitForRequests(2); try await h.finish()
    }

    func testCommandEditUsesSelectedIndexAndEscapeDismissesExactlyOnce() async throws {
        let h = MultipartPreviewHarness(initialPartIndex: 2)
        try await h.waitForRequests(1); try await h.finish()
        let window = try XCTUnwrap(h.controller.window)
        XCTAssertTrue(h.controller.handleKey(key(14, text: "e", modifiers: .command, window: window)))
        XCTAssertEqual(h.edits, [2])
        XCTAssertTrue(h.controller.handleKey(key(53, text: "\u{1b}", window: window)))
        XCTAssertEqual(h.dismissals, 1)
        XCTAssertFalse(h.controller.handleKey(key(53, text: "\u{1b}", window: window)))
        XCTAssertEqual(h.dismissals, 1)
    }

    func testPresentationReentryCannotRestartLoadingAfterDismissal() {
        let record = MultipartPreviewHarness.fixture()
        let panel = UnshownTestPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 660),
                                    styleMask: .borderless, backing: .buffered, defer: false)
        let controller = MultipartPreviewController(record: record, window: panel)
        var dismissed = 0
        controller.onDismiss = { dismissed += 1 }
        controller.presentWindow = { [weak controller] _, _ in controller?.dismiss() }
        controller.present(relativeTo: nil)
        XCTAssertEqual(dismissed, 1); XCTAssertFalse(controller.isLoading)
        XCTAssertNil(controller.displayedPlan)
    }

    private func key(_ code: UInt16, text: String, modifiers: NSEvent.ModifierFlags = [], window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1, windowNumber: window.windowNumber,
                        context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }
}
