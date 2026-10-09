import AppKit
@testable import ClipShelfCore
import XCTest
@testable import ClipShelf

/// All pasteboards are uniquely named; no general clipboard, windows, external
/// applications, network account, or user's history is touched by these tests.
final class OwnedFilePublicationTests: XCTestCase {
    private var directory: URL!
    private let bytes = Data("owned publication regression bytes".utf8)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-publications-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func store() throws -> HistoryStore {
        try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
    }

    private func owned(_ store: HistoryStore, name: String = "original.txt") throws -> ClipboardRecord {
        try store.create(ClipboardRecord(text: name, parts: [ClipboardPart(representations: [
            ClipboardRepresentation(typeIdentifier: "public.file-url", data: Data())
        ])]), ownedFiles: [.init(partIndex: 0, representationIndex: 0, filename: name, data: bytes)],
        expectedSyncConfiguration: store.syncConfiguration(), expectedSharingConfiguration: store.sharingConfiguration())
    }

    private func url(_ record: ClipboardRecord) throws -> URL {
        try XCTUnwrap(ClipboardFileAccess.url(from: XCTUnwrap(record.parts.first?.representations.first?.data)))
    }

    @MainActor private func board() -> NSPasteboard {
        NSPasteboard(name: .init("ClipShelf.publication.tests.\(UUID())"))
    }

    @MainActor func testCopiedFileRemainsPublishedAfterCancelStopAndStoreReopenUntilReplaced() throws {
        let board = board()
        defer { board.releaseGlobally() }
        var originalStore: HistoryStore? = try store()
        let record = try owned(XCTUnwrap(originalStore))
        let file = try url(record)
        var publications: OwnedFilePublicationCoordinator? = OwnedFilePublicationCoordinator(store: try XCTUnwrap(originalStore), pasteboard: board)
        var paste: PasteCoordinator? = PasteCoordinator(pasteboard: board)
        paste?.publications = publications
        XCTAssertTrue(try XCTUnwrap(paste).copy(record))
        let originalID = try XCTUnwrap(originalStore?.ownedPublications(purpose: .clipboard).first?.id)
        XCTAssertEqual(board.string(forType: OwnedFilePublicationCoordinator.pasteboardType), originalID.uuidString)
        try originalStore?.delete(id: record.id)
        paste?.cancel()
        publications?.stopObserving()
        paste = nil; publications = nil; originalStore = nil

        let reopened = try store()
        let observer = OwnedFilePublicationCoordinator(store: reopened, pasteboard: board)
        observer.reconcileClipboard()
        XCTAssertEqual(try reopened.ownedPublications(purpose: .clipboard).map(\.id), [originalID])
        XCTAssertEqual(try reopened.prepareOwnedStorageCleanup().candidateCount, 0)
        XCTAssertEqual(try reopened.commitOwnedStorageCleanup(reopened.prepareOwnedStorageCleanup()).removedAssetCount, 0)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        board.clearContents()
        XCTAssertTrue(board.setString("replacement by another writer", forType: .string))
        observer.reconcileClipboard()
        XCTAssertTrue(try reopened.ownedPublications(purpose: .clipboard).isEmpty)
        XCTAssertEqual(try reopened.commitOwnedStorageCleanup(reopened.prepareOwnedStorageCleanup()).removedAssetCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor func testChangedClipboardWithoutMarkerButWithSameURLStillProtectsFile() throws {
        let store = try store(), record = try owned(store)
        let board = board()
        defer { board.releaseGlobally() }
        let observer = OwnedFilePublicationCoordinator(store: store, pasteboard: board)
        let paste = PasteCoordinator(pasteboard: board); paste.publications = observer
        XCTAssertTrue(paste.copy(record))
        let id = try XCTUnwrap(store.ownedPublications(purpose: .clipboard).first?.id)
        board.clearContents()
        XCTAssertTrue(board.setString(try url(record).absoluteString, forType: .fileURL))
        XCTAssertNil(board.string(forType: OwnedFilePublicationCoordinator.pasteboardType))
        observer.reconcileClipboard()
        XCTAssertEqual(try store.ownedPublications(purpose: .clipboard).map(\.id), [id])
        // An unreadable file representation is insufficient proof of replacement.
        board.clearContents()
        XCTAssertTrue(board.setData(Data([0xFF]), forType: .fileURL))
        observer.reconcileClipboard()
        XCTAssertEqual(try store.ownedPublications(purpose: .clipboard).map(\.id), [id])
    }

    @MainActor func testTokenSurvivesReopenAndProtectsEvenIfReceiverStripsURLRepresentation() throws {
        let store = try store(), record = try owned(store)
        let board = board()
        defer { board.releaseGlobally() }
        let paste = PasteCoordinator(pasteboard: board)
        paste.publications = OwnedFilePublicationCoordinator(store: store, pasteboard: board)
        XCTAssertTrue(paste.copy(record))
        let id = try XCTUnwrap(store.ownedPublications(purpose: .clipboard).first?.id)
        board.clearContents()
        XCTAssertTrue(board.setString(id.uuidString, forType: OwnedFilePublicationCoordinator.pasteboardType))
        let reopened = try self.store()
        OwnedFilePublicationCoordinator(store: reopened, pasteboard: board).reconcileClipboard()
        XCTAssertEqual(try reopened.ownedPublications(purpose: .clipboard).map(\.id), [id])
    }

    @MainActor func testUnsafeOwnedProjectionRejectsBeforeClipboardMutationOrExternalLaunch() throws {
        let store = try store(), record = try owned(store)
        let file = try url(record), target = directory.appendingPathComponent("unrelated.txt")
        try Data("unrelated".utf8).write(to: target)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let board = board()
        defer { board.releaseGlobally() }
        board.clearContents(); XCTAssertTrue(board.setString("previous clipboard", forType: .string))
        let before = board.changeCount
        let publications = OwnedFilePublicationCoordinator(store: store, pasteboard: board)
        let paste = PasteCoordinator(pasteboard: board); paste.publications = publications
        XCTAssertFalse(paste.copy(record))
        XCTAssertEqual(board.changeCount, before)
        XCTAssertEqual(board.string(forType: .string), "previous clipboard")
        let sharing = SystemIntegrationController(); sharing.publications = publications
        XCTAssertThrowsError(try sharing.prepareSharingItems(record))
        var launched = false, failed = false
        let opener = FileApplicationOpener(launcher: { _, _, _ in launched = true }, isApplication: { _ in true })
        opener.publications = publications
        opener.open(file: file, using: .init(url: directory.appendingPathComponent("test.app"), name: "Fixture", isDefault: false, menuTitle: "Fixture")) {
            if case .failure = $0 { failed = true }
        }
        XCTAssertTrue(failed)
        XCTAssertFalse(launched)
        XCTAssertTrue(try store.ownedPublications().isEmpty)
        XCTAssertEqual(try Data(contentsOf: target), Data("unrelated".utf8))
    }

    @MainActor func testShareAndOpenKeepDurableRootsAfterCallbackAndCoordinatorRelease() throws {
        let store = try store(), record = try owned(store)
        let file = try url(record), board = board()
        defer { board.releaseGlobally() }
        var publications: OwnedFilePublicationCoordinator? = OwnedFilePublicationCoordinator(store: store, pasteboard: board)
        var sharing: SystemIntegrationController? = SystemIntegrationController()
        sharing?.publications = publications
        let items = try XCTUnwrap(sharing).prepareSharingItems(record)
        XCTAssertEqual(items as? [URL], [file])
        var delivered: ((Result<Void, Error>) -> Void)?
        var observedBeforeLaunch = false
        var opener: FileApplicationOpener? = FileApplicationOpener(launcher: { launched, _, reply in
            observedBeforeLaunch = (try? store.ownedPublications(purpose: .externalOpen).first?.fileURLs.contains(launched)) == true
            delivered = reply
        }, isApplication: { _ in true })
        opener?.publications = publications
        var returned = false
        opener?.open(file: file, using: .init(url: directory.appendingPathComponent("fixture.app"), name: "Fixture", isDefault: false, menuTitle: "Fixture")) { _ in returned = true }
        XCTAssertTrue(observedBeforeLaunch)
        try store.delete(id: record.id)
        delivered?(.success(()))
        XCTAssertTrue(returned)
        sharing = nil; opener = nil; publications = nil
        let reopened = try self.store()
        XCTAssertEqual(try reopened.ownedPublications(purpose: .sharing).count, 1)
        XCTAssertEqual(try reopened.ownedPublications(purpose: .externalOpen).count, 1)
        XCTAssertEqual(try reopened.prepareOwnedStorageCleanup().candidateCount, 0)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    @MainActor func testMultipartCopyUsesOnePublicationAndInternalMarkerIsNeverRecaptured() throws {
        let store = try store(), first = try owned(store), second = try owned(store, name: "second.txt")
        let board = board()
        defer { board.releaseGlobally() }
        let paste = PasteCoordinator(pasteboard: board)
        paste.publications = OwnedFilePublicationCoordinator(store: store, pasteboard: board)
        XCTAssertTrue(paste.copy([first, second]))
        let publication = try XCTUnwrap(store.ownedPublications(purpose: .clipboard).first)
        XCTAssertEqual(publication.fileURLs.count, 2)
        XCTAssertEqual(board.pasteboardItems?.compactMap { $0.string(forType: OwnedFilePublicationCoordinator.pasteboardType) },
                       [publication.id.uuidString, publication.id.uuidString])
        let recaptured = try XCTUnwrap(ClipboardCodec.record(from: board, sourceApp: nil, sourceBundleID: nil))
        XCTAssertFalse(recaptured.parts.flatMap(\.representations).contains { $0.typeIdentifier == OwnedFilePublicationCoordinator.pasteboardType.rawValue })
    }

    @MainActor func testPublicationStorageFailureAbortsAllExternalOutputBeforeSideEffects() throws {
        let store = try store(), record = try owned(store), file = try url(record)
        try store.execute("CREATE TRIGGER fail_publication BEFORE INSERT ON owned_asset_publications BEGIN SELECT RAISE(ABORT, 'synthetic publication failure'); END")
        let board = board()
        defer { board.releaseGlobally() }
        board.clearContents(); XCTAssertTrue(board.setString("unchanged", forType: .string))
        let before = board.changeCount
        let publications = OwnedFilePublicationCoordinator(store: store, pasteboard: board)
        let paste = PasteCoordinator(pasteboard: board); paste.publications = publications
        XCTAssertFalse(paste.copy(record))
        XCTAssertEqual(board.changeCount, before)
        XCTAssertEqual(board.string(forType: .string), "unchanged")
        let sharing = SystemIntegrationController(); sharing.publications = publications
        XCTAssertThrowsError(try sharing.prepareSharingItems(record))
        var launched = false, failed = false
        let opener = FileApplicationOpener(launcher: { _, _, _ in launched = true }, isApplication: { _ in true })
        opener.publications = publications
        opener.open(file: file, using: .init(url: directory.appendingPathComponent("test.app"), name: "Fixture", isDefault: false, menuTitle: "Fixture")) {
            if case .failure = $0 { failed = true }
        }
        XCTAssertTrue(failed)
        XCTAssertFalse(launched)
        XCTAssertTrue(try store.ownedPublications().isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
}
