import AppKit
import XCTest
import ClipShelfCore
@testable import ClipShelf

@MainActor
final class ClipboardPartEditPlanTests: XCTestCase {
    private func textPart(_ text: String, extra: [ClipboardRepresentation] = []) -> ClipboardPart {
        .init(representations: [.init(typeIdentifier: "public.utf8-plain-text", data: Data(text.utf8))] + extra)
    }

    private func rich(_ text: String) throws -> Data {
        try ClipboardEditPlan.encodeNativeRTF(NSAttributedString(string: text, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.red]))
    }

    func testFirstMiddleAndLastEditsPreserveEveryOtherObjectAndMetadata() throws {
        let original = ClipboardRecord(text: "untrusted aggregate", sourceApp: "Fixture", sourceBundleID: "test.fixture",
            copiedAt: Date(timeIntervalSince1970: 1234),
            parts: [textPart("first"), textPart("middle"), textPart("last")],
            renamedTitle: "Keep name", pinboardID: UUID(), isInHistory: false, revision: 9,
            pinboardOrder: 100, originDeviceID: UUID(), originDeviceName: "Mac")
        XCTAssertEqual(ClipboardEditPlan.editablePartIndices(original: original), [0, 1, 2])
        for index in original.parts.indices {
            let edit = try ClipboardEditPlan.makePartEdit(original: original, partIndex: index,
                                                          contents: NSAttributedString(string: "replacement"))
            let saved = try edit.applying(to: original)
            XCTAssertEqual(saved.parts.count, original.parts.count)
            for other in original.parts.indices where other != index { XCTAssertEqual(saved.parts[other], original.parts[other]) }
            var summaries = ["first", "middle", "last"]; summaries[index] = "replacement"
            XCTAssertEqual(saved.text, summaries.joined(separator: "\n"))
            XCTAssertNil(saved.rtf); XCTAssertNil(saved.html)
            var expected = original
            expected.parts[index] = saved.parts[index]; expected.text = saved.text
            XCTAssertEqual(saved, expected)
        }
    }

    func testIdenticalTextObjectsAreAddressedByIndexAndNotByStringReplacement() throws {
        let original = ClipboardRecord(text: "same\nsame\nsame", parts: Array(repeating: textPart("same"), count: 3))
        let edit = try ClipboardEditPlan.makePartEdit(original: original, partIndex: 1,
                                                      contents: NSAttributedString(string: "only middle"))
        let saved = try edit.applying(to: original)
        XCTAssertEqual(saved.text, "same\nonly middle\nsame")
        XCTAssertEqual(saved.parts[0], original.parts[0]); XCTAssertEqual(saved.parts[2], original.parts[2])
    }

    func testMixedObjectsUseTargetKindAndRetainSearchableSiblingTextAndFilePath() throws {
        let file = URL(fileURLWithPath: "/tmp/synthetic folder/report.txt")
        let original = ClipboardRecord(text: "#AABBCC", parts: [
            textPart("plain text"),
            .init(representations: [.init(typeIdentifier: "public.png", data: Data([0, 1, 255]))]),
            textPart("opaque sibling", extra: [.init(typeIdentifier: "test.vendor.binary", data: Data([4, 5, 6]))]),
            .init(representations: [.init(typeIdentifier: "public.file-url", data: Data(file.absoluteString.utf8))]),
            textPart("Sibling link title", extra: [.init(typeIdentifier: "public.url", data: Data("https://sibling.example.test/path".utf8))]),
        ], ocrText: "image OCR")
        XCTAssertEqual(original.kind, .file)
        XCTAssertEqual(try ClipboardEditPlan.partRecord(original: original, partIndex: 0).kind, .text)
        XCTAssertEqual(ClipboardEditPlan.editablePartIndices(original: original), [0, 4])
        let edit = try ClipboardEditPlan.makePartEdit(original: original, partIndex: 0,
                                                      contents: NSAttributedString(string: "new plain text"))
        let saved = try edit.applying(to: original)
        XCTAssertTrue(saved.text.contains("new plain text"))
        XCTAssertTrue(saved.text.contains("opaque sibling"))
        XCTAssertTrue(saved.text.contains(file.path))
        XCTAssertTrue(saved.text.contains("Sibling link title"))
        XCTAssertTrue(saved.text.contains("https://sibling.example.test/path"))
        XCTAssertEqual(Array(saved.parts.dropFirst()), Array(original.parts.dropFirst()))
        XCTAssertEqual(saved.ocrText, original.ocrText)
    }

    func testURLTitleLoadsActualAddressAndPreservesNativeFontThenUpdatesAllLinkRepresentations() throws {
        let address = "https://old.example.test/actual"
        let original = ClipboardRecord(text: "unrelated aggregate", parts: [textPart("Display title", extra: [
            .init(typeIdentifier: "public.url", data: Data(address.utf8)),
            .init(typeIdentifier: "public.rtf", data: try rich("Display title")),
            .init(typeIdentifier: "public.url-name", data: Data("Display title".utf8)),
        ])])
        let projected = try ClipboardEditPlan.partRecord(original: original, partIndex: 0)
        let contents = try ClipboardEditPlan.partContents(original: original, partIndex: 0)
        XCTAssertEqual(projected.text, address); XCTAssertEqual(contents.string, address)
        XCTAssertEqual((contents.attribute(.link, at: 0, effectiveRange: nil) as? URL)?.absoluteString, address)
        XCTAssertTrue((contents.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        let changed = "https://new.example.test/中文"
        let edit = try ClipboardEditPlan.makePartEdit(original: original, partIndex: 0, contents: NSAttributedString(string: changed))
        let saved = try edit.applying(to: original)
        let canonical = try XCTUnwrap(URL(string: changed)).absoluteString
        XCTAssertEqual(saved.text, canonical)
        XCTAssertEqual(Set(saved.parts[0].representations.map(\.typeIdentifier)), ["public.utf8-plain-text", "public.rtf", "public.url"])
        XCTAssertEqual(saved.parts[0].representations.first { $0.typeIdentifier == "public.url" }?.data, Data(canonical.utf8))
        XCTAssertEqual(saved.rtf, saved.parts[0].representations.first { $0.typeIdentifier == "public.rtf" }?.data)
        // The legacy API uses the same part-specific URL rules.
        XCTAssertThrowsError(try ClipboardEditPlan.makeRecord(original: original, contents: NSAttributedString(string: "new display title")))
    }

    func testSafariBookmarkLoadsTheURLInsteadOfItsTitle() throws {
        let address = "https://bookmark.example.test"
        let bytes = try PropertyListSerialization.data(fromPropertyList: [[address], ["Bookmark title"]], format: .binary, options: 0)
        let original = ClipboardRecord(text: "Bookmark title", parts: [.init(representations: [
            .init(typeIdentifier: "WebURLsWithTitlesPboardType", data: bytes)])])
        XCTAssertEqual(try ClipboardEditPlan.partContents(original: original, partIndex: 0).string, address)
        let saved = try ClipboardEditPlan.makePartEdit(original: original, partIndex: 0,
            contents: NSAttributedString(string: "https://replacement.example.test")).applying(to: original)
        XCTAssertEqual(saved.parts[0].representations.last?.typeIdentifier, "public.url")
        XCTAssertFalse(saved.parts[0].representations.contains { $0.typeIdentifier == "WebURLsWithTitlesPboardType" })
    }

    func testUTF16BOMAndNativeInternalTextAreDecodedWithoutUsingTheRecordSummary() throws {
        let text = "中文 🧪\nsecond line"
        let values: [(String, Data)] = [
            ("public.utf16-plain-text", try XCTUnwrap(text.data(using: .utf16LittleEndian))),
            ("public.utf16-external-plain-text", Data([0xfe, 0xff]) + (try XCTUnwrap(text.data(using: .utf16BigEndian)))),
            ("public.utf16-external-plain-text", try XCTUnwrap(text.data(using: .utf16))),
        ]
        for (type, bytes) in values {
            let original = ClipboardRecord(text: "not the contents", parts: [.init(representations: [.init(typeIdentifier: type, data: bytes)])])
            XCTAssertEqual(ClipboardEditPlan.editablePartIndices(original: original), [0])
            XCTAssertEqual(try ClipboardEditPlan.partContents(original: original, partIndex: 0).string, text)
            let saved = try ClipboardEditPlan.makePartEdit(original: original, partIndex: 0,
                contents: NSAttributedString(string: text + " edited")).applying(to: original)
            XCTAssertEqual(saved.text, text + " edited")
            XCTAssertEqual(saved.parts[0].representations.first?.data, Data(saved.text.utf8))
        }
    }

    func testRichTextOnlyPartLoadsAndRetainsAttributedContentsInMixedRecord() throws {
        let bytes = try rich("rich body")
        let original = ClipboardRecord(text: "image summary", parts: [textPart("sibling"),
            .init(representations: [.init(typeIdentifier: "public.rtf", data: bytes)])])
        let contents = NSMutableAttributedString(attributedString: try ClipboardEditPlan.partContents(original: original, partIndex: 1))
        XCTAssertEqual(contents.string, "rich body")
        contents.replaceCharacters(in: NSRange(location: 0, length: 4), with: "new")
        let saved = try ClipboardEditPlan.makePartEdit(original: original, partIndex: 1, contents: contents).applying(to: original)
        let rtf = try XCTUnwrap(saved.parts[1].representations.first { $0.typeIdentifier == "public.rtf" }?.data)
        let decoded = try XCTUnwrap(NSAttributedString(rtf: rtf, documentAttributes: nil))
        XCTAssertEqual(decoded.string, "new body")
        XCTAssertTrue((decoded.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        XCTAssertEqual(saved.text, "sibling\nnew body")
        XCTAssertEqual(saved.parts[0], original.parts[0]); XCTAssertNil(saved.rtf)
    }

    func testNativeRTFEscapedCodeLiteralsRemainEditableAndRoundTrip() throws {
        let literal = #"code \pict \object \objdata \NeXTGraphic \attachment \bin {braces} \\path"#
        let source = textPart(literal, extra: [.init(typeIdentifier: "public.rtf", data: try rich(literal))])
        for parts in [[source], [source, textPart("unchanged sibling")]] {
            let original = ClipboardRecord(text: literal, parts: parts)
            XCTAssertEqual(ClipboardEditPlan.editablePartIndices(original: original), Array(parts.indices))
            let draft = NSMutableAttributedString(attributedString: try ClipboardEditPlan.partContents(original: original, partIndex: 0))
            XCTAssertEqual(draft.string, literal)
            draft.append(NSAttributedString(string: " edited"))
            let saved = try ClipboardEditPlan.makePartEdit(original: original, partIndex: 0, contents: draft).applying(to: original)
            let reloaded = try ClipboardEditPlan.partContents(original: saved, partIndex: 0)
            XCTAssertEqual(reloaded.string, literal + " edited")
            XCTAssertTrue((reloaded.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
            XCTAssertEqual(Array(saved.parts.dropFirst()), Array(original.parts.dropFirst()))
            if parts.count == 1 {
                XCTAssertEqual(saved.rtf, saved.parts[0].representations.first { $0.typeIdentifier == "public.rtf" }?.data)
            } else { XCTAssertNil(saved.rtf) }
        }
    }

    func testOnlyTargetHTMLAndBrowserMetadataAreRetired() throws {
        let html = ClipboardRepresentation(typeIdentifier: "public.html", data: Data("<b>old text</b>".utf8))
        let source = ClipboardRepresentation(typeIdentifier: "org.chromium.source-url", data: Data("https://source.example.test".utf8))
        let original = ClipboardRecord(text: "old text\nunchanged", parts: [textPart("old text", extra: [html, source]), textPart("unchanged", extra: [html, source])])
        let projected = try ClipboardEditPlan.partRecord(original: original, partIndex: 0)
        XCTAssertNil(projected.rtf); XCTAssertEqual(projected.html, html.data)
        let saved = try ClipboardEditPlan.makePartEdit(original: original, partIndex: 0,
            contents: NSAttributedString(string: "changed")).applying(to: original)
        XCTAssertEqual(Set(saved.parts[0].representations.map(\.typeIdentifier)), ["public.utf8-plain-text", "public.rtf"])
        XCTAssertEqual(saved.parts[1], original.parts[1]); XCTAssertNil(saved.html)
    }

    func testUnsupportedObjectsAndUnreadableTextStayReadOnlyWhileSafeSiblingsRemainEditable() throws {
        let identifiers = ["public.file-url", "public.png", "com.adobe.pdf", "com.apple.flat-rtfd", "test.vendor.document"]
        let unsafe = identifiers.map { textPart("display text", extra: [.init(typeIdentifier: $0, data: Data([1, 2, 3]))]) }
        let malformed = ClipboardPart(representations: [.init(typeIdentifier: "public.rtf", data: Data("not RTF".utf8))])
        let metadataOnly = ClipboardPart(representations: [.init(typeIdentifier: "public.url-name", data: Data("title only".utf8))])
        let htmlOnly = ClipboardPart(representations: [.init(typeIdentifier: "public.html", data: Data("<p>without text representation</p>".utf8))])
        let badUTF16 = ClipboardPart(representations: [.init(typeIdentifier: "public.utf16-plain-text", data: Data([0xff]))])
        let original = ClipboardRecord(text: "irrelevant", parts: [textPart("editable")] + unsafe + [malformed, metadataOnly, htmlOnly, badUTF16])
        XCTAssertEqual(ClipboardEditPlan.editablePartIndices(original: original), [0])
        for index in original.parts.indices where index > 0 {
            XCTAssertThrowsError(try ClipboardEditPlan.partContents(original: original, partIndex: index))
            XCTAssertThrowsError(try ClipboardEditPlan.makePartEdit(original: original, partIndex: index, contents: NSAttributedString(string: "do not flatten")))
        }
    }

    func testInvalidIndexAndLegacyEmptyPartsNeverInventAnEditableObject() {
        for original in [ClipboardRecord(text: "legacy"), ClipboardRecord(text: "one", parts: [textPart("one")])] {
            for index in [-1, original.parts.count, Int.max] {
                XCTAssertThrowsError(try ClipboardEditPlan.partRecord(original: original, partIndex: index)) {
                    XCTAssertEqual($0 as? ClipboardEditPlanError, .invalidPartIndex)
                }
                XCTAssertThrowsError(try ClipboardEditPlan.makePartEdit(original: original, partIndex: index, contents: NSAttributedString(string: "new")))
            }
        }
        XCTAssertEqual(ClipboardEditPlan.editablePartIndices(original: ClipboardRecord(text: "legacy")), [])
        XCTAssertNoThrow(try ClipboardEditPlan.makeRecord(original: ClipboardRecord(text: "legacy"), contents: NSAttributedString(string: "still editable")))
    }

    func testEncoderFailureAndDraftAttachmentDoNotMutateAnyOriginalBytes() throws {
        enum Injected: Error { case encoding }
        let original = ClipboardRecord(text: "first\nsecond", parts: [textPart("first"), textPart("second")])
        let contents = NSMutableAttributedString(string: "typed draft", attributes: [.font: NSFont.boldSystemFont(ofSize: 17)])
        let before = NSAttributedString(attributedString: contents)
        var calls = 0
        XCTAssertThrowsError(try ClipboardEditPlan.makePartEdit(original: original, partIndex: 1, contents: contents, encodeRTF: { _ in
            calls += 1; throw Injected.encoding
        })) { XCTAssertEqual($0 as? ClipboardEditPlanError, .richTextEncodingFailed) }
        XCTAssertEqual(calls, 1); XCTAssertTrue(contents.isEqual(to: before))
        XCTAssertEqual(original.parts, [textPart("first"), textPart("second")])
        contents.addAttribute(.attachment, value: NSTextAttachment(), range: NSRange(location: 0, length: 1))
        XCTAssertThrowsError(try ClipboardEditPlan.makePartEdit(original: original, partIndex: 1, contents: contents)) {
            XCTAssertEqual($0 as? ClipboardEditPlanError, .attachments)
        }
    }

    func testColorPartValidationDoesNotInheritSiblingImageOrAggregateKind() throws {
        let original = ClipboardRecord(text: "mixed", parts: [textPart("#123456"),
            .init(representations: [.init(typeIdentifier: "public.png", data: Data([1, 2, 3]))])])
        XCTAssertEqual(original.kind, .image)
        XCTAssertEqual(try ClipboardEditPlan.partRecord(original: original, partIndex: 0).kind, .color)
        XCTAssertThrowsError(try ClipboardEditPlan.makePartEdit(original: original, partIndex: 0, contents: NSAttributedString(string: "invalid"))) {
            XCTAssertEqual($0 as? ClipboardEditPlanError, .invalidColor)
        }
        let saved = try ClipboardEditPlan.makePartEdit(original: original, partIndex: 0, contents: NSAttributedString(string: "abcdef")).applying(to: original)
        XCTAssertEqual(saved.parts[0].representations.first?.data, Data("#ABCDEF".utf8))
        XCTAssertEqual(saved.parts[1], original.parts[1])
    }

    func testEditedMultipartRecordCombinedWithAnotherRecordOutputsEveryObjectInRTF() throws {
        let original = ClipboardRecord(text: "first\nsecond", parts: [textPart("first", extra: [
            .init(typeIdentifier: "public.rtf", data: try rich("first"))]), textPart("second")])
        let saved = try ClipboardEditPlan.makePartEdit(original: original, partIndex: 1,
            contents: NSAttributedString(string: "changed second")).applying(to: original)
        XCTAssertNil(saved.rtf)
        let objects = try ClipboardCodec.items(for: [saved, ClipboardRecord(text: "another record")], plainText: false)
        XCTAssertEqual(objects.count, 1)
        XCTAssertEqual(objects[0].string(forType: .string), "first\nchanged second\nanother record")
        let data = try XCTUnwrap(objects[0].data(forType: .rtf))
        XCTAssertEqual(try XCTUnwrap(NSAttributedString(rtf: data, documentAttributes: nil)).string, "first\nchanged second\nanother record")
    }
}
