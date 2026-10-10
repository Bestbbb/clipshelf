import AppKit
import ClipShelfCore
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import ClipShelf

final class ClipboardPartPreviewPlanTests: XCTestCase {
    private func part(_ type: String, _ data: Data) -> ClipboardPart {
        .init(representations: [.init(typeIdentifier: type, data: data)])
    }

    private func textPart(_ value: String) -> ClipboardPart { part("public.utf8-plain-text", Data(value.utf8)) }

    private func record(_ parts: [ClipboardPart]) -> ClipboardRecord {
        ClipboardRecord(text: "AGGREGATE MUST NEVER APPEAR", rtf: Data(#"{\rtf1 Wrong aggregate}"#.utf8),
                        html: Data("<h1>Wrong aggregate</h1>".utf8), parts: parts, ocrText: "Wrong aggregate OCR")
    }

    private func png(width: Int = 3, height: Int = 2, red: CGFloat = 0.2) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return bytes as Data
    }

    private func pdf(pages: Int = 2) throws -> Data {
        let bytes = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes))
        var box = CGRect(x: 0, y: 0, width: 100, height: 120)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(CGRect(x: 5, y: 7, width: 10, height: 15))
            context.endPDFPage()
        }
        context.closePDF()
        return bytes as Data
    }

    func testSecondaryTextKeepsOriginalIndexAndNeverUsesAggregateOrNeighbor() throws {
        let original = record([textPart("first"), textPart("second 🧪"), textPart("third")])
        let before = original
        let preview = try ClipboardPartPreviewPlan.make(original: original, partIndex: 1)
        XCTAssertEqual(preview.partIndex, 1)
        guard case .text(let value) = preview.content else { return XCTFail("Expected selected plain text") }
        XCTAssertEqual(value, "second 🧪")
        XCTAssertEqual(preview.representations, [.init(typeIdentifier: "public.utf8-plain-text", byteCount: "second 🧪".utf8.count)])
        XCTAssertFalse(preview.isTruncated)
        XCTAssertEqual(original, before)
    }

    func testSecondaryImageDecodesItsOwnBytesAndBoundsThumbnail() throws {
        let bytes = try png(width: 2_400, height: 12)
        let original = record([textPart("first"), part("public.png", bytes)])
        let before = original
        let preview = try ClipboardPartPreviewPlan.make(original: original, partIndex: 1)
        guard case .image(let image) = preview.content else { return XCTFail("Expected secondary image") }
        XCTAssertEqual(preview.partIndex, 1)
        XCTAssertGreaterThan(image.size.width, image.size.height)
        XCTAssertLessThanOrEqual(image.size.width, CGFloat(ClipboardPartPreviewPlan.maximumImagePixelDimension))
        XCTAssertLessThanOrEqual(image.size.height, CGFloat(ClipboardPartPreviewPlan.maximumImagePixelDimension))
        XCTAssertEqual(preview.representations.first?.byteCount, bytes.count)
        XCTAssertEqual(original, before)
        XCTAssertFalse(ClipboardPartPreviewPlan.isPotentiallyEditable(original: original, partIndex: 1))
    }

    func testSecondaryPDFPreservesAllPagesAndOriginalBytes() throws {
        let bytes = try pdf()
        let original = record([textPart("first"), part("com.adobe.pdf", bytes)])
        let before = original
        let preview = try ClipboardPartPreviewPlan.make(original: original, partIndex: 1)
        guard case .pdf(let document) = preview.content else { return XCTFail("Expected secondary PDF") }
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(preview.partIndex, 1)
        XCTAssertEqual(original, before)
        XCTAssertFalse(ClipboardPartPreviewPlan.isPotentiallyEditable(original: original, partIndex: 1))
    }

    func testAnimatedImageFirstFramePreviewIsExplicitlyPartial() throws {
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.gif.identifier as CFString, 2, nil))
        // ImageIO coalesces identical GIF frames. Use two genuinely different
        // frames and validate the fixture before checking the preview contract.
        for red: CGFloat in [0.2, 0.8] {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(try png(red: red) as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertEqual(CGImageSourceGetCount(try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))), 2)
        let original = record([textPart("first"), part(UTType.gif.identifier, bytes as Data)])
        let before = original
        let preview = try ClipboardPartPreviewPlan.make(original: original, partIndex: 1)
        guard case .image = preview.content else { return XCTFail("Expected first-frame thumbnail") }
        XCTAssertTrue(preview.isTruncated)
        XCTAssertEqual(original, before)
    }

    func testPDFWidgetsAreReadOnlyAndExternalActionsAreRemovedOnlyFromPreview() throws {
        let document = try XCTUnwrap(PDFDocument(data: try pdf()))
        let first = try XCTUnwrap(document.page(at: 0))
        let widget = PDFAnnotation(bounds: CGRect(x: 1, y: 1, width: 20, height: 20), forType: .widget, withProperties: nil)
        widget.widgetFieldType = .text
        first.addAnnotation(widget)
        let external = PDFAnnotation(bounds: CGRect(x: 25, y: 1, width: 20, height: 20), forType: .link, withProperties: nil)
        external.action = PDFActionURL(url: URL(string: "https://unreachable.invalid")!)
        first.addAnnotation(external)
        let internalLink = PDFAnnotation(bounds: CGRect(x: 50, y: 1, width: 20, height: 20), forType: .link, withProperties: nil)
        internalLink.action = PDFActionGoTo(destination: PDFDestination(page: try XCTUnwrap(document.page(at: 1)), at: .zero))
        first.addAnnotation(internalLink)
        let original = record([part("com.adobe.pdf", try XCTUnwrap(document.dataRepresentation()))])
        let before = original
        let preview = try ClipboardPartPreviewPlan.make(original: original, partIndex: 0)
        guard case .pdf(let prepared) = preview.content else { return XCTFail("Expected sanitized read-only PDF") }
        let annotations = try XCTUnwrap(prepared.page(at: 0)).annotations
        XCTAssertEqual(annotations.count, 3)
        XCTAssertTrue(annotations.allSatisfy(\.isReadOnly))
        XCTAssertEqual(annotations.filter { $0.action is PDFActionGoTo }.count, 1)
        XCTAssertFalse(annotations.contains { $0.action is PDFActionURL })
        XCTAssertEqual(original, before)
        let untouched = try XCTUnwrap(PDFDocument(data: original.parts[0].representations[0].data))
        XCTAssertTrue(try XCTUnwrap(untouched.page(at: 0)).annotations.contains { $0.action is PDFActionURL })
    }

    func testRichTextPreviewsNativeAttributesWithoutEditorProjection() throws {
        let original = record([textPart("first"), part("public.rtf", Data(#"{\rtf1\ansi plain \b bold\b0}"#.utf8))])
        let before = original
        let preview = try ClipboardPartPreviewPlan.make(original: original, partIndex: 1)
        guard case .richText(let rich) = preview.content else { return XCTFail("Expected native rich text") }
        XCTAssertEqual(rich.string, "plain bold")
        let font = try XCTUnwrap(rich.attribute(.font, at: 7, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(original, before)
    }

    @MainActor func testRTFDAttachmentIsReadableWhileEditingRemainsUnavailable() throws {
        let wrapper = FileWrapper(regularFileWithContents: try png())
        wrapper.preferredFilename = "fixture.png"
        let contents = NSMutableAttributedString(string: "embedded image: ")
        contents.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        let data = try contents.data(from: NSRange(location: 0, length: contents.length),
                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        let original = record([textPart("first"), part(NSPasteboard.PasteboardType.rtfd.rawValue, data)])
        let before = original
        let preview = try ClipboardPartPreviewPlan.make(original: original, partIndex: 1)
        guard case .richText(let rich) = preview.content else { return XCTFail("Expected RTFD read-only preview") }
        XCTAssertEqual(rich.string, contents.string)
        XCTAssertNotNil(rich.attribute(.attachment, at: rich.length - 1, effectiveRange: nil) as? NSTextAttachment)
        XCTAssertFalse(ClipboardPartPreviewPlan.isPotentiallyEditable(original: original, partIndex: 1))
        XCTAssertThrowsError(try ClipboardEditPlan.partRecord(original: original, partIndex: 1))
        XCTAssertEqual(original, before)
    }

    func testHTMLOnlyReturnsLiteralSourceIncludingExternalReferences() throws {
        let source = "<iframe src='https://unreachable.invalid/'></iframe><script>alert(1)</script><img src='file:///private/fixture.png'>"
        let original = record([textPart("first"), part("public.html", Data(source.utf8))])
        let before = original
        let preview = try ClipboardPartPreviewPlan.make(original: original, partIndex: 1)
        guard case .htmlSource(let value) = preview.content else { return XCTFail("HTML must stay literal source") }
        XCTAssertEqual(value, source)
        XCTAssertEqual(original, before)
    }

    func testFilePreviewOnlyRetainsNonexistentURLAndDoesNotCreateOrRepairIt() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-preview-\(UUID().uuidString).rtf")
        let original = record([textPart("first"), part("public.file-url", Data(url.absoluteString.utf8))])
        let before = original
        let preview = try ClipboardPartPreviewPlan.make(original: original, partIndex: 1)
        guard case .file(let actual) = preview.content else { return XCTFail("Expected stored file URL") }
        XCTAssertEqual(actual, url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(original, before)
    }

    func testUnknownAndMalformedPartsRemainSelectableWithExactRepresentationMetadata() throws {
        for (type, bytes) in [("test.vendor.document", Data([0, 255, 1])), ("public.png", Data("broken".utf8)),
                              ("com.adobe.pdf", Data("broken".utf8)), ("public.rtf", Data("broken".utf8)),
                              (NSPasteboard.PasteboardType.rtfd.rawValue, Data("broken".utf8)),
                              ("public.utf8-plain-text", Data([0xff, 0xff]))] {
            let original = record([textPart("first"), part(type, bytes)])
            let before = original
            let preview = try ClipboardPartPreviewPlan.make(original: original, partIndex: 1)
            guard case .unavailable = preview.content else { XCTFail("Expected safe summary for \(type)"); continue }
            XCTAssertEqual(preview.partIndex, 1)
            XCTAssertEqual(preview.representations, [.init(typeIdentifier: type, byteCount: bytes.count)])
            XCTAssertEqual(original, before)
        }
    }

    func testMalformedPreferredRepresentationFallsBackToSameObjectText() throws {
        let selected = ClipboardPart(representations: [.init(typeIdentifier: "public.png", data: Data([0, 1, 2])),
            .init(typeIdentifier: "public.utf8-plain-text", data: Data("local fallback".utf8))])
        let original = record([textPart("first"), selected])
        let preview = try ClipboardPartPreviewPlan.make(original: original, partIndex: 1)
        guard case .text(let value) = preview.content else { return XCTFail("Expected same-part fallback") }
        XCTAssertEqual(value, "local fallback")
        XCTAssertEqual(preview.representations.count, 2)
    }

    func testLinkUsesRepresentedAddressInsteadOfTitleAndSafariListKeepsAllAddresses() throws {
        let selected = ClipboardPart(representations: [.init(typeIdentifier: "public.url", data: Data("https://example.test/path".utf8)),
            .init(typeIdentifier: "public.utf8-plain-text", data: Data("A page title".utf8))])
        let list = try PropertyListSerialization.data(fromPropertyList: [["https://one.test", "https://two.test"], ["One", "Two"]], format: .binary, options: 0)
        let original = record([selected, part("WebURLsWithTitlesPboardType", list)])
        guard case .text(let first) = try ClipboardPartPreviewPlan.make(original: original, partIndex: 0).content,
              case .text(let second) = try ClipboardPartPreviewPlan.make(original: original, partIndex: 1).content else {
            return XCTFail("Expected represented addresses")
        }
        XCTAssertEqual(first, "https://example.test/path")
        XCTAssertEqual(second, "https://one.test\nhttps://two.test")
    }

    func testUTF16PlainTextUsesDeclaredEncoding() throws {
        let original = record([part("public.utf16-plain-text", Data("中文 🧪".utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })),
                               part("public.utf16-external-plain-text", try XCTUnwrap("Other 中文".data(using: .utf16BigEndian)))])
        guard case .text(let first) = try ClipboardPartPreviewPlan.make(original: original, partIndex: 0).content,
              case .text(let second) = try ClipboardPartPreviewPlan.make(original: original, partIndex: 1).content else {
            return XCTFail("Expected UTF-16 text")
        }
        XCTAssertEqual(first, "中文 🧪")
        XCTAssertEqual(second, "Other 中文")
    }

    func testRepeatedSafariPlistStringsCannotExpandBeyondTextPreviewLimit() throws {
        let address = "https://example.test/" + String(repeating: "x", count: 200_000)
        let data = try PropertyListSerialization.data(fromPropertyList: [Array(repeating: address, count: 10),
            Array(repeating: "Title", count: 10)], format: .binary, options: 0)
        XCTAssertLessThan(data.count, ClipboardPartPreviewPlan.maximumTextBytes)
        let original = record([part("WebURLsWithTitlesPboardType", data)])
        let preview = try ClipboardPartPreviewPlan.make(original: original, partIndex: 0)
        guard case .text(let value) = preview.content else { return XCTFail("Expected bounded represented URL list") }
        XCTAssertLessThanOrEqual(value.utf8.count, ClipboardPartPreviewPlan.maximumTextBytes)
        XCTAssertTrue(preview.isTruncated)
    }

    func testBoundedTextPrefixNeverSplitsAScalarAndDoesNotChangeStoredContent() throws {
        let source = String(repeating: "a", count: ClipboardPartPreviewPlan.maximumTextBytes - 2) + "🧪tail"
        let original = record([textPart(source)])
        let before = original
        let preview = try ClipboardPartPreviewPlan.make(original: original, partIndex: 0)
        guard case .text(let value) = preview.content else { return XCTFail("Expected bounded text prefix") }
        XCTAssertEqual(value, String(repeating: "a", count: ClipboardPartPreviewPlan.maximumTextBytes - 2))
        XCTAssertTrue(preview.isTruncated)
        XCTAssertEqual(original, before)
        XCTAssertFalse(ClipboardPartPreviewPlan.isPotentiallyEditable(original: original, partIndex: 0))
    }

    func testPDFPageLimitFallsBackToSummaryAndRetainsBytes() throws {
        let original = record([part("com.adobe.pdf", try pdf(pages: ClipboardPartPreviewPlan.maximumPDFPageCount + 1))])
        let before = original
        let preview = try ClipboardPartPreviewPlan.make(original: original, partIndex: 0)
        guard case .unavailable = preview.content else { return XCTFail("Expected page-limit fallback") }
        XCTAssertEqual(original, before)
    }

    func testEmptyAndInvalidIndicesNeverInventAggregateContent() throws {
        let original = record([.init(representations: [])])
        let preview = try ClipboardPartPreviewPlan.make(original: original, partIndex: 0)
        guard case .unavailable = preview.content else { return XCTFail("Empty object has no content") }
        XCTAssertTrue(preview.representations.isEmpty)
        for index in [-1, 1, 99] {
            XCTAssertThrowsError(try ClipboardPartPreviewPlan.make(original: original, partIndex: index)) {
                XCTAssertEqual($0 as? ClipboardEditPlanError, .invalidPartIndex)
            }
            XCTAssertFalse(ClipboardPartPreviewPlan.isPotentiallyEditable(original: original, partIndex: index))
        }
    }

    func testUnselectedMalformedObjectsDoNotAffectSelectedPreviewOrEditingAdmission() throws {
        let original = record([part("com.apple.flat-rtfd", Data([0, 255])), textPart("only chosen object"), part("com.adobe.pdf", Data([0]))])
        let preview = try ClipboardPartPreviewPlan.make(original: original, partIndex: 1)
        guard case .text(let value) = preview.content else { return XCTFail("Expected selected text") }
        XCTAssertEqual(value, "only chosen object")
        XCTAssertTrue(ClipboardPartPreviewPlan.isPotentiallyEditable(original: original, partIndex: 1))
        XCTAssertFalse(ClipboardPartPreviewPlan.isPotentiallyEditable(original: original, partIndex: 0))
    }

    func testCancelledWorkerDoesNotDecodeEvenSelectedRepresentation() async throws {
        let original = record([textPart("selected")])
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ClipboardPartPreviewPlan.make(original: original, partIndex: 0)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }
}
