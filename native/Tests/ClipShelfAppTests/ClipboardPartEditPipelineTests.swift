import AppKit
import XCTest
import ClipShelfCore
@testable import ClipShelf

@MainActor
final class ClipboardPartEditPipelineTests: XCTestCase {
    func testMixedClipboardEditPersistsOutputsAndUndoesWithoutChangingOtherObjects() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-part-pipeline-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = NSPasteboard(name: .init("clipshelf-part-source-\(UUID())"))
        let destination = NSPasteboard(name: .init("clipshelf-part-destination-\(UUID())"))
        defer { source.releaseGlobally(); destination.releaseGlobally() }
        let file = directory.appendingPathComponent("fixture.txt")
        try Data("unchanged file contents".utf8).write(to: file)
        let first = NSPasteboardItem()
        first.setString("first object", forType: .string)
        first.setData(Data([0, 7, 255]), forType: .init("test.opaque"))
        let middle = NSPasteboardItem()
        middle.setString("old middle text", forType: .string)
        middle.setData(Data("<b>old middle text</b>".utf8), forType: .html)
        let last = NSPasteboardItem()
        last.setString(file.absoluteString, forType: .fileURL)
        XCTAssertTrue(source.writeObjects([first, middle, last]))
        let captured = try XCTUnwrap(ClipboardCodec.record(from: source, sourceApp: "Fixture", sourceBundleID: "test.fixture"))
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let original = try store.create(captured)
        let snapshot = try store.prepareEdit(.init(id: original.id, revision: original.revision))
        let contents = NSAttributedString(string: "edited middle 中文", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
        let edit = try ClipboardEditPlan.makePartEdit(original: snapshot.record, partIndex: 1, contents: contents)
        let undo = try await ClipboardEditCommitter.commitPartEdit(edit, snapshot: snapshot, store: store,
                                                                 cache: OCRDerivedCache(directory: directory.appendingPathComponent("ocr")))
        let saved = try XCTUnwrap(store.item(id: original.id))
        XCTAssertEqual(saved.revision, original.revision + 1)
        XCTAssertEqual(saved.parts[0], original.parts[0])
        XCTAssertEqual(saved.parts[2], original.parts[2])
        XCTAssertEqual(try store.searchMetadata(.init(text: "edited middle 中文")).map(\.id), [original.id])
        XCTAssertTrue(try store.searchMetadata(.init(text: "old middle text")).isEmpty)
        XCTAssertTrue(destination.writeObjects(try ClipboardCodec.items(for: [saved], plainText: false)))
        let output = try XCTUnwrap(destination.pasteboardItems)
        XCTAssertEqual(output.count, 3)
        XCTAssertEqual(output[0].data(forType: .init("test.opaque")), Data([0, 7, 255]))
        XCTAssertEqual(output[1].string(forType: .string), contents.string)
        XCTAssertNil(output[1].data(forType: .html), "Old HTML cannot override the edited content at the receiver")
        let rich = try XCTUnwrap(NSAttributedString(rtf: XCTUnwrap(output[1].data(forType: .rtf)), documentAttributes: nil))
        XCTAssertEqual(rich.string, contents.string)
        let font = try XCTUnwrap(rich.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        XCTAssertEqual(output[2].string(forType: .fileURL), file.absoluteString)
        _ = try store.undoSelectionEdit(undo)
        let restored = try XCTUnwrap(store.item(id: original.id))
        destination.clearContents()
        XCTAssertTrue(destination.writeObjects(try ClipboardCodec.items(for: [restored], plainText: false)))
        let restoredOutput = try XCTUnwrap(destination.pasteboardItems)
        XCTAssertEqual(restoredOutput.count, original.parts.count)
        for (index, part) in original.parts.enumerated() {
            for representation in part.representations {
                XCTAssertEqual(restoredOutput[index].data(forType: .init(representation.typeIdentifier)), representation.data)
            }
        }
    }
}
