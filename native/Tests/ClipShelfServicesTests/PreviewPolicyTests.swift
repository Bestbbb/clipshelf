import AppKit
import ClipShelfCore
import XCTest
@testable import ClipShelf

final class PreviewPolicyTests: XCTestCase {
    @MainActor func testBrowserOnlyAcceptsHTTPWithoutCredentials() {
        for value in ["https://example.com/path?q=1", "http://example.com/"] {
            XCTAssertTrue(LinkPreviewController.allows(URL(string: value)))
        }
        for value in ["file:///tmp/example.pdf", "javascript:alert(1)", "data:text/html,hello", "mailto:test@example.com", "clipshelf://record/1", "https://user:password@example.com", "https:/missing-host"] {
            XCTAssertFalse(LinkPreviewController.allows(URL(string: value)), value)
        }
        XCTAssertFalse(LinkPreviewController.allows(nil))
    }

    func testPDFPresentationUsesTypeMetadataWithoutLoadingPayloadsOrChangingKind() {
        for type in ["public.pdf", "com.adobe.pdf", NSPasteboard.PasteboardType.pdf.rawValue] {
            // Deliberately not a valid PDF: list presentation should never parse it.
            let record = ClipboardRecord(text: "复制的内容", parts: [ClipboardPart(representations: [
                ClipboardRepresentation(typeIdentifier: type, data: Data("synthetic opaque bytes".utf8))])])
            let card = ClipboardCardContent(record)
            XCTAssertTrue(card.hasPDF)
            XCTAssertEqual(card.title, "扫描文稿（PDF）")
            XCTAssertEqual(card.preview, "扫描文稿（PDF）")
            XCTAssertEqual(card.kind, record.kind)
            XCTAssertEqual(record.text, "复制的内容")
        }
        XCTAssertFalse(ClipboardCardContent.isPDFType("public.png"))
        XCTAssertFalse(ClipboardCardContent.isPDFType("public.utf8-plain-text"))
    }
}
