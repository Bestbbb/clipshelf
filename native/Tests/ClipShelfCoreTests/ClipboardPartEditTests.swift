import Foundation
import XCTest
@testable import ClipShelfCore

final class ClipboardPartEditTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("part-edit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func store(_ name: String = "history") throws -> HistoryStore {
        try HistoryStore(databaseURL: directory.appendingPathComponent(name + ".sqlite"))
    }
    private func part(_ text: String, type: String = "public.utf8-plain-text") -> ClipboardPart {
        .init(representations: [.init(typeIdentifier: type, data: Data(text.utf8))])
    }
    private func reference(_ record: ClipboardRecord) -> ClipboardSelectionReference { .init(id: record.id, revision: record.revision) }
    private func edit(_ text: String = "new text", index: Int = 0, summary: String? = nil) -> ClipboardPartEdit {
        .init(partIndex: index, replacement: part(text), text: summary ?? text, rtf: nil, html: nil)
    }

    func testApplyingChangesOnlySelectedPartAndDeclaredProjections() throws {
        let original = ClipboardRecord(text: "old summary", sourceApp: "source", sourceBundleID: "example.source",
            copiedAt: Date(timeIntervalSince1970: 123), parts: [part("image", type: "public.png"), part("old"),
                part("file:///missing/file", type: "public.file-url"), part("opaque", type: "org.example.custom")],
            renamedTitle: "keep", ocrText: "image OCR", pinboardID: UUID(), isInHistory: false,
            revision: 8, pinboardOrder: 4, originDeviceID: UUID(), originDeviceName: "Origin")
        let changed = try edit(index: 1, summary: "image\nnew text\nfile:///missing/file\nopaque").applying(to: original)
        var expected = original
        expected.parts[1] = part("new text"); expected.text = "image\nnew text\nfile:///missing/file\nopaque"
        XCTAssertEqual(changed, expected)
        XCTAssertEqual(changed.ocrText, original.ocrText)
        XCTAssertEqual(changed.parts.count, 4)
    }

    func testRejectsMissingOrOutOfRangeTargetAndUnsafeOriginalOrReplacement() throws {
        for index in [-1, 1] { XCTAssertThrowsError(try edit(index: index).applying(to: ClipboardRecord(text: "old", parts: [part("old")]))) }
        XCTAssertThrowsError(try edit().applying(to: ClipboardRecord(text: "legacy")))
        let unsafe = ["public.file-url", "public.png", "public.tiff", "com.adobe.pdf", "com.apple.flat-rtfd", "org.example.opaque"]
        for type in unsafe {
            let payload = part("synthetic", type: type)
            XCTAssertThrowsError(try edit().applying(to: ClipboardRecord(text: "original", parts: [payload])), type)
            let replacement = ClipboardPartEdit(partIndex: 0, replacement: payload, text: "new", rtf: nil, html: nil)
            XCTAssertThrowsError(try replacement.applying(to: ClipboardRecord(text: "original", parts: [part("old")])) , type)
        }
        XCTAssertThrowsError(try ClipboardPartEdit.validateEditablePart(part("file:///tmp/original", type: "public.url")))
        XCTAssertThrowsError(try ClipboardPartEdit.validateEditablePart(.init(representations: [])))
        XCTAssertThrowsError(try ClipboardPartEdit.validateEditablePart(.init(representations: part("x").representations + part("y").representations)))
    }

    func testTextRichFormatsAndBrowserMetadataStayWithinOneObject() throws {
        let rtf = Data(#"{\rtf1\ansi old}"#.utf8), html = Data("<p>old</p>".utf8)
        let archive = try PropertyListSerialization.data(fromPropertyList: ["WebMainResource": [
            "WebResourceMIMEType": "text/html", "WebResourceData": html]], format: .binary, options: 0)
        let urls = try PropertyListSerialization.data(fromPropertyList: [["https://example.test"], ["Title"]], format: .binary, options: 0)
        let original = ClipboardPart(representations: [
            .init(typeIdentifier: "public.utf16-plain-text", data: try XCTUnwrap("old".data(using: .utf16))),
            .init(typeIdentifier: "public.rtf", data: rtf), .init(typeIdentifier: "public.html", data: html),
            .init(typeIdentifier: "public.url", data: Data("https://example.test".utf8)),
            .init(typeIdentifier: "public.url-name", data: Data("Title".utf8)),
            .init(typeIdentifier: "org.chromium.source-url", data: Data("https://source.test".utf8)),
            .init(typeIdentifier: "NeXT smart paste pasteboard type", data: Data()),
            .init(typeIdentifier: "WebURLsWithTitlesPboardType", data: urls),
            .init(typeIdentifier: "com.apple.webarchive", data: archive),
        ])
        XCTAssertNoThrow(try ClipboardPartEdit.validateEditablePart(original))
        let changed = try edit().applying(to: ClipboardRecord(text: "old", parts: [original]))
        XCTAssertEqual(changed.parts, [part("new text")])
        for rich in [part(#"{\rtf1{\pict 0102}}"#, type: "public.rtf"), part("<p>text<img src='x'></p>", type: "public.html")] {
            XCTAssertThrowsError(try ClipboardPartEdit.validateEditablePart(rich))
        }
        let binaryArchive = try PropertyListSerialization.data(fromPropertyList: [
            "WebMainResource": ["WebResourceMIMEType": "text/html", "WebResourceData": html],
            "WebSubresources": [["WebResourceMIMEType": "image/png", "WebResourceData": Data([1])]]], format: .binary, options: 0)
        XCTAssertThrowsError(try ClipboardPartEdit.validateEditablePart(.init(representations: [.init(typeIdentifier: "com.apple.webarchive", data: binaryArchive)])))
    }

    func testRTFLiteralEscapesDoNotBecomeAttachmentControlWords() throws {
        let sources = [
            #"{\rtf1\ansi \\pict \\object \\objdata \\NeXTGraphic \\attachment \\bin}"#,
            #"{\rtf1\ansi \{\\object\} \\\\pict \'5cpict \'5Cobject \'7battachment\'7d}"#,
            #"{\rtf1\ansi \pictorial ordinary text}"#,
        ]
        for source in sources {
            let original = ClipboardRecord(text: "code", parts: [part(source, type: "public.rtf"), part("sibling")])
            XCTAssertNoThrow(try ClipboardPartEdit.validateEditablePart(original.parts[0]), source)
            let changed = try edit("changed", summary: "changed\nsibling").applying(to: original)
            XCTAssertEqual(changed.parts[1], original.parts[1])
        }
    }

    func testRTFRealAttachmentAndBinaryControlsAreRejectedAfterLiteralEscapes() {
        for word in ["pict", "object", "objdata", "NeXTGraphic", "attachment", "bin", "PICT", "BIN"] {
            for prefix in [#"{\rtf1\ansi "#, #"{\rtf1\ansi \\"#, #"{\rtf1\ansi \{\'5c\} "#] {
                for parameter in ["", "0", "-1"] {
                    let source = prefix + "\\" + word + parameter + " payload}"
                    XCTAssertThrowsError(try ClipboardPartEdit.validateEditablePart(part(source, type: "public.rtf")), source)
                }
            }
        }
        for source in [#"{\rtf1\ansi \'0}"#, #"{\rtf1\ansi \'zz}"#, #"{\rtf1\ansi tail\"#] {
            XCTAssertThrowsError(try ClipboardPartEdit.validateEditablePart(part(source, type: "public.rtf")), source)
        }
    }

    func testRichProjectionIsNilForMultipleObjectsAndExactForSingleObject() throws {
        let rtf = Data(#"{\rtf1\ansi new}"#.utf8), html = Data("<b>new</b>".utf8)
        let replacement = ClipboardPart(representations: part("new").representations + [
            .init(typeIdentifier: "public.rtf", data: rtf), .init(typeIdentifier: "public.html", data: html)])
        let rich = ClipboardPartEdit(partIndex: 0, replacement: replacement, text: "new", rtf: rtf, html: html)
        XCTAssertNoThrow(try rich.applying(to: ClipboardRecord(text: "old", parts: [part("old")])))
        XCTAssertThrowsError(try rich.applying(to: ClipboardRecord(text: "old\nother", parts: [part("old"), part("other")])))
        let multi = ClipboardPartEdit(partIndex: 0, replacement: replacement, text: "new\nother", rtf: nil, html: nil)
        XCTAssertNoThrow(try multi.applying(to: ClipboardRecord(text: "old\nother", parts: [part("old"), part("other")])))
        XCTAssertThrowsError(try multi.applying(to: ClipboardRecord(text: "old", parts: [part("old")])))
    }

    func testCommitPreservesUnselectedOwnedObjectImageOCRAndUndoExactly() throws {
        let store = try store()
        let original = try store.create(ClipboardRecord(text: "owned image old", parts: [
            part("file:///placeholder", type: "public.file-url"), part("synthetic image", type: "public.png"),
            part("old"), part("opaque unchanged", type: "org.example.opaque")], ocrText: "unchanged first-image OCR"),
            ownedFiles: [.init(partIndex: 0, representationIndex: 0, filename: "original.bin", data: Data([1, 2, 3]))],
            expectedSyncConfiguration: store.syncConfiguration(), expectedSharingConfiguration: store.sharingConfiguration())
        let bindings = try store.ownedFileBindings(recordID: original.id)
        let snapshot = try store.prepareEdit(reference(original)), plan = edit(index: 2, summary: "owned image new text")
        let undo = try store.commitPartEdit(plan, snapshot: snapshot)
        var expected = try plan.applying(to: original); expected.revision += 1
        XCTAssertEqual(try store.item(id: original.id), expected)
        XCTAssertEqual(try store.ownedFileBindings(recordID: original.id), bindings)
        XCTAssertEqual(try store.searchMetadata(.init(text: "first-image OCR")).map(\.id), [original.id])
        _ = try store.undoSelectionEdit(undo)
        var restored = original; restored.revision += 2
        XCTAssertEqual(try store.item(id: original.id), restored)
        XCTAssertEqual(try store.ownedFileBindings(recordID: original.id), bindings)
        XCTAssertEqual(try store.ownedFileAssetWithoutLock(id: XCTUnwrap(bindings.first).assetID).byteCount, 3)
    }

    func testPartCommitRejectsStoreRevisionAndBothAccountGenerationChanges() throws {
        for shared in [false, true] {
            let name = shared ? "shared" : "private", store = try store(shared ? "shared" : "private")
            let original = try store.create(ClipboardRecord(text: "old", parts: [part("old")]))
            let snapshot = try store.prepareEdit(reference(original)), peer = try self.store(name)
            XCTAssertThrowsError(try peer.commitPartEdit(edit(), snapshot: snapshot))
            XCTAssertThrowsError(try store.commitPartEdit(edit(), snapshot: .init(record: original)))
            if shared { try store.configureSharing(accountID: "A"); try store.configureSharing(accountID: nil) }
            else { try store.configureSync(accountID: "A"); try store.configureSync(accountID: nil) }
            XCTAssertThrowsError(try store.commitPartEdit(edit(), snapshot: snapshot))
            XCTAssertEqual(try store.item(id: original.id), original)
            let latest = try store.prepareEdit(reference(original))
            var outside = original; outside.text = "outside"
            let updated = try peer.update(record: outside)
            XCTAssertThrowsError(try store.commitPartEdit(edit(), snapshot: latest))
            XCTAssertEqual(try store.item(id: original.id), updated)
        }
    }

    func testPartCommitRechecksSharedReadOnlyAndRevokedAccess() throws {
        for access in [SharedBoardAccess.readOnly, .revoked] {
            let store = try store(String(describing: access)), local = try store.createPinboard(name: "Local")
            _ = try store.create(ClipboardRecord(text: "old", parts: [part("old")], pinboardID: local.id))
            try store.configureSharing(accountID: "A")
            let descriptor = SharedBoardDescriptor(boardID: UUID(), accountID: "A", containerIdentifier: "iCloud.synthetic",
                zoneName: "fixture", zoneOwnerName: "fixture-owner", shareRecordName: "fixture-share")
            let board = try store.createSharedCopy(from: local.id, descriptor: descriptor)
            let record = try XCTUnwrap(store.search(.init(pinboardIDs: [board.id])).first)
            let snapshot = try store.prepareEdit(reference(record))
            try store.updateSharedAccess(boardID: board.id, accountID: "A", access: access)
            XCTAssertThrowsError(try store.commitPartEdit(edit(), snapshot: snapshot))
            XCTAssertEqual(try store.item(id: record.id), record)
        }
    }

    func testQuotaFailureRollsBackPartBlobAndOutboxAndSameSnapshotCanRetry() throws {
        let store = try store()
        try store.configureSync(accountID: "A")
        let original = try store.create(ClipboardRecord(text: "old other", parts: [part("old"), part("other")]))
        let snapshot = try store.prepareEdit(reference(original)), pending = try store.pendingSyncOperations(accountID: "A")
        let before = try store.contentQuotaStatus()
        _ = try store.setContentQuotaLimit(before.usedBytes, expectedRevision: before.policyRevision)
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: store.representations.directory.path))
        let plan = edit(String(repeating: "bigger", count: 100), summary: String(repeating: "bigger", count: 100) + " other")
        XCTAssertThrowsError(try store.commitPartEdit(plan, snapshot: snapshot)) { error in
            guard case ContentQuotaError.exceeded = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try store.item(id: original.id), original)
        XCTAssertEqual(try store.pendingSyncOperations(accountID: "A"), pending)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: store.representations.directory.path)), files)
        let full = try store.contentQuotaStatus()
        XCTAssertEqual(full.usedBytes, before.usedBytes)
        _ = try store.setContentQuotaLimit(nil, expectedRevision: full.policyRevision)
        let undo = try store.commitPartEdit(plan, snapshot: snapshot)
        XCTAssertEqual(try store.item(id: original.id)?.parts[1], original.parts[1])
        _ = try store.undoSelectionEdit(undo)
        var expected = original; expected.revision += 2
        XCTAssertEqual(try store.item(id: original.id), expected)
    }
}
