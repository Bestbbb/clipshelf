import AppKit
import Darwin
import Foundation
import XCTest
import ClipShelfCore
@testable import ClipShelf

final class FileReferenceOutputTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipshelf-file-output-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func writeFile(_ name: String, bytes: Data = Data("synthetic file bytes".utf8)) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func part(_ url: URL) -> ClipboardPart {
        part(Data(url.absoluteString.utf8))
    }

    private func part(_ rawURL: Data) -> ClipboardPart {
        ClipboardPart(representations: [ClipboardRepresentation(typeIdentifier: "public.file-url", data: rawURL)])
    }

    private func record(_ url: URL) -> ClipboardRecord {
        ClipboardRecord(text: url.lastPathComponent, parts: [part(url)])
    }

    private func createOwned(in store: HistoryStore) throws -> ClipboardRecord {
        let candidate = ClipboardRecord(text: "owned.txt", parts: [part(Data())])
        return try store.create(candidate,
                                ownedFiles: [.init(partIndex: 0, representationIndex: 0, filename: "owned.txt",
                                                   data: Data("preserved owned bytes".utf8))],
                                expectedSyncConfiguration: store.syncConfiguration(),
                                expectedSharingConfiguration: store.sharingConfiguration())
    }

    private func url(of record: ClipboardRecord) throws -> URL {
        try XCTUnwrap(ClipboardFileAccess.url(from: XCTUnwrap(record.parts.first?.representations.first?.data)))
    }

    @MainActor private func copyResolved(_ record: ClipboardRecord, from store: HistoryStore,
                                         to pasteboard: NSPasteboard) throws -> Bool {
        let records = try store.resolveSelectionForOutput([.init(id: record.id, revision: record.revision)])
        return PasteCoordinator(pasteboard: pasteboard).copy(records)
    }

    @MainActor private func copyCaptured(_ record: ClipboardRecord, from store: HistoryStore,
                                         to pasteboard: NSPasteboard) throws -> Bool {
        try store.validateCapturedFileOutput([record])
        return PasteCoordinator(pasteboard: pasteboard).copy(record)
    }

    @MainActor private func board() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("ClipShelf.file-reference-tests.\(UUID().uuidString)"))
    }

    @MainActor private func contents(_ pasteboard: NSPasteboard) -> [[String: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type.rawValue, $0) }
            })
        }
    }

    @MainActor private func assertRejected(_ records: [ClipboardRecord], preserving pasteboard: NSPasteboard,
                                           file: StaticString = #filePath, line: UInt = #line) {
        let previous = contents(pasteboard), changeCount = pasteboard.changeCount
        let coordinator = PasteCoordinator(pasteboard: pasteboard)
        var writes = 0, messages: [String] = []
        coordinator.onClipboardWrite = { writes += 1 }
        coordinator.onResult = { messages.append($0) }
        XCTAssertFalse(coordinator.copy(records), file: file, line: line)
        XCTAssertEqual(pasteboard.changeCount, changeCount, file: file, line: line)
        XCTAssertEqual(contents(pasteboard), previous, file: file, line: line)
        XCTAssertEqual(writes, 0, file: file, line: line)
        XCTAssertEqual(messages.count, 1, file: file, line: line)
        XCTAssertThrowsError(try ClipboardCardView.payloadDragItems(for: records), file: file, line: line)
    }

    @MainActor private func assertRejected(_ records: [ClipboardRecord], file: StaticString = #filePath, line: UInt = #line) {
        let pasteboard = board()
        defer { pasteboard.releaseGlobally() }
        let previous = NSPasteboardItem()
        previous.setString("preserve existing clipboard", forType: .string)
        previous.setData(Data([0, 1, 255]), forType: .init("test.existing-format"))
        XCTAssertTrue(pasteboard.writeObjects([previous]), file: file, line: line)
        assertRejected(records, preserving: pasteboard, file: file, line: line)
    }

    @MainActor private func assertResolvedOutputRejected(_ record: ClipboardRecord, from store: HistoryStore,
                                                         file: StaticString = #filePath, line: UInt = #line) {
        let pasteboard = board()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.setString("clipboard before rejected owned output", forType: .string), file: file, line: line)
        let previous = contents(pasteboard), changeCount = pasteboard.changeCount
        XCTAssertThrowsError(try copyResolved(record, from: store, to: pasteboard), file: file, line: line)
        XCTAssertEqual(contents(pasteboard), previous, file: file, line: line)
        XCTAssertEqual(pasteboard.changeCount, changeCount, file: file, line: line)
    }

    @MainActor func testMissingFileRejectsEntireSelectionAndMultipartRecordWithoutChangingClipboard() throws {
        let valid = try writeFile("available.txt")
        let missing = directory.appendingPathComponent("missing.txt")
        assertRejected([record(valid), record(missing)])
        assertRejected([ClipboardRecord(text: "both files", parts: [part(valid), part(missing)])])
    }

    @MainActor func testInvalidUTF8AndNonFileURLRejectMixedOutputWithoutChangingClipboard() throws {
        let valid = try writeFile("valid.txt")
        for invalid in [Data([0xFF, 0xFE]), Data("not a file URL".utf8), Data("https://example.invalid/file.txt".utf8)] {
            let malformed = ClipboardRecord(text: "invalid reference", parts: [part(invalid)])
            assertRejected([record(valid), malformed])
        }
    }

    @MainActor func testRemoteHostCredentialsQueryFragmentAndNULFileURLsAreRejected() throws {
        let valid = try writeFile("existing.txt")
        var remote = try XCTUnwrap(URLComponents(url: valid, resolvingAgainstBaseURL: false))
        remote.host = "remote.invalid"
        var credentials = try XCTUnwrap(URLComponents(url: valid, resolvingAgainstBaseURL: false))
        credentials.user = "someone"
        let variants = [
            try XCTUnwrap(remote.string),
            try XCTUnwrap(credentials.string),
            valid.absoluteString + "?download=1",
            valid.absoluteString + "#fragment",
            valid.absoluteString + "\0ignored",
            valid.absoluteString + "%00ignored",
        ]
        for raw in variants {
            assertRejected([record(valid), ClipboardRecord(text: "invalid location", parts: [part(Data(raw.utf8))])])
        }
    }

    @MainActor func testFIFOIsRejectedWithoutOpeningOrBlockingTheOutputPipeline() throws {
        let valid = try writeFile("valid.txt")
        let fifo = directory.appendingPathComponent("named-pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertEqual(ClipboardFileAccess.availability(of: fifo), .unreadable)
        assertRejected([record(valid), record(fifo)])
    }

    @MainActor func testUnreadableFileRejectsEntireSelectionWithoutChangingClipboard() throws {
        try XCTSkipIf(geteuid() == 0, "Root bypasses ordinary POSIX read permissions; this fixture requires an unprivileged process.")
        let valid = try writeFile("valid.txt")
        let unreadable = try writeFile("unreadable.txt")
        XCTAssertEqual(chmod(unreadable.path, 0), 0)
        defer { _ = chmod(unreadable.path, 0o600) }
        XCTAssertEqual(ClipboardFileAccess.availability(of: unreadable), .unreadable)
        assertRejected([record(valid), record(unreadable)])
    }

    @MainActor func testDirectoryAndFileRemainOrderedFileObjectsForCopyAndDrag() throws {
        let folder = directory.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = try writeFile("following.txt")
        let records = [record(folder), record(file)]
        let pasteboard = board()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(PasteCoordinator(pasteboard: pasteboard).copy(records))
        XCTAssertEqual(pasteboard.pasteboardItems?.map { $0.string(forType: .fileURL) },
                       [folder.absoluteString, file.absoluteString])
        let dragItems = try ClipboardCardView.payloadDragItems(for: records)
        XCTAssertEqual(dragItems.map { $0.string(forType: .fileURL) }, [folder.absoluteString, file.absoluteString])
        XCTAssertTrue(dragItems.allSatisfy { $0.string(forType: .string) == nil })
        XCTAssertEqual(try Data(contentsOf: file), Data("synthetic file bytes".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    @MainActor func testUnicodeAndWhitespaceFileNamesAreNotTrimmedOrReplacedByDisplayText() throws {
        let spaced = try writeFile("  中文 🧪.txt  ")
        let reserved = try writeFile("百分号%与#问号?.txt")
        let rawURLs = ["file://" + spaced.path, spaced.absoluteString, reserved.absoluteString]
        let expectedURLs = [spaced, spaced, reserved]
        let pasteboard = board()
        defer { pasteboard.releaseGlobally() }
        for (raw, expected) in zip(rawURLs, expectedURLs) {
            let stored = ClipboardRecord(text: "display title must not become payload", parts: [part(Data(raw.utf8))])
            XCTAssertEqual(ClipboardFileAccess.url(from: Data(raw.utf8))?.path, expected.path)
            XCTAssertTrue(PasteCoordinator(pasteboard: pasteboard).copy(stored))
            let item = try XCTUnwrap(pasteboard.pasteboardItems?.first)
            XCTAssertEqual(item.data(forType: .fileURL), Data(raw.utf8))
            XCTAssertNil(item.string(forType: .string))
            let output = try XCTUnwrap(ClipboardFileAccess.url(from: XCTUnwrap(item.data(forType: .fileURL))))
            XCTAssertEqual(try Data(contentsOf: output), Data("synthetic file bytes".utf8))
        }
    }

    @MainActor func testExternalRelocationPreservesPartOrderAndUndoRestoresUnavailableReference() throws {
        let missing = directory.appendingPathComponent("missing-original.txt")
        let replacementBytes = Data("selected replacement content".utf8)
        let replacement = try writeFile("replacement.txt", bytes: replacementBytes)
        let secondBytes = Data([0, 10, 255, 42])
        let second = try writeFile("second.bin", bytes: secondBytes)
        let stalePath = ClipboardRepresentation(typeIdentifier: "public.utf8-plain-text", data: Data(missing.path.utf8))
        let opaque = ClipboardRepresentation(typeIdentifier: "test.unrelated-second-format", data: Data([4, 5, 6]))
        let firstPart = ClipboardPart(representations: [stalePath] + part(missing).representations)
        let secondPart = ClipboardPart(representations: part(second).representations + [opaque])
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let original = try store.create(ClipboardRecord(text: "missing-original.txt\nsecond.bin", sourceApp: "Synthetic",
                                                      copiedAt: Date(timeIntervalSince1970: 100), parts: [firstPart, secondPart],
                                                      renamedTitle: "Keep user title"))
        assertRejected([original])
        let snapshot = try store.fileRepairSnapshot(.init(id: original.id, revision: original.revision))
        let missingReference = try XCTUnwrap(snapshot.files.first { $0.partIndex == 0 && $0.representationIndex == 1 })
        XCTAssertEqual(missingReference.status, .missing)
        let undo = try store.relocateExternalFile(snapshot, file: missingReference, to: replacement)
        let repaired = try XCTUnwrap(store.item(id: original.id))
        XCTAssertEqual(repaired.revision, original.revision + 1)
        XCTAssertEqual(repaired.sourceApp, original.sourceApp)
        XCTAssertEqual(repaired.copiedAt, original.copiedAt)
        XCTAssertEqual(repaired.renamedTitle, original.renamedTitle)
        XCTAssertEqual(repaired.parts.count, 2)
        XCTAssertEqual(repaired.parts[1], secondPart)
        XCTAssertEqual(repaired.parts[0].representations.map(\.typeIdentifier), ["public.file-url"],
                       "A stale path fallback must not override the newly selected file in a receiver.")
        XCTAssertTrue(try store.ownedFileBindings(recordID: repaired.id).isEmpty)

        let pasteboard = board()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(PasteCoordinator(pasteboard: pasteboard).copy(repaired))
        XCTAssertEqual(pasteboard.pasteboardItems?.map { $0.string(forType: .fileURL) },
                       [replacement.absoluteString, second.absoluteString])
        let drag = try ClipboardCardView.payloadDragItems(for: [repaired])
        XCTAssertEqual(drag.map { $0.string(forType: .fileURL) }, [replacement.absoluteString, second.absoluteString])
        XCTAssertEqual(drag[1].data(forType: .init(opaque.typeIdentifier)), opaque.data)
        XCTAssertEqual(try Data(contentsOf: replacement), replacementBytes)
        XCTAssertEqual(try Data(contentsOf: second), secondBytes)

        _ = try store.undoSelectionEdit(undo)
        let restored = try XCTUnwrap(store.item(id: original.id))
        XCTAssertEqual(restored.parts, original.parts)
        XCTAssertEqual(restored.text, original.text)
        assertRejected([restored], preserving: pasteboard)
        XCTAssertEqual(try Data(contentsOf: replacement), replacementBytes, "Undo restores the reference, not the user's filesystem.")
        XCTAssertEqual(try Data(contentsOf: second), secondBytes)
        XCTAssertThrowsError(try store.undoSelectionEdit(undo), "The committed revision prevents replaying the same Undo.")
    }

    @MainActor func testOwnedProjectionSymlinkIsRejectedBeforeChangingClipboard() throws {
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let owned = try createOwned(in: store)
        let projection = try url(of: owned)
        let unrelated = try writeFile("unrelated.txt", bytes: Data("must not be sent as owned content".utf8))
        try FileManager.default.removeItem(at: projection)
        try FileManager.default.createSymbolicLink(at: projection, withDestinationURL: unrelated)
        let snapshot = try store.fileRepairSnapshot(.init(id: owned.id, revision: owned.revision))
        XCTAssertEqual(snapshot.files.first?.status, .unsafeProjection)
        assertResolvedOutputRejected(owned, from: store)
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("must not be sent as owned content".utf8))
    }

    @MainActor func testOwnedProjectionHardlinkIsRejectedBeforeChangingClipboard() throws {
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let owned = try createOwned(in: store)
        let projection = try url(of: owned)
        let unrelated = try writeFile("hardlink-target.txt")
        try FileManager.default.removeItem(at: projection)
        try FileManager.default.linkItem(at: unrelated, to: projection)
        let snapshot = try store.fileRepairSnapshot(.init(id: owned.id, revision: owned.revision))
        XCTAssertEqual(snapshot.files.first?.status, .unsafeProjection)
        assertResolvedOutputRejected(owned, from: store)
    }

    @MainActor func testOrdinaryExternalSymlinkRemainsUsableThroughOutputResolution() throws {
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let target = try writeFile("external-target.txt")
        let alias = directory.appendingPathComponent("user-selected-link.txt")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let external = try store.create(record(alias))
        let pasteboard = board()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(try copyResolved(external, from: store, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .fileURL), alias.absoluteString)
        let resolved = try store.resolveSelectionForOutput([.init(id: external.id, revision: external.revision)])
        XCTAssertEqual(try ClipboardCardView.payloadDragItems(for: resolved).first?.string(forType: .fileURL), alias.absoluteString)
        XCTAssertEqual(try Data(contentsOf: alias), Data("synthetic file bytes".utf8))
        XCTAssertTrue(try store.ownedFileBindings(recordID: external.id).isEmpty)
    }

    @MainActor func testNormalOwnedProjectionCanBeCopiedAndDraggedThroughOutputResolution() throws {
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let owned = try createOwned(in: store)
        let pasteboard = board()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(try copyResolved(owned, from: store, to: pasteboard))
        let projection = try url(of: owned)
        XCTAssertEqual(pasteboard.string(forType: .fileURL), projection.absoluteString)
        let resolved = try store.resolveSelectionForOutput([.init(id: owned.id, revision: owned.revision)])
        XCTAssertEqual(try ClipboardCardView.payloadDragItems(for: resolved).first?.string(forType: .fileURL), projection.absoluteString)
        XCTAssertEqual(try Data(contentsOf: projection), Data("preserved owned bytes".utf8))
    }

    @MainActor func testCapturedExternalOccurrenceSurvivesHistoryCoalescingAndDeletion() throws {
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let target = try writeFile("captured-external.txt")
        let alias = directory.appendingPathComponent("captured-link.txt")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let captured = try store.record(record(alias))
        let coalesced = try store.record(record(alias))
        XCTAssertEqual(coalesced.id, captured.id)
        XCTAssertEqual(coalesced.revision, captured.revision + 1)
        XCTAssertThrowsError(try store.resolveSelectionForOutput([.init(id: captured.id, revision: captured.revision)]),
                             "History selection is strict, but a captured Stack occurrence is independent.")
        let pasteboard = board()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(try copyCaptured(captured, from: store, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .fileURL), alias.absoluteString)
        try store.delete(id: captured.id)
        XCTAssertNil(try store.item(id: captured.id))
        XCTAssertTrue(try copyCaptured(captured, from: store, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .fileURL), alias.absoluteString)
        XCTAssertEqual(try Data(contentsOf: alias), Data("synthetic file bytes".utf8))
    }

    @MainActor func testCapturedOwnedOccurrenceRetainsSafetyChecksAfterItsHistoryRowIsDeleted() throws {
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let captured = try createOwned(in: store)
        let coalesced = try store.record(captured)
        XCTAssertEqual(coalesced.id, captured.id)
        XCTAssertEqual(coalesced.revision, captured.revision + 1)
        let pasteboard = board()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(try copyCaptured(captured, from: store, to: pasteboard))
        try store.delete(id: captured.id)
        XCTAssertTrue(try copyCaptured(captured, from: store, to: pasteboard))
        let projection = try url(of: captured)
        let unrelated = try writeFile("not-the-captured-file.txt")
        for hardlink in [false, true] {
            try FileManager.default.removeItem(at: projection)
            if hardlink { try FileManager.default.linkItem(at: unrelated, to: projection) }
            else { try FileManager.default.createSymbolicLink(at: projection, withDestinationURL: unrelated) }
            let previous = contents(pasteboard), changeCount = pasteboard.changeCount
            XCTAssertThrowsError(try copyCaptured(captured, from: store, to: pasteboard))
            XCTAssertEqual(contents(pasteboard), previous)
            XCTAssertEqual(pasteboard.changeCount, changeCount)
        }
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("synthetic file bytes".utf8))
    }
}
