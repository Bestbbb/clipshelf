import AppKit
import XCTest
import ClipShelfCore
@testable import ClipShelf

final class ClipboardPlainTextProjectionTests: XCTestCase {
    private func part(_ type: String, _ data: Data) -> ClipboardPart {
        ClipboardPart(representations: [.init(typeIdentifier: type, data: data)])
    }

    @MainActor func testURLsUseActualAddressesIncludingSafariLists() throws {
        let url = ClipboardPart(representations: [
            .init(typeIdentifier: "public.utf8-plain-text", data: Data("display title".utf8)),
            .init(typeIdentifier: "public.url", data: Data("https://example.test/actual".utf8)),
        ])
        let list = try PropertyListSerialization.data(fromPropertyList: [
            ["https://example.test/one", "https://example.test/two"], ["First title", "Second title"]
        ], format: .binary, options: 0)
        for type in ["WebURLsWithTitlesPboardType", "dyn.ah62d4rv4gu8zs3pcnzme2641rf4guzdmsv0gn64uqm10c6xenv61a3k"] {
            let record = ClipboardRecord(text: "stale display summary", parts: [url, part(type, list)])
            let output = try ClipboardCodec.items(for: [record], plainText: true)
            XCTAssertEqual(output.count, 1)
            XCTAssertEqual(output[0].string(forType: .string), "https://example.test/actual\nhttps://example.test/one\nhttps://example.test/two")
            XCTAssertEqual(record.text, "stale display summary")
            XCTAssertEqual(record.parts[0], url)
        }
    }

    @MainActor func testUTF16AndRTFOnlyObjectsProjectInOriginalOrder() throws {
        let value = "中文 🧪"
        let rich = NSAttributedString(string: "Rich body", attributes: [.font: NSFont.boldSystemFont(ofSize: 16)])
        let rtf = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let record = ClipboardRecord(text: "unrelated summary", parts: [
            part("public.utf16-plain-text", try XCTUnwrap(value.data(using: .utf16LittleEndian))),
            part("public.utf16-external-plain-text", try XCTUnwrap(value.data(using: .utf16BigEndian))),
            part("public.utf16-external-plain-text", try XCTUnwrap(value.data(using: .utf16))),
            part("public.rtf", rtf)
        ])
        XCTAssertTrue(ClipboardCodec.supportsPlainText(record))
        let output = try ClipboardCodec.items(for: [record, ClipboardRecord(text: "tail")], plainText: true)
        XCTAssertEqual(output[0].string(forType: .string), "\(value)\n\(value)\n\(value)\nRich body\ntail")
        XCTAssertNil(output[0].data(forType: .rtf))
        XCTAssertEqual(record.parts.last?.representations.first?.data, rtf)
    }

    @MainActor func testUnprojectableObjectsRejectWholeBatchWithoutReplacingClipboard() throws {
        let board = NSPasteboard(name: .init("ClipShelf.tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let invalid: [ClipboardPart] = [
            part("test.opaque", Data([1, 2, 3])),
            part("public.html", Data("<b>HTML-only body</b>".utf8)),
            part("public.utf16-plain-text", Data([0x61])),
            part("public.rtf", Data("invalid rich text".utf8)),
            part("public.rtf", Data(#"{\rtf1 text {\pict\pngblip 00}}"#.utf8)),
            part("public.url", Data([0xff])),
        ]
        for unavailable in invalid {
            board.clearContents(); board.setString("existing clipboard", forType: .string)
            let record = ClipboardRecord(text: "must never be pasted", parts: [
                part("public.utf8-plain-text", Data("readable first object".utf8)), unavailable
            ])
            XCTAssertFalse(ClipboardCodec.supportsPlainText(record))
            XCTAssertFalse(PasteCoordinator(pasteboard: board).copy([ClipboardRecord(text: "prefix"), record], plainText: true))
            XCTAssertEqual(board.string(forType: .string), "existing clipboard")
        }
    }

    @MainActor func testExplicitTextProjectionAllowsOpaqueAlternateFormatsAndEmptyText() throws {
        let record = ClipboardRecord(text: "display summary", parts: [ClipboardPart(representations: [
            .init(typeIdentifier: "test.opaque", data: Data([1, 2, 3])),
            .init(typeIdentifier: "public.utf8-plain-text", data: Data())
        ]), part("public.utf8-plain-text", Data("second".utf8))])
        XCTAssertTrue(ClipboardCodec.supportsPlainText(record))
        XCTAssertEqual(try ClipboardCodec.items(for: [record], plainText: true)[0].string(forType: .string), "\nsecond")
        XCTAssertEqual(record.parts[0].representations[0].data, Data([1, 2, 3]))
    }

    @MainActor func testFileImageAndPDFOnlyNeverUseSummaryButPDFTextCanConvert() throws {
        for identifier in ["public.file-url", "public.png", "com.adobe.pdf", "public.pdf"] {
            let record = ClipboardRecord(text: "display name", parts: [part(identifier, Data("synthetic payload".utf8))])
            XCTAssertFalse(ClipboardCodec.supportsPlainText(record))
        }
        let pdf = ClipboardRecord(text: "display name", parts: [ClipboardPart(representations: [
            .init(typeIdentifier: "com.adobe.pdf", data: Data("synthetic PDF".utf8)),
            .init(typeIdentifier: "public.utf8-plain-text", data: Data("actual document text".utf8))
        ])])
        XCTAssertEqual(try ClipboardCodec.items(for: [pdf], plainText: true)[0].string(forType: .string), "actual document text")
    }
}
