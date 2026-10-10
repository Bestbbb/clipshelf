import AppKit
import ClipShelfCore
import XCTest
@testable import ClipShelf

@MainActor
final class ClipboardOriginalFormatOutputTests: XCTestCase {
    private enum Injected: Error { case encoding }
    private let browserURLListType = "dyn.ah62d4rv4gu8zs3pcnzme2641rf4guzdmsv0gn64uqm10c6xenv61a3k"

    private func board() -> NSPasteboard {
        NSPasteboard(name: .init("ClipShelf.original-format.\(UUID().uuidString)"))
    }

    private func representation(_ type: NSPasteboard.PasteboardType, _ data: Data) -> ClipboardRepresentation {
        .init(typeIdentifier: type.rawValue, data: data)
    }

    private func textPart(_ text: String, extra: [ClipboardRepresentation] = []) -> ClipboardPart {
        .init(representations: [representation(.string, Data(text.utf8))] + extra)
    }

    private func rich(_ contents: NSAttributedString) throws -> Data {
        try contents.data(from: NSRange(location: 0, length: contents.length),
                          documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    private func originalParts(_ records: [ClipboardRecord]) -> [ClipboardPart] {
        records.flatMap { record in
            if !record.parts.isEmpty { return record.parts }
            var representations = [representation(.string, Data(record.text.utf8))]
            if let rtf = record.rtf { representations.append(representation(.rtf, rtf)) }
            if let html = record.html { representations.append(representation(.html, html)) }
            return [ClipboardPart(representations: representations)]
        }
    }

    private func canonicalType(_ identifier: String) -> String {
        identifier == "WebURLsWithTitlesPboardType" ? browserURLListType : identifier
    }

    private func assertPayloads(_ items: [NSPasteboardItem], equal parts: [ClipboardPart], published: Bool = false,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(items.count, parts.count, file: file, line: line)
        for (item, part) in zip(items, parts) {
            let actual = item.types.filter { $0 != CaptureService.internalType }.map(\.rawValue)
            let expected = part.representations.map(\.typeIdentifier)
            if published {
                // macOS can derive additional UTF-8/UTF-16 representations after publication.
                // Every original type and byte payload must remain; the derived types are allowed.
                XCTAssertTrue(Set(expected.map(canonicalType)).isSubset(of: Set(actual.map(canonicalType))),
                              "Missing original types: \(expected), published: \(actual)", file: file, line: line)
            } else {
                XCTAssertEqual(actual, expected, "The builder must preserve exact declaration order", file: file, line: line)
            }
            for value in part.representations {
                let type = published ? item.types.first { canonicalType($0.rawValue) == canonicalType(value.typeIdentifier) }
                    : NSPasteboard.PasteboardType(value.typeIdentifier)
                XCTAssertEqual(type.flatMap { item.data(forType: $0) }, value.data,
                               value.typeIdentifier, file: file, line: line)
            }
        }
    }

    private func assertOriginalRoundTrip(_ records: [ClipboardRecord],
                                         encode: ((NSAttributedString) throws -> Data)? = nil,
                                         maximumCombinedBytes: Int = ClipboardCodec.maximumOutputBytes,
                                         file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = originalParts(records)
        let output = try ClipboardCodec.items(for: records, plainText: false, encodeCombinedRTF: encode,
                                             maximumCombinedBytes: maximumCombinedBytes)
        assertPayloads(output, equal: expected, file: file, line: line)
        let destination = board(); defer { destination.releaseGlobally() }
        XCTAssertTrue(destination.writeObjects(output), file: file, line: line)
        assertPayloads(try XCTUnwrap(destination.pasteboardItems, file: file, line: line),
                       equal: expected, published: true, file: file, line: line)
    }

    func testOrdinaryTextRecordsStillCombineInSelectionOrderWithEmptyAndUnicodeContent() throws {
        let values = ["  中文 🧪\n", "", "#12ABEF", "  中文 🧪\n"]
        let records = values.enumerated().map { index, value in
            index.isMultiple(of: 2) ? ClipboardRecord(text: value, parts: [textPart(value)]) : ClipboardRecord(text: value)
        }
        let destination = board(); defer { destination.releaseGlobally() }
        XCTAssertTrue(PasteCoordinator(pasteboard: destination).copy(records))
        XCTAssertEqual(destination.pasteboardItems?.count, 1)
        let expected = values.joined(separator: "\n")
        XCTAssertEqual(destination.string(forType: .string), expected)
        let rtf = try XCTUnwrap(destination.data(forType: .rtf))
        XCTAssertEqual(try XCTUnwrap(NSAttributedString(rtf: rtf, documentAttributes: nil)).string, expected)
        XCTAssertEqual(records.map(\.text), values)
    }

    func testNativeRichTextAndPlainTextCombineUsingAuthoritativePartRTFAndPreserveAttributes() throws {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .right; paragraph.firstLineHeadIndent = 12
        let link = try XCTUnwrap(URL(string: "https://example.test/rich"))
        let contents = NSAttributedString(string: "rich body", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.red,
            .paragraphStyle: paragraph, .link: link,
        ])
        let payload = try rich(contents)
        let record = ClipboardRecord(text: contents.string, rtf: Data("stale top-level projection".utf8),
                                     parts: [textPart(contents.string, extra: [representation(.rtf, payload)])])
        let before = record
        let destination = board(); defer { destination.releaseGlobally() }
        XCTAssertTrue(PasteCoordinator(pasteboard: destination).copy([ClipboardRecord(text: "prefix"), record]))
        XCTAssertEqual(destination.pasteboardItems?.count, 1)
        XCTAssertEqual(destination.string(forType: .string), "prefix\nrich body")
        let combinedRTF = try XCTUnwrap(destination.data(forType: .rtf))
        let decoded = try XCTUnwrap(NSAttributedString(rtf: combinedRTF, documentAttributes: nil))
        XCTAssertEqual(decoded.string, "prefix\nrich body")
        let offset = ("prefix\n" as NSString).length
        let font = try XCTUnwrap(decoded.attribute(.font, at: offset, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold)); XCTAssertEqual(font.pointSize, 18)
        XCTAssertEqual((decoded.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)?.redComponent, 1)
        XCTAssertEqual((decoded.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle)?.alignment, .right)
        let decodedLink = decoded.attribute(.link, at: offset, effectiveRange: nil)
        XCTAssertEqual((decodedLink as? URL)?.absoluteString ?? (decodedLink as? String), link.absoluteString)
        XCTAssertEqual(record, before)
    }

    func testRTFOnlyPartAndLegacyRichRecordCombineWhenEveryDecodedBodyMatches() throws {
        let first = try rich(NSAttributedString(string: "first rich", attributes: [.font: NSFont.boldSystemFont(ofSize: 16)]))
        let last = try rich(NSAttributedString(string: "last rich", attributes: [.foregroundColor: NSColor.blue]))
        let records = [ClipboardRecord(text: "first rich", parts: [.init(representations: [representation(.rtf, first)])]),
                       ClipboardRecord(text: "last rich", rtf: last)]
        let destination = board(); defer { destination.releaseGlobally() }
        XCTAssertTrue(destination.writeObjects(try ClipboardCodec.items(for: records, plainText: false)))
        XCTAssertEqual(destination.pasteboardItems?.count, 1)
        let combinedRTF = try XCTUnwrap(destination.data(forType: .rtf))
        let decoded = try XCTUnwrap(NSAttributedString(rtf: combinedRTF, documentAttributes: nil))
        XCTAssertEqual(decoded.string, "first rich\nlast rich")
        XCTAssertTrue((decoded.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    func testUnknownRepresentationKeepsWholeSelectionOriginalThroughCopyCoordinator() throws {
        let opaque = representation(.init("test.vendor.original-binary"), Data([0, 255, 13, 10, 7]))
        let records = [ClipboardRecord(text: "prefix"), ClipboardRecord(text: "middle", parts: [textPart("middle", extra: [opaque])]),
                       ClipboardRecord(text: "suffix")]
        var encodings = 0
        try assertOriginalRoundTrip(records, encode: { _ in encodings += 1; throw Injected.encoding })
        XCTAssertEqual(encodings, 0, "An unsupported selection must not enter the combining encoder")
        let destination = board(); defer { destination.releaseGlobally() }
        XCTAssertTrue(PasteCoordinator(pasteboard: destination).copy(records))
        assertPayloads(try XCTUnwrap(destination.pasteboardItems), equal: originalParts(records), published: true)
    }

    func testHTMLURLUTF16AndBrowserMetadataKeepAllOriginalTypesBytesAndOrder() throws {
        let address = "https://example.test/actual-address"
        let bookmark = try PropertyListSerialization.data(fromPropertyList: [[address], ["Display title"]], format: .binary, options: 0)
        let candidates = [
            ClipboardRecord(text: "body", parts: [textPart("body", extra: [representation(.html, Data("<b>body</b>".utf8))])]),
            ClipboardRecord(text: "Display title", parts: [textPart("Display title", extra: [representation(.URL, Data(address.utf8))])]),
            ClipboardRecord(text: "中文", parts: [.init(representations: [representation(.init("public.utf16-plain-text"), try XCTUnwrap("中文".data(using: .utf16LittleEndian)))])]),
            ClipboardRecord(text: "body", parts: [textPart("body", extra: [representation(.init("org.chromium.source-url"), Data(address.utf8))])]),
            ClipboardRecord(text: "Display title", parts: [.init(representations: [representation(.init(browserURLListType), bookmark)])]),
            ClipboardRecord(text: "legacy html", html: Data("<i>legacy html</i>".utf8)),
        ]
        for candidate in candidates {
            try assertOriginalRoundTrip([ClipboardRecord(text: "before"), candidate, ClipboardRecord(text: "after")])
        }
    }

    func testMultipartRecordIsNeverFoldedEvenWhenEveryPartIsPlainText() throws {
        let multi = ClipboardRecord(text: "first\nsecond", parts: [textPart("first"), textPart("second")])
        try assertOriginalRoundTrip([ClipboardRecord(text: "before"), multi, ClipboardRecord(text: "after")])
    }

    func testUnsupportedLegacyTypeRefusesWholeCopyBeforeReplacingExistingClipboard() throws {
        let unsupported = NSPasteboard.PasteboardType("WebURLsWithTitlesPboardType")
        let payload = try PropertyListSerialization.data(fromPropertyList: [["https://example.test"], ["Title"]], format: .binary, options: 0)
        // This legacy non-UTI spelling is rejected by NSPasteboardItem, unlike its dynamic UTI.
        XCTAssertFalse(NSPasteboardItem().setData(payload, forType: unsupported))
        let record = ClipboardRecord(text: "Title", parts: [textPart("Title", extra: [representation(unsupported, payload)])])
        let records = [ClipboardRecord(text: "valid first item"), record]
        XCTAssertThrowsError(try ClipboardCodec.items(for: records, plainText: false)) { error in
            guard let codecError = error as? ClipboardCodecError, case .noContent = codecError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let destination = board(); defer { destination.releaseGlobally() }
        let previous = NSPasteboardItem()
        let privateType = NSPasteboard.PasteboardType("test.vendor.existing-format")
        let previousPayload = Data([0, 255, 2, 3])
        XCTAssertTrue(previous.setString("existing content", forType: .string))
        XCTAssertTrue(previous.setData(previousPayload, forType: privateType))
        XCTAssertTrue(destination.writeObjects([previous]))
        let changeCount = destination.changeCount
        let coordinator = PasteCoordinator(pasteboard: destination)
        var writes = 0; coordinator.onClipboardWrite = { writes += 1 }
        XCTAssertFalse(coordinator.copy(records))
        XCTAssertEqual(writes, 0); XCTAssertEqual(destination.changeCount, changeCount)
        XCTAssertEqual(destination.pasteboardItems?.count, 1)
        XCTAssertEqual(destination.string(forType: .string), "existing content")
        XCTAssertEqual(destination.data(forType: privateType), previousPayload)
    }

    func testInconsistentSummaryAndRTFOrInvalidUTF8PreserveOriginalPayloads() throws {
        let bodyRTF = try rich(NSAttributedString(string: "actual rich body"))
        let cases = [
            ClipboardRecord(text: "display summary", parts: [textPart("actual body")]),
            ClipboardRecord(text: "actual body", parts: [textPart("actual body", extra: [representation(.rtf, bodyRTF)])]),
            ClipboardRecord(text: "display summary", parts: [.init(representations: [representation(.rtf, bodyRTF)])]),
            ClipboardRecord(text: "display summary", rtf: bodyRTF),
            ClipboardRecord(text: "display summary", parts: [.init(representations: [representation(.string, Data([0xff, 0xfe, 0xff]))])]),
        ]
        for record in cases { try assertOriginalRoundTrip([record, ClipboardRecord(text: "next")]) }
    }

    func testBrokenRTFDoesNotFallBackToSummaryOrDropItsOriginalBytes() throws {
        let invalid = Data("not an RTF document".utf8)
        XCTAssertNil(NSAttributedString(rtf: invalid, documentAttributes: nil))
        let records = [ClipboardRecord(text: "body", rtf: invalid),
                       ClipboardRecord(text: "body", parts: [textPart("body", extra: [representation(.rtf, invalid)])])]
        for record in records { try assertOriginalRoundTrip([record, ClipboardRecord(text: "next")]) }
    }

    func testAttachmentAndBinaryRTFControlWordsRemainOriginalEvenIfTextIsAvailable() throws {
        for source in [#"{\rtf1\ansi body{\pict\pngblip 00}}"#,
                       #"{\rtf1\ansi body{\object\objdata 00}}"#,
                       #"{\rtf1\ansi body\bin1 X}"#] {
            let data = Data(source.utf8)
            let record = ClipboardRecord(text: "body", parts: [textPart("body", extra: [representation(.rtf, data)])])
            try assertOriginalRoundTrip([record, ClipboardRecord(text: "next")])
        }
    }

    func testEscapedRTFControlWordTextCanStillCombine() throws {
        let text = #"literal \pict \object \bin10"#
        let payload = try rich(NSAttributedString(string: text))
        let record = ClipboardRecord(text: text, parts: [textPart(text, extra: [representation(.rtf, payload)])])
        let destination = board(); defer { destination.releaseGlobally() }
        XCTAssertTrue(destination.writeObjects(try ClipboardCodec.items(for: [record, ClipboardRecord(text: "next")], plainText: false)))
        XCTAssertEqual(destination.pasteboardItems?.count, 1)
        XCTAssertEqual(destination.string(forType: .string), text + "\nnext")
    }

    func testRTFEncodingFailureKeepsEntireSelectionOriginalInsteadOfPlainTextDowngrade() throws {
        let first = try rich(NSAttributedString(string: "first", attributes: [.font: NSFont.boldSystemFont(ofSize: 15)]))
        let second = try rich(NSAttributedString(string: "second", attributes: [.foregroundColor: NSColor.green]))
        let records = [ClipboardRecord(text: "first", parts: [textPart("first", extra: [representation(.rtf, first)])]),
                       ClipboardRecord(text: "second", rtf: second), ClipboardRecord(text: "last")]
        var encodings = 0
        try assertOriginalRoundTrip(records, encode: { contents in
            encodings += 1
            XCTAssertEqual(contents.string, "first\nsecond\nlast")
            throw Injected.encoding
        })
        XCTAssertEqual(encodings, 1)
    }

    func testSingleRecordKeepsItsOriginalRTFWithoutEnteringMergeEncoder() throws {
        let payload = try rich(NSAttributedString(string: "single", attributes: [.font: NSFont.boldSystemFont(ofSize: 19)]))
        let record = ClipboardRecord(text: "single", parts: [textPart("single", extra: [representation(.rtf, payload)])])
        var encodings = 0
        try assertOriginalRoundTrip([record], encode: { _ in encodings += 1; throw Injected.encoding })
        XCTAssertEqual(encodings, 0)
    }

    func testCombinedByteLimitCountsUTF8NewlinesAndEncodedRTFGrowthWithoutLargeFixtures() throws {
        let records = [ClipboardRecord(text: "🧪", parts: [textPart("🧪")]), ClipboardRecord(text: "B")]
        let combinedText = "🧪\nB"
        let textBytes = combinedText.utf8.count
        XCTAssertEqual(textBytes, 6)
        var encodings = 0
        try assertOriginalRoundTrip(records, encode: { _ in
            encodings += 1; throw Injected.encoding
        }, maximumCombinedBytes: textBytes - 1)
        XCTAssertEqual(encodings, 0, "UTF-8 plus separator bytes are checked before RTF encoding")

        let payload = try rich(NSAttributedString(string: combinedText))
        let encode: (NSAttributedString) throws -> Data = { contents in
            encodings += 1; XCTAssertEqual(contents.string, combinedText); return payload
        }
        try assertOriginalRoundTrip(records, encode: encode, maximumCombinedBytes: textBytes + payload.count - 1)
        XCTAssertEqual(encodings, 1, "Encoding expansion must keep all original items")

        let destination = board(); defer { destination.releaseGlobally() }
        let output = try ClipboardCodec.items(for: records, plainText: false, encodeCombinedRTF: encode,
                                             maximumCombinedBytes: textBytes + payload.count)
        XCTAssertEqual(encodings, 2); XCTAssertEqual(output.count, 1)
        XCTAssertTrue(destination.writeObjects(output))
        XCTAssertEqual(destination.string(forType: .string), combinedText)
        XCTAssertEqual(destination.data(forType: .rtf), payload)
    }
}
