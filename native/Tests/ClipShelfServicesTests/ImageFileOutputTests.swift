import AppKit
import ClipShelfCore
import Darwin
import XCTest
@testable import ClipShelf

final class ImageFileOutputTests: XCTestCase {
    /// AppKit's protocol passes its provider to this callback on the chosen queue.
    /// The test transfers it only as that callback argument, never accessing AppKit state there.
    private final class PromiseWriteRequest: @unchecked Sendable {
        let provider: NSFilePromiseProvider
        let delegate: NSFilePromiseProviderDelegate
        @MainActor init(_ provider: NSFilePromiseProvider) { self.provider = provider; delegate = provider.delegate! }
        func write(to url: URL, completion: @escaping (Error?) -> Void) {
            delegate.filePromiseProvider(provider, writePromiseTo: url, completionHandler: completion)
        }
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ClipShelf-ImageOutput-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor private func image(_ width: Int, type: NSBitmapImageRep.FileType = .png) throws -> ClipboardPart {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 3,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
        memset(bitmap.bitmapData!, 128, bitmap.bytesPerRow * bitmap.pixelsHigh)
        return ClipboardPart(representations: [.init(typeIdentifier: type == .tiff ? "public.tiff" : "public.png",
            data: try XCTUnwrap(bitmap.representation(using: type, properties: [:])))])
    }

    private func file(_ url: URL) -> ClipboardPart {
        .init(representations: [.init(typeIdentifier: "public.file-url", data: Data(url.absoluteString.utf8))])
    }

    @MainActor func testBackgroundPreparationExportsEveryImagePartInRecordOrderAndPreservesOtherContent() async throws {
        let root = try directory(), external = root.appendingPathComponent("existing.txt")
        try Data("original file".utf8).write(to: external)
        let text = ClipboardPart(representations: [.init(typeIdentifier: "public.utf8-plain-text", data: Data("原样文本".utf8))])
        var previewFile = file(external)
        previewFile.representations += try image(9).representations
        let original = [ClipboardRecord(text: "first", sourceApp: "Fixture", rtf: Data([1, 2]),
            parts: [try image(4), text, try image(5, type: .tiff)], renamedTitle: "Keep title", revision: 7),
            ClipboardRecord(text: "second", parts: [previewFile, try image(6)])]
        let prepared = try await Task.detached { try ImageFileOutput.prepare(original) }.value
        XCTAssertEqual(prepared.imageCount, 3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["existing.txt"])
        let receipt = try await Task.detached { try prepared.exportReceipt(directory: root.appendingPathComponent("exports")) }.value
        XCTAssertEqual(receipt.records.map(\.id), original.map(\.id))
        XCTAssertEqual(receipt.records[0].revision, 7)
        XCTAssertEqual(receipt.records[0].renamedTitle, "Keep title")
        XCTAssertEqual(receipt.records[0].rtf, original[0].rtf)
        XCTAssertEqual(receipt.records[0].parts[1], text)
        XCTAssertEqual(receipt.records[1].parts[0], previewFile, "A file part's image preview is not a second file")
        XCTAssertEqual(receipt.fileURLs.compactMap { NSImage(contentsOf: $0)?.size.width }, [4, 5, 6])
        for url in receipt.fileURLs {
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber, 0o600)
            XCTAssertEqual(try Data(contentsOf: url).prefix(8), Data([137, 80, 78, 71, 13, 10, 26, 10]))
        }
        XCTAssertEqual(try ClipboardCodec.items(for: receipt.records, plainText: false).count, 5)
        receipt.discardUnpublished()
        XCTAssertTrue(receipt.fileURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(try Data(contentsOf: external), Data("original file".utf8))
        XCTAssertEqual(original[0].parts[0].representations[0].typeIdentifier, "public.png")
    }

    @MainActor func testCorruptLaterImageRejectsWholePreparationAndValidAlternativeRepresentationWorks() throws {
        let invalid = ClipboardPart(representations: [.init(typeIdentifier: "public.png", data: Data("not an image".utf8))])
        XCTAssertThrowsError(try ImageFileOutput.prepare([ClipboardRecord(text: "two", parts: [try image(4), invalid])]))
        var alternate = invalid; alternate.representations += try image(7).representations
        XCTAssertEqual(try ImageFileOutput.prepare([ClipboardRecord(text: "alternate", parts: [alternate])]).imageCount, 1)
        XCTAssertFalse(ImageFileOutput.hasImages(in: [ClipboardRecord(text: "plain")]))
        XCTAssertThrowsError(try ImageFileOutput.prepare([ClipboardRecord(text: "plain")]))
    }

    @MainActor func testUnavailableMixedFileRejectsPrepareAndIsRecheckedBeforeExportOrDrag() throws {
        let root = try directory(), external = root.appendingPathComponent("existing.txt")
        let record = ClipboardRecord(text: "mixed", parts: [try image(4), file(external)])
        XCTAssertThrowsError(try ImageFileOutput.prepare([record]))
        try Data([1]).write(to: external)
        let prepared = try ImageFileOutput.prepare([record])
        try FileManager.default.removeItem(at: external)
        XCTAssertThrowsError(try prepared.draggingWriters())
        let destination = root.appendingPathComponent("exports")
        XCTAssertThrowsError(try prepared.exportReceipt(directory: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor func testLaterFileConflictRollsBackEarlierExportWithoutTouchingExistingFile() throws {
        let root = try directory()
        let prepared = try ImageFileOutput.prepare([ClipboardRecord(text: "two", parts: [try image(4), try image(5)])])
        let providers = try prepared.draggingWriters().compactMap { $0 as? NSFilePromiseProvider }
        let names = providers.map { $0.delegate!.filePromiseProvider($0, fileNameForType: $0.fileType) }
        XCTAssertEqual(Set(names).count, 2)
        let occupied = root.appendingPathComponent(names[1])
        try Data("must survive".utf8).write(to: occupied)
        XCTAssertThrowsError(try prepared.exportReceipt(directory: root))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [names[1]])
        XCTAssertEqual(try Data(contentsOf: occupied), Data("must survive".utf8))
    }

    @MainActor func testDiscardUnpublishedPreservesReplacedRegularFileAndSymlink() throws {
        let root = try directory()
        let prepared = try ImageFileOutput.prepare([ClipboardRecord(text: "three", parts: [try image(4), try image(5), try image(6)])])
        let receipt = try prepared.exportReceipt(directory: root)
        let replacement = root.appendingPathComponent("replacement")
        try Data("external replacement".utf8).write(to: replacement)
        try FileManager.default.removeItem(at: receipt.fileURLs[0])
        try FileManager.default.moveItem(at: replacement, to: receipt.fileURLs[0])
        try FileManager.default.removeItem(at: receipt.fileURLs[1])
        try FileManager.default.createSymbolicLink(at: receipt.fileURLs[1], withDestinationURL: receipt.fileURLs[0])
        receipt.discardUnpublished(); receipt.discardUnpublished()
        XCTAssertEqual(try Data(contentsOf: receipt.fileURLs[0]), Data("external replacement".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: receipt.fileURLs[1].path), receipt.fileURLs[0].path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.fileURLs[2].path))
    }

    @MainActor func testDragWritersKeepAllPartsAndRetainDelegateAfterPreparedValueIsReleased() async throws {
        let root = try directory()
        let text = ClipboardPart(representations: [.init(typeIdentifier: "public.utf8-plain-text", data: Data("middle".utf8))])
        var prepared: PreparedImageFileOutput? = try ImageFileOutput.prepare([ClipboardRecord(text: "three", parts: [try image(4), text, try image(5)])])
        let writers = try prepared!.draggingWriters()
        prepared = nil
        XCTAssertEqual(writers.count, 3)
        XCTAssertEqual((writers[1] as? NSPasteboardItem)?.string(forType: .string), "middle")
        let provider = try XCTUnwrap(writers[2] as? NSFilePromiseProvider)
        XCTAssertNotNil(provider.delegate)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        let destination = root.appendingPathComponent("Receiver chose this name.png")
        let completion = expectation(description: "file promise completed exactly once")
        completion.assertForOverFulfill = true
        let queue = try XCTUnwrap(provider.delegate?.operationQueue?(for: provider))
        let request = PromiseWriteRequest(provider)
        XCTAssertFalse(queue === OperationQueue.main)
        queue.addOperation {
            request.write(to: destination) { error in
                XCTAssertFalse(Thread.isMainThread)
                XCTAssertNil(error); completion.fulfill()
            }
        }
        await fulfillment(of: [completion], timeout: 5)
        XCTAssertEqual(NSImage(contentsOf: destination)?.size.width, 5)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [destination.lastPathComponent])
    }

    @MainActor func testPromiseConflictAndMissingDestinationReportOnceAndNeverOverwrite() async throws {
        let root = try directory(), occupied = root.appendingPathComponent("occupied.png")
        try Data("keep".utf8).write(to: occupied)
        let prepared = try ImageFileOutput.prepare([ClipboardRecord(text: "one", parts: [try image(4)])])
        let provider = try XCTUnwrap(prepared.draggingWriters().first as? NSFilePromiseProvider)
        let queue = try XCTUnwrap(provider.delegate?.operationQueue?(for: provider))
        let request = PromiseWriteRequest(provider)
        for destination in [occupied, root.appendingPathComponent("absent/child.png")] {
            let completion = expectation(description: "one failing callback")
            completion.assertForOverFulfill = true
            queue.addOperation {
                request.write(to: destination) { error in
                    XCTAssertNotNil(error); completion.fulfill()
                }
            }
            await fulfillment(of: [completion], timeout: 5)
        }
        XCTAssertEqual(try Data(contentsOf: occupied), Data("keep".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["occupied.png"])
    }

    @MainActor func testCacheExpiryOnlyRemovesOldRecognizedFilesAndKeepsCurrentBatch() throws {
        let root = try directory()
        let record = ClipboardRecord(text: "one", parts: [try image(4)])
        let old = try ImageFileOutput.prepare([record]).exportReceipt(directory: root)
        let unrelated = root.appendingPathComponent("ClipShelf-personal.png")
        try Data("leave alone".utf8).write(to: unrelated)
        let symlink = root.appendingPathComponent("ClipShelf-\(UUID().uuidString).png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: unrelated)
        let current = try ImageFileOutput.prepare([record]).exportReceipt(directory: root, now: Date().addingTimeInterval(90_000))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.fileURLs[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.fileURLs[0].path))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("leave alone".utf8))
        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path))
    }

    @MainActor func testLegacySingleExportRefusesSilentLossOfAdditionalImagesAndSymlinkCacheRoot() throws {
        let root = try directory(), actual = root.appendingPathComponent("actual"), link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
        let record = ClipboardRecord(text: "two", parts: [try image(4), try image(5)])
        XCTAssertThrowsError(try SystemIntegrationController.exportImage(record, directory: root))
        XCTAssertThrowsError(try ImageFileOutput.prepare([record]).exportReceipt(directory: link))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: actual.path), [])
    }
}
