import AppKit
import ClipShelfCore
import XCTest
@testable import ClipShelf

@MainActor final class CaptureObservationTests: XCTestCase {
    func testTemporaryFailureRetriesSameCountAndEmitsOnlyCompleteSnapshot() {
        let input = CaptureInput()
        let capture = input.service(); capture.start(); defer { capture.stop() }
        var snapshots: [ClipboardCaptureSnapshot] = [], messages: [String] = []
        capture.onSnapshot = { snapshots.append($0) }; capture.onStatus = { messages.append($0) }
        input.copy("text")
        input.parts.append(.init(representations: [.init(typeIdentifier: "test.opaque", data: Data([0, 255, 3]))]))
        input.failure = ClipboardCodecError.temporarilyUnavailable
        capture.poll(); capture.poll()
        XCTAssertTrue(snapshots.isEmpty, "An incomplete multi-representation read cannot emit a partial record")
        XCTAssertTrue(messages.isEmpty)
        input.failure = nil
        capture.poll(); capture.poll()
        XCTAssertEqual(input.reads, 3)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.parts, input.parts)
        XCTAssertEqual(snapshots.first?.byteCount, 7)
        XCTAssertEqual(snapshots.first?.sourceBundleID, "app.a")
        XCTAssertEqual(snapshots.first?.copiedAt, input.copiedAt)
    }

    func testUnavailableCountHasThreeAttemptsOneStatusAndDoesNotBlockLaterCopy() {
        let input = CaptureInput()
        let capture = input.service(); capture.start(); defer { capture.stop() }
        var snapshots: [ClipboardCaptureSnapshot] = [], messages: [String] = []
        capture.onSnapshot = { snapshots.append($0) }; capture.onStatus = { messages.append($0) }
        input.copy("unavailable"); input.failure = ClipboardCodecError.temporarilyUnavailable
        for _ in 0..<8 { capture.poll() }
        XCTAssertEqual(input.reads, 3); XCTAssertEqual(messages.count, 1); XCTAssertTrue(snapshots.isEmpty)
        input.failure = nil; capture.poll()
        XCTAssertEqual(input.reads, 3, "An exhausted count waits for another copy rather than retrying forever")
        input.copy("next"); capture.poll()
        XCTAssertEqual(input.reads, 4); XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.parts, input.parts)
    }

    func testNilSnapshotRetriesSameCountAndPermanentlyEmptyClipboardExpiresQuietly() {
        let input = CaptureInput()
        let capture = input.service(); capture.start(); defer { capture.stop() }
        var captured = 0, messages = 0
        capture.onSnapshot = { _ in captured += 1 }; capture.onStatus = { _ in messages += 1 }
        input.copy("not ready")
        input.noDeclaredTypes = true; input.noSnapshot = true
        capture.poll(); capture.poll()
        XCTAssertEqual(captured, 0); XCTAssertEqual(messages, 0)
        input.noDeclaredTypes = false; input.noSnapshot = false
        capture.poll(); capture.poll()
        XCTAssertEqual(captured, 1); XCTAssertEqual(input.reads, 3)
        input.copy(""); input.noSnapshot = true
        for _ in 0..<8 { capture.poll() }
        XCTAssertEqual(input.reads, 6); XCTAssertEqual(messages, 0)
        input.noSnapshot = false; input.copy("after empty clipboard"); capture.poll()
        XCTAssertEqual(captured, 2)
    }

    func testPermanentFailureReportsOnceAndNewCountGetsFreshRetryBudget() {
        let input = CaptureInput()
        let capture = input.service(); capture.start(); defer { capture.stop() }
        var messages = 0, captured = 0
        capture.onStatus = { _ in messages += 1 }; capture.onSnapshot = { _ in captured += 1 }
        input.copy("too large"); input.failure = ClipboardCodecError.tooLarge
        capture.poll(); capture.poll()
        XCTAssertEqual(input.reads, 1); XCTAssertEqual(messages, 1)
        input.copy("temporary"); input.failure = ClipboardCodecError.temporarilyUnavailable
        capture.poll(); capture.poll()
        input.copy("new temporary")
        capture.poll(); capture.poll()
        XCTAssertEqual(messages, 1, "A different count has its own bounded retry budget")
        input.failure = nil; capture.poll()
        XCTAssertEqual(captured, 1)
    }

    func testStopAndStopStartDuringReadRejectOldSnapshotAndLateError() {
        for restart in [false, true] {
            for failure in [false, true] {
                let input = CaptureInput()
                let capture = input.service(); capture.start(); defer { capture.stop() }
                var captured = 0, messages = 0
                capture.onSnapshot = { _ in captured += 1 }; capture.onStatus = { _ in messages += 1 }
                input.copy("old")
                input.failure = failure ? ClipboardCodecError.tooLarge : nil
                input.onRead = { [weak capture] in
                    capture?.stop()
                    if restart { capture?.start() }
                }
                capture.poll()
                XCTAssertEqual(captured, 0); XCTAssertEqual(messages, 0)
                input.onRead = nil; input.failure = nil
                if !restart { capture.start() }
                capture.poll()
                XCTAssertEqual(captured, 0, "Starting capture cannot backfill the discarded old snapshot")
                input.copy("fresh"); capture.poll()
                XCTAssertEqual(captured, 1)
            }
        }
    }

    func testExclusionPolicyABAInsideReadRejectsPayloadAndDoesNotBackfill() {
        let input = CaptureInput()
        let capture = input.service(); capture.start(); defer { capture.stop() }
        var snapshots: [ClipboardCaptureSnapshot] = []
        capture.onSnapshot = { snapshots.append($0) }
        input.copy("policy changed")
        input.onRead = { [weak capture] in
            capture?.excludedBundleIDs = ["app.a"]
            capture?.excludedBundleIDs = []
        }
        capture.poll()
        XCTAssertTrue(snapshots.isEmpty)
        input.onRead = nil; capture.poll()
        XCTAssertTrue(snapshots.isEmpty)
        input.copy("after policy change"); capture.poll()
        XCTAssertEqual(snapshots.count, 1)
    }

    func testAllowedTransitionRetainsUnobservedCopyWithoutInventingWriter() {
        let input = CaptureInput()
        let capture = input.service(); capture.start(); defer { capture.stop() }
        var snapshots: [ClipboardCaptureSnapshot] = []
        capture.onSnapshot = { snapshots.append($0) }
        input.copy("copied before switch")
        input.source = "app.b"
        capture.poll() // The poll itself detects a delayed workspace notification.
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertNil(snapshots.first?.sourceApp); XCTAssertNil(snapshots.first?.sourceBundleID)
        input.copy("copy in current app"); capture.poll()
        XCTAssertEqual(snapshots.last?.sourceBundleID, "app.b")
    }

    func testAllowedABAWhileReadingInvalidatesReadThenRetriesWithUnknownSource() {
        let input = CaptureInput()
        let capture = input.service(); capture.start(); defer { capture.stop() }
        var snapshots: [ClipboardCaptureSnapshot] = []
        capture.onSnapshot = { snapshots.append($0) }
        input.copy("same clipboard count")
        input.onRead = { [weak capture] in
            input.source = "app.b"; capture?.noteFrontmostApplication(bundleID: input.source)
            input.source = "app.a"; capture?.noteFrontmostApplication(bundleID: input.source)
        }
        capture.poll()
        XCTAssertTrue(snapshots.isEmpty)
        input.onRead = nil; capture.poll()
        XCTAssertEqual(snapshots.count, 1); XCTAssertNil(snapshots.first?.sourceBundleID)
    }

    func testExcludedABAWhileReadingDiscardsSameCountWithoutRetry() {
        let input = CaptureInput()
        let capture = input.service(); capture.excludedBundleIDs = ["app.secret"]
        capture.start(); defer { capture.stop() }
        var captured = 0
        capture.onSnapshot = { _ in captured += 1 }
        input.copy("uncertain private copy")
        input.onRead = { [weak capture] in
            input.source = "app.secret"; capture?.noteFrontmostApplication(bundleID: input.source)
            input.source = "app.a"; capture?.noteFrontmostApplication(bundleID: input.source)
        }
        capture.poll(); input.onRead = nil; capture.poll()
        XCTAssertEqual(input.reads, 1); XCTAssertEqual(captured, 0)
        input.copy("permitted new copy"); capture.poll()
        XCTAssertEqual(captured, 1)
    }

    func testClipboardReplacementDuringReadDoesNotAcknowledgeTheNewCount() {
        let input = CaptureInput()
        let capture = input.service(); capture.start(); defer { capture.stop() }
        var snapshots: [ClipboardCaptureSnapshot] = []
        capture.onSnapshot = { snapshots.append($0) }
        input.copy("first")
        input.onRead = { input.copy("second") }
        capture.poll(); XCTAssertTrue(snapshots.isEmpty)
        input.onRead = nil; capture.poll()
        XCTAssertEqual(snapshots.count, 1); XCTAssertEqual(snapshots.first?.parts, input.parts)
    }

    func testPrivacyAndInternalMarkersSkipPayloadButFollowingExternalCopySurvives() {
        let input = CaptureInput()
        let capture = input.service(); capture.start(); defer { capture.stop() }
        var snapshots: [ClipboardCaptureSnapshot] = []
        capture.onSnapshot = { snapshots.append($0) }
        for marker in ["org.nspasteboard.ConcealedType", CaptureService.internalType.rawValue] {
            input.copy("marked"); input.types.insert(marker); capture.poll()
        }
        XCTAssertEqual(input.reads, 0)
        // An external writer may replace our marked output before any poll.
        input.copy("unobserved self write"); input.types.insert(CaptureService.internalType.rawValue)
        input.copy("external immediately after self write"); capture.poll()
        XCTAssertEqual(snapshots.count, 1); XCTAssertEqual(snapshots.first?.parts, input.parts)
    }

    func testReadCanReenterPollAndDeliveryCanStopWithoutDuplicateEmission() {
        let input = CaptureInput()
        let capture = input.service(); capture.start(); defer { capture.stop() }
        var captured = 0
        input.onRead = { [weak capture] in capture?.poll() }
        capture.onSnapshot = { [weak capture] _ in captured += 1; capture?.poll(); capture?.stop() }
        input.copy("once"); capture.poll()
        XCTAssertEqual(input.reads, 1); XCTAssertEqual(captured, 1); XCTAssertFalse(capture.isRunning)
    }

    func testPrivacyMarkerAppearingDuringReadSuppressesPayloadAndError() {
        for marker in ["org.nspasteboard.ConfidentialType", CaptureService.internalType.rawValue] {
            for failure in [false, true] {
                let input = CaptureInput()
                let capture = input.service(); capture.start(); defer { capture.stop() }
                var captured = 0, messages = 0
                capture.onSnapshot = { _ in captured += 1 }; capture.onStatus = { _ in messages += 1 }
                input.copy("late marker")
                input.failure = failure ? ClipboardCodecError.tooLarge : nil
                input.onRead = { input.types.insert(marker) }
                capture.poll(); capture.poll()
                XCTAssertEqual(captured, 0); XCTAssertEqual(messages, 0); XCTAssertEqual(input.reads, 1)
            }
        }
    }

    func testSourceProviderStoppingObservationPreventsPayloadRead() {
        let input = CaptureInput()
        let capture = input.service(); capture.start(); defer { capture.stop() }
        input.copy("stop in source callback")
        input.onSource = { [weak capture] in capture?.stop() }
        capture.poll()
        XCTAssertEqual(input.reads, 0)
    }
}

@MainActor private final class CaptureInput {
    var count = 0
    var source: String? = "app.a"
    var types: Set<String> = ["public.utf8-plain-text"]
    var parts: [ClipboardPart] = []
    let copiedAt = Date(timeIntervalSince1970: 12_345)
    var reads = 0
    var failure: Error?
    var noDeclaredTypes = false
    var noSnapshot = false
    var onRead: (() -> Void)?
    var onSource: (() -> Void)?

    func copy(_ text: String) {
        count += 1
        types = ["public.utf8-plain-text"]
        parts = [.init(representations: [.init(typeIdentifier: "public.utf8-plain-text", data: Data(text.utf8))])]
    }

    func service() -> CaptureService {
        CaptureService(reader: .init(changeCount: { self.count }, declaredTypes: { self.noDeclaredTypes ? nil : self.types }, snapshot: { name, id in
            self.reads += 1
            let snapshot = ClipboardCaptureSnapshot(parts: self.parts, sourceApp: name, sourceBundleID: id,
                copiedAt: self.copiedAt, byteCount: self.parts.flatMap(\.representations).reduce(0) { $0 + $1.data.count })
            self.onRead?()
            if let failure = self.failure { throw failure }
            return self.noSnapshot ? nil : snapshot
        }), sourceProvider: {
            self.onSource?()
            return (self.source, self.source)
        })
    }
}
