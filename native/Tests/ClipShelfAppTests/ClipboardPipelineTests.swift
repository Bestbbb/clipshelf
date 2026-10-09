import AppKit
import XCTest
import ClipShelfCore
@testable import ClipShelf

final class ClipboardPipelineTests: XCTestCase {
    @MainActor private func board() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("ClipShelf.tests.\(UUID().uuidString)"))
    }

    func testCaptureStartsFromNewChangesAndPreservesUnicode() async throws {
        await MainActor.run {
            let pb = board(); defer { pb.releaseGlobally() }
            pb.setString("before start", forType: .string)
            let capture = CaptureService(pasteboard: pb, sourceProvider: { ("Fixture", "test.fixture") })
            var result: [ClipboardRecord] = []
            capture.onSnapshot = { snapshot in
                do { result.append(try ClipboardCodec.record(from: snapshot)) }
                catch { XCTFail("Complete snapshot must decode: \(error)") }
            }
            capture.start(); defer { capture.stop() }
            capture.poll()
            XCTAssertTrue(result.isEmpty)
            pb.clearContents(); pb.setString("中文\n  code 🧪", forType: .string)
            capture.poll()
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result.first?.text, "中文\n  code 🧪")
            XCTAssertEqual(result.first?.sourceBundleID, "test.fixture")
            capture.poll()
            XCTAssertEqual(result.count, 1)
        }
    }

    func testConfidentialAndExcludedSourcesNeverEmitRecord() async throws {
        await MainActor.run {
            let pb = board(); defer { pb.releaseGlobally() }
            let capture = CaptureService(pasteboard: pb, sourceProvider: { ("Secret Fixture", "test.secret") })
            var count = 0
            capture.onSnapshot = { _ in count += 1 }
            capture.start(); defer { capture.stop() }
            let secret = NSPasteboardItem()
            secret.setString("synthetic secret", forType: .string)
            secret.setString("", forType: .init("org.nspasteboard.ConcealedType"))
            pb.clearContents(); pb.writeObjects([secret]); capture.poll()
            XCTAssertEqual(count, 0)
            capture.excludedBundleIDs = ["test.secret"]
            pb.clearContents(); pb.setString("excluded", forType: .string); capture.poll()
            XCTAssertEqual(count, 0)
            capture.excludedBundleIDs = []
            capture.poll()
            XCTAssertEqual(count, 0, "Unexcluding must not backfill the ignored clipboard")
        }
    }

    func testPauseResumeDoesNotBackfillPausedContent() async throws {
        await MainActor.run {
            let pb = board(); defer { pb.releaseGlobally() }
            let capture = CaptureService(pasteboard: pb, sourceProvider: { ("Fixture", "test.fixture") })
            var result: [ClipboardRecord] = []
            capture.onSnapshot = { snapshot in
                do { result.append(try ClipboardCodec.record(from: snapshot)) }
                catch { XCTFail("Complete snapshot must decode: \(error)") }
            }
            capture.start(); capture.stop()
            pb.clearContents(); pb.setString("during pause", forType: .string); capture.poll()
            capture.start(); defer { capture.stop() }; capture.poll()
            XCTAssertTrue(result.isEmpty)
            pb.clearContents(); pb.setString("after resume", forType: .string); capture.poll()
            XCTAssertEqual(result.map(\.text), ["after resume"])
        }
    }

    @MainActor func testExcludedCopyFollowedByAppSwitchBeforePollIsDiscarded() {
        let pb = board(); defer { pb.releaseGlobally() }
        var source = "test.excluded"
        let capture = CaptureService(pasteboard: pb, sourceProvider: { (source, source) })
        capture.excludedBundleIDs = ["test.excluded"]
        var results: [ClipboardRecord] = []
        capture.onSnapshot = { snapshot in
            do { results.append(try ClipboardCodec.record(from: snapshot)) }
            catch { XCTFail("Complete snapshot must decode: \(error)") }
        }
        capture.start(); defer { capture.stop() }
        pb.clearContents(); pb.setString("excluded synthetic fixture", forType: .string)
        source = "test.allowed"
        // The poll itself also detects a transition if the workspace notification is delayed.
        capture.poll()
        XCTAssertTrue(results.isEmpty)
        pb.clearContents(); pb.setString("new permitted content", forType: .string)
        capture.poll()
        XCTAssertEqual(results.map(\.text), ["new permitted content"])
        capture.noteFrontmostApplication(bundleID: "test.excluded")
        pb.clearContents(); pb.setString("another excluded fixture", forType: .string)
        capture.noteFrontmostApplication(bundleID: "test.allowed")
        capture.poll()
        XCTAssertEqual(results.count, 1, "Leaving and returning between polls must not capture excluded content")
    }

    func testSelfWriteDoesNotBecomeNewHistory() async throws {
        await MainActor.run {
            let pb = board(); defer { pb.releaseGlobally() }
            let capture = CaptureService(pasteboard: pb, sourceProvider: { ("Fixture", "test.fixture") })
            let paste = PasteCoordinator(pasteboard: pb)
            var count = 0
            capture.onSnapshot = { _ in count += 1 }
            capture.start(); defer { capture.stop() }
            XCTAssertTrue(paste.copy(ClipboardRecord(text: "sample")))
            capture.poll()
            XCTAssertEqual(count, 0)
            XCTAssertEqual(pb.string(forType: .string), "sample")
        }
    }

    func testMultipleObjectsAndOpaqueRepresentationsRoundTrip() async throws {
        try await MainActor.run {
            let source = board(); let destination = board()
            defer { source.releaseGlobally(); destination.releaseGlobally() }
            let first = NSPasteboardItem(); first.setString("first", forType: .string)
            first.setData(Data([0, 1, 2, 255]), forType: .init("test.custom-format"))
            let second = NSPasteboardItem(); second.setString("second", forType: .string)
            source.writeObjects([first, second])
            let record = try XCTUnwrap(ClipboardCodec.record(from: source, sourceApp: "Fixture", sourceBundleID: nil))
            XCTAssertEqual(record.parts.count, 2)
            let output = try ClipboardCodec.items(for: [record], plainText: false)
            destination.writeObjects(output)
            XCTAssertEqual(destination.pasteboardItems?.count, 2)
            XCTAssertEqual(destination.pasteboardItems?[0].data(forType: .init("test.custom-format")), Data([0, 1, 2, 255]))
            XCTAssertEqual(destination.pasteboardItems?[1].string(forType: .string), "second")
        }
    }

    func testPlainTextOutputRetainsOriginalRichRecord() async throws {
        await MainActor.run {
            let pb = board(); defer { pb.releaseGlobally() }
            let record = ClipboardRecord(text: "Hello", rtf: Data("rich bytes".utf8), html: Data("<b>Hello</b>".utf8))
            let paste = PasteCoordinator(pasteboard: pb)
            XCTAssertTrue(paste.copy(record, plainText: true))
            XCTAssertEqual(pb.string(forType: .string), "Hello")
            XCTAssertNil(pb.data(forType: .rtf))
            XCTAssertEqual(record.rtf, Data("rich bytes".utf8))
            XCTAssertTrue(paste.copy(record))
            XCTAssertEqual(pb.data(forType: .html), Data("<b>Hello</b>".utf8))
        }
    }

    func testInvalidFileDoesNotReplaceCurrentClipboard() async throws {
        await MainActor.run {
            let pb = board(); defer { pb.releaseGlobally() }
            pb.setString("existing sample", forType: .string)
            let fileURL = URL(fileURLWithPath: "/ClipShelf-nonexistent-\(UUID().uuidString)")
            let record = ClipboardRecord(text: "gone", parts: [ClipboardPart(representations: [
                ClipboardRepresentation(typeIdentifier: NSPasteboard.PasteboardType.fileURL.rawValue, data: Data(fileURL.absoluteString.utf8))
            ])])
            XCTAssertFalse(PasteCoordinator(pasteboard: pb).copy(record))
            XCTAssertEqual(pb.string(forType: .string), "existing sample")
        }
    }

    @MainActor func testPDFIsPreservedAndCannotBeReplacedByItsDisplayTitle() throws {
        let pb = board(); defer { pb.releaseGlobally() }
        let payload = Data("%PDF-synthetic-format-preservation-fixture".utf8)
        for identifier in ["com.adobe.pdf", "public.pdf"] {
            let item = NSPasteboardItem()
            item.setData(payload, forType: .init(identifier))
            let record = try XCTUnwrap(ClipboardCodec.record(from: [item], sourceApp: "Fixture", sourceBundleID: nil))
            XCTAssertEqual(record.text, "扫描文稿（PDF）")
            XCTAssertFalse(ClipboardCodec.supportsPlainText(record))
            pb.clearContents(); pb.setString("existing clipboard", forType: .string)
            XCTAssertFalse(PasteCoordinator(pasteboard: pb).copy(record, plainText: true))
            XCTAssertEqual(pb.string(forType: .string), "existing clipboard")
            let output = try ClipboardCodec.items(for: [record, ClipboardRecord(text: "annotation")], plainText: false)
            XCTAssertEqual(output.count, 2)
            XCTAssertEqual(output[0].data(forType: .init(identifier)), payload)
        }
    }
}
