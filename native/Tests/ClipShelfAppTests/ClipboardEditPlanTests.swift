import AppKit
import XCTest
import ClipShelfCore
@testable import ClipShelf

final class ClipboardEditPlanTests: XCTestCase {
    @MainActor private func representation(_ type: NSPasteboard.PasteboardType, _ text: String) -> ClipboardRepresentation {
        ClipboardRepresentation(typeIdentifier: type.rawValue, data: Data(text.utf8))
    }

    @MainActor private func decoded(_ data: Data?) throws -> NSAttributedString {
        let bytes = try XCTUnwrap(data)
        return try XCTUnwrap(NSAttributedString(rtf: bytes, documentAttributes: nil))
    }

    @MainActor private func linkString(_ value: Any?) -> String? {
        if let url = value as? URL { return url.absoluteString }
        return value as? String
    }

    @MainActor func testLinkCanonicalTextURLAndEveryRTFLinkAgreeOnPrivatePasteboard() throws {
        let oldURL = "https://old.example.test/path"
        let oldRich = try ClipboardEditPlan.encodeNativeRTF(NSAttributedString(string: oldURL, attributes: [.link: URL(string: oldURL)!]))
        let list = try PropertyListSerialization.data(fromPropertyList: [[oldURL], ["Old title"]], format: .binary, options: 0)
        let original = ClipboardRecord(text: oldURL, rtf: oldRich, html: Data("<a href='\(oldURL)'>old</a>".utf8), parts: [.init(representations: [
            representation(.string, oldURL), representation(.URL, oldURL),
            .init(typeIdentifier: "public.rtf", data: oldRich), representation(.html, "<a href='\(oldURL)'>old</a>"),
            representation(.init("public.url-name"), "Old title"), representation(.init("org.chromium.source-url"), oldURL),
            .init(typeIdentifier: "WebURLsWithTitlesPboardType", data: list),
        ])])
        let entered = " \nhttps://new.example.test/中文?q=one#fragment \n"
        let draft = NSMutableAttributedString(string: entered, attributes: [.font: NSFont.boldSystemFont(ofSize: 16), .link: URL(string: oldURL)!])
        draft.addAttribute(.link, value: "https://other-old.example.test", range: NSRange(location: 4, length: 5))
        let saved = try ClipboardEditPlan.makeRecord(original: original, contents: draft)
        let canonical = try XCTUnwrap(URL(string: entered.trimmingCharacters(in: .whitespacesAndNewlines))).absoluteString
        XCTAssertEqual(saved.text, canonical)
        XCTAssertNil(saved.html)
        XCTAssertEqual(Set(saved.parts[0].representations.map(\.typeIdentifier)), Set(["public.utf8-plain-text", "public.rtf", "public.url"]))
        let pasteboard = NSPasteboard(name: .init("ClipShelf.edit-plan.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects(try ClipboardCodec.items(for: [saved], plainText: false)))
        XCTAssertEqual(pasteboard.string(forType: .string), canonical)
        XCTAssertEqual(pasteboard.string(forType: .URL), canonical)
        XCTAssertNil(pasteboard.data(forType: .html))
        XCTAssertNil(pasteboard.data(forType: .init("public.url-name")))
        let rich = try decoded(pasteboard.data(forType: .rtf))
        XCTAssertEqual(rich.string, canonical)
        rich.enumerateAttribute(.link, in: NSRange(location: 0, length: rich.length)) { value, _, _ in
            XCTAssertEqual(linkString(value), canonical)
        }
        XCTAssertTrue((rich.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        XCTAssertEqual(draft.string, entered, "The immutable edit plan must not normalize the user's live draft")
        XCTAssertEqual(original.text, oldURL)
    }

    @MainActor func testLinkSchemesAndInvalidDraftValuesUseSameValidationAndSaveRules() throws {
        let original = ClipboardRecord(text: "https://example.test")
        for text in ["http://example.test", "https://example.test/path?x=1", "mailto:hello@example.test", "ftp://example.test/file"] {
            XCTAssertNil(ClipboardEditPlan.validationError(original: original, text: text), text)
            let record = try ClipboardEditPlan.makeRecord(original: original, contents: NSAttributedString(string: text))
            XCTAssertEqual(record.text, text)
            XCTAssertEqual(linkString(try decoded(record.rtf).attribute(.link, at: 0, effectiveRange: nil)), text)
        }
        for text in ["", "example.test", "https://", "ftp:/file", "file:///tmp/test", "javascript:alert(1)", "https://exam ple.test", "https://a.test/\npath", "https://a.test/\u{0}path"] {
            XCTAssertEqual(ClipboardEditPlan.validationError(original: original, text: text) as? ClipboardEditPlanError, .invalidLink, text)
            XCTAssertThrowsError(try ClipboardEditPlan.makeRecord(original: original, contents: NSAttributedString(string: text))) {
                XCTAssertEqual($0 as? ClipboardEditPlanError, .invalidLink)
            }
        }
    }

    @MainActor func testURLRepresentationWithDisplayTitleRemainsALinkWhileSourceURLDoesNot() throws {
        let titled = ClipboardRecord(text: "Example title", parts: [.init(representations: [
            representation(.URL, "https://old.example.test"), representation(.string, "Example title"),
            representation(.init("public.url-name"), "Example title"),
        ])])
        XCTAssertNil(ClipboardEditPlan.editingError(original: titled))
        XCTAssertEqual(ClipboardEditPlan.validationError(original: titled, text: "plain title") as? ClipboardEditPlanError, .invalidLink)
        let link = try ClipboardEditPlan.makeRecord(original: titled, contents: NSAttributedString(string: "https://new.example.test"))
        XCTAssertEqual(link.kind, .link)
        let text = ClipboardRecord(text: "selected browser text", parts: [.init(representations: [
            representation(.string, "selected browser text"), representation(.init("org.chromium.source-url"), "https://source.example.test"),
            representation(.init("NeXT smart paste pasteboard type"), ""),
        ])])
        let saved = try ClipboardEditPlan.makeRecord(original: text, contents: NSAttributedString(string: "edited browser text"))
        XCTAssertEqual(saved.text, "edited browser text")
        XCTAssertFalse(saved.parts[0].representations.contains { $0.typeIdentifier == "public.url" })
    }

    @MainActor func testRichTextPreservesFontsColorsParagraphsAndMixedLinks() throws {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 7
        let contents = NSMutableAttributedString(string: "Bold 中文\nlinked 🧪", attributes: [.font: NSFont.systemFont(ofSize: 15), .paragraphStyle: paragraph])
        contents.addAttributes([.font: NSFont.boldSystemFont(ofSize: 19), .foregroundColor: NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)], range: NSRange(location: 0, length: 4))
        contents.addAttribute(.link, value: URL(string: "https://reference.example.test")!, range: NSRange(location: 8, length: 6))
        let original = ClipboardRecord(text: "Original rich text", rtf: try ClipboardEditPlan.encodeNativeRTF(NSAttributedString(string: "Original rich text")))
        let saved = try ClipboardEditPlan.makeRecord(original: original, contents: contents)
        let rich = try decoded(saved.rtf)
        XCTAssertEqual(saved.text, contents.string)
        XCTAssertEqual(rich.string, contents.string)
        let font = try XCTUnwrap(rich.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 19, accuracy: 0.01)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
        let color = try XCTUnwrap(rich.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(ClipboardEditPlan.hexString(for: color), "#336699")
        XCTAssertEqual((rich.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.lineSpacing, 7)
        XCTAssertEqual(linkString(rich.attribute(.link, at: 8, effectiveRange: nil)), "https://reference.example.test")
        XCTAssertNil(rich.attribute(.link, at: 0, effectiveRange: nil))
    }

    @MainActor func testPlainTextWhitespaceUnicodeAndEmptyDraftArePreserved() throws {
        let original = ClipboardRecord(text: "ordinary text")
        for text in [" \n let x = '%_中文🧪';\n\t", ""] {
            let saved = try ClipboardEditPlan.makeRecord(original: original, contents: NSAttributedString(string: text))
            XCTAssertEqual(saved.text, text)
            XCTAssertEqual(try decoded(saved.rtf).string, text)
        }
    }

    @MainActor func testHTMLOnlyTextConvertsToEditorRTFAndDiscardsStaleHTML() throws {
        let html = Data("<p><b>old</b> <a href='https://old.example.test'>text</a></p>".utf8)
        let original = ClipboardRecord(text: "old text", html: html, parts: [.init(representations: [
            .init(typeIdentifier: "public.html", data: html), representation(.string, "old text"),
        ])])
        let contents = NSAttributedString(string: "new text", attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue])
        let saved = try ClipboardEditPlan.makeRecord(original: original, contents: contents)
        XCTAssertNil(saved.html)
        XCTAssertFalse(saved.parts[0].representations.contains { $0.typeIdentifier == "public.html" })
        XCTAssertEqual(try decoded(saved.rtf).attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(original.html, html)
    }

    @MainActor func testMetadataIdentityAndRevisionArePreservedWhileOCRIsInvalidated() throws {
        let original = ClipboardRecord(text: "old", sourceApp: "Fixture", sourceBundleID: "test.fixture", copiedAt: Date(timeIntervalSinceReferenceDate: 1234), renamedTitle: "My title", ocrText: "old OCR", pinboardID: UUID(), isInHistory: false, revision: 21, pinboardOrder: 900, originDeviceID: UUID(), originDeviceName: "Mac", originDeviceConflict: true)
        let saved = try ClipboardEditPlan.makeRecord(original: original, contents: NSAttributedString(string: "new"))
        var expected = original
        expected.text = saved.text; expected.parts = saved.parts; expected.rtf = saved.rtf; expected.ocrText = nil
        XCTAssertEqual(saved, expected)
    }

    @MainActor func testEncoderFailureHasReadableErrorAndLeavesOriginalUntouched() {
        enum FixtureFailure: Error { case failed }
        let original = ClipboardRecord(text: "original", html: Data("<p>original</p>".utf8), ocrText: "original OCR")
        let before = original
        var calls = 0
        XCTAssertThrowsError(try ClipboardEditPlan.makeRecord(original: original, contents: NSAttributedString(string: "edited"), encodeRTF: { _ in
            calls += 1; throw FixtureFailure.failed
        })) {
            XCTAssertEqual($0 as? ClipboardEditPlanError, .richTextEncodingFailed)
            XCTAssertTrue($0.localizedDescription.contains("草稿已保留"))
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(original, before)
    }

    @MainActor func testMultiObjectAndNonTextRepresentationsAreNotFlattened() {
        let plain = ClipboardPart(representations: [representation(.string, "one")])
        let multiple = ClipboardRecord(text: "one\ntwo", parts: [plain, plain])
        XCTAssertEqual(ClipboardEditPlan.editingError(original: multiple), .multipleObjects)
        for identifier in ["public.file-url", "public.png", "com.adobe.pdf", "com.apple.flat-rtfd", "test.vendor.document", "org.chromium.web-custom-data"] {
            let original = ClipboardRecord(text: "display title", parts: [.init(representations: [
                representation(.string, "display title"), .init(typeIdentifier: identifier, data: Data([1, 2, 3])),
            ])])
            var called = false
            XCTAssertThrowsError(try ClipboardEditPlan.makeRecord(original: original, contents: NSAttributedString(string: "replacement"), encodeRTF: { _ in called = true; return Data() }))
            XCTAssertFalse(called, identifier)
            XCTAssertEqual(ClipboardEditPlan.editingError(original: original), .unsupportedRepresentation(identifier))
        }
    }

    @MainActor func testBrokenOriginalRTFAndDraftAttachmentsAreRejected() {
        let bytes = Data("broken rtf".utf8)
        for original in [ClipboardRecord(text: "text", rtf: bytes), ClipboardRecord(text: "text", parts: [.init(representations: [.init(typeIdentifier: "public.rtf", data: bytes)])])] {
            XCTAssertEqual(ClipboardEditPlan.editingError(original: original), .invalidRichText)
            XCTAssertThrowsError(try ClipboardEditPlan.makeRecord(original: original, contents: NSAttributedString(string: "new")))
        }
        let draft = NSAttributedString(string: "text", attributes: [.attachment: NSTextAttachment()])
        XCTAssertThrowsError(try ClipboardEditPlan.makeRecord(original: ClipboardRecord(text: "text"), contents: draft)) {
            XCTAssertEqual($0 as? ClipboardEditPlanError, .attachments)
        }
        XCTAssertThrowsError(try ClipboardEditPlan.makeRecord(original: ClipboardRecord(text: "text"), contents: NSAttributedString(string: "embedded \u{FFFC}")))
    }

    @MainActor func testBrowserTextArchiveIsAllowedButEmbeddedObjectsAndMultipleBookmarksAreRejected() throws {
        func archive(html: String, resources: [[String: Any]] = []) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: ["WebMainResource": ["WebResourceData": Data(html.utf8), "WebResourceMIMEType": "text/html"], "WebSubresources": resources], format: .binary, options: 0)
        }
        let safe = ClipboardRecord(text: "selected text", parts: [.init(representations: [
            representation(.string, "selected text"), .init(typeIdentifier: "com.apple.webarchive", data: try archive(html: "<b>selected text</b>")),
        ])])
        XCTAssertNil(ClipboardEditPlan.editingError(original: safe))
        XCTAssertNoThrow(try ClipboardEditPlan.makeRecord(original: safe, contents: NSAttributedString(string: "edited")))
        for data in [try archive(html: "<p><img src='https://image.example.test/a.png'></p>"), try archive(html: "text", resources: [["WebResourceMIMEType": "image/png", "WebResourceData": Data([1, 2, 3])]])] {
            let original = ClipboardRecord(text: "text", parts: [.init(representations: [.init(typeIdentifier: "com.apple.webarchive", data: data)])])
            XCTAssertEqual(ClipboardEditPlan.editingError(original: original), .attachments)
        }
        let urls = try PropertyListSerialization.data(fromPropertyList: [["https://one.example.test", "https://two.example.test"], ["one", "two"]], format: .binary, options: 0)
        XCTAssertEqual(ClipboardEditPlan.editingError(original: ClipboardRecord(text: "one", parts: [.init(representations: [.init(typeIdentifier: "WebURLsWithTitlesPboardType", data: urls)])])), .multipleObjects)
        XCTAssertEqual(ClipboardEditPlan.editingError(original: ClipboardRecord(text: "text", html: Data("<OBJECT data='embedded'></OBJECT>".utf8))), .attachments)
    }

    @MainActor func testRGBParserAndCardPreviewShareStrictASCIIGrammarAndRoundTrip() throws {
        for (input, expected) in [("#12aBeF", "#12ABEF"), ("\n 12abef \t", "#12ABEF"), ("000000", "#000000"), ("FFFFFF", "#FFFFFF")] {
            let color = try XCTUnwrap(ClipboardEditPlan.color(from: input))
            XCTAssertEqual(ClipboardEditPlan.hexString(for: color), expected)
            XCTAssertEqual(ClipboardEditPlan.hexString(for: try XCTUnwrap(ClipboardCardView.hexColor(input))), expected)
            XCTAssertEqual(color.alphaComponent, 1)
        }
        for invalid in ["", "#abc", "#11223344", "##112233", "11#2233", "#11 2233", "#11\n2233", "#１２ABEF", "#GG2233", "0x123456", "#12345\u{0}"] {
            XCTAssertNil(ClipboardEditPlan.color(from: invalid), invalid)
            XCTAssertNil(ClipboardCardView.hexColor(invalid), invalid)
        }
    }

    @MainActor func testRGBPickerConversionRejectsAlphaAndNonRGBAndRoundsComponents() throws {
        XCTAssertEqual(ClipboardEditPlan.hexString(for: NSColor(srgbRed: 0.5, green: 1, blue: 0, alpha: 1)), "#80FF00")
        XCTAssertNotNil(ClipboardEditPlan.hexString(for: NSColor(white: 0.5, alpha: 1)), "A convertible grayscale color must be accepted")
        XCTAssertNil(ClipboardEditPlan.hexString(for: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5)))
        XCTAssertNil(ClipboardEditPlan.hexString(for: NSColor(patternImage: NSImage(size: NSSize(width: 1, height: 1)))))
    }

    @MainActor func testColorSaveCanonicalizesEveryRepresentationAndRejectsInvalidDraft() throws {
        let original = ClipboardRecord(text: "#ABCDEF", html: Data("<span style='color:#ABCDEF'>#ABCDEF</span>".utf8))
        let draft = NSAttributedString(string: " \n12abef \t", attributes: [.link: URL(string: "https://stale.example.test")!, .font: NSFont.boldSystemFont(ofSize: 14)])
        let saved = try ClipboardEditPlan.makeRecord(original: original, contents: draft)
        XCTAssertEqual(saved.text, "#12ABEF")
        XCTAssertEqual(saved.kind, .color)
        let rich = try decoded(saved.rtf)
        XCTAssertEqual(rich.string, "#12ABEF")
        XCTAssertNil(rich.attribute(.link, at: 0, effectiveRange: nil))
        XCTAssertNil(saved.html)
        XCTAssertFalse(saved.parts[0].representations.contains { $0.typeIdentifier == "public.url" })
        XCTAssertEqual(ClipboardEditPlan.validationError(original: original, text: "#123") as? ClipboardEditPlanError, .invalidColor)
        XCTAssertThrowsError(try ClipboardEditPlan.makeRecord(original: original, contents: NSAttributedString(string: "#123")))
    }
}
