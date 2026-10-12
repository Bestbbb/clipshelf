import AppKit
import ApplicationServices
import XCTest
@testable import ClipShelf

@MainActor
final class PasteDiagnosticsTests: XCTestCase {
    func testAXSnapshotSharesBudgetAndStopsAfterUnresponsiveRead() {
        var time: TimeInterval = 10
        var calls = 0
        let element = PasteAXSession.application(ProcessInfo.processInfo.processIdentifier)
        let budget = PasteAXSession(pid: 200, clock: { time }, copy: { _, _, _ in
            calls += 1; time += 0.26; return .cannotComplete
        })
        XCTAssertNil(budget.value(element, kAXFocusedWindowAttribute))
        XCTAssertNil(budget.value(element, kAXFocusedUIElementAttribute))
        XCTAssertEqual(calls, 1)
        let expired = PasteAXSession(pid: 200, clock: { time }, copy: { _, _, _ in calls += 1; return .success })
        time += 0.26
        XCTAssertNil(expired.value(element, kAXFocusedWindowAttribute))
        XCTAssertEqual(calls, 1, "No IPC after the shared snapshot budget expires")
    }

    func testOutcomeLogRetainsOnlyLast20MetadataEntriesAndExportMatches() {
        let log = PasteOutcomeLog()
        for i in 0..<25 {
            log.append(.init(timestamp: Date(timeIntervalSince1970: Double(i)), bundleID: "synthetic.editor",
                mode: .compatible, outcome: .cancelled, failure: .clipboardChanged, method: nil, elapsedMS: Double(i)))
        }
        XCTAssertEqual(log.entries.count, 20)
        XCTAssertEqual(log.entries.first?.elapsedMS, 5)
        let snapshot = DiagnosticsSnapshot(hasPermission: true, activeBindings: [.activation: KeyboardShortcutConfiguration.defaults.activation],
            registrationFailures: [], pastePreferences: .init(overrides: ["synthetic.editor": .strict]),
            attempts: log.entries, footprintBytes: 20 * 1_048_576)
        let report = DiagnosticsController.makeReport(snapshot)
        XCTAssertTrue(report.contains("Physical footprint: 20.0 MiB"))
        XCTAssertTrue(report.contains("synthetic.editor: strict"))
        XCTAssertEqual(report.components(separatedBy: "clipboard_changed").count - 1, 20)
        XCTAssertTrue(report.contains("dispatch is not insertion confirmation"))
        for forbidden in ["recordID", "windowTitle", "clipboardText", "fileURL"] { XCTAssertFalse(report.contains(forbidden)) }
    }

    func testKernelFootprintIsAvailableForCurrentProcess() throws {
        XCTAssertGreaterThan(try XCTUnwrap(MemoryFootprint.bytes()), 0)
    }
}
