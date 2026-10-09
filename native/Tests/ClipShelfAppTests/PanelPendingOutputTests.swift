import AppKit
import XCTest
@testable import ClipShelf
@testable import ClipShelfCore

@MainActor private final class PendingOutputHarness {
    let panel = ClipboardPanelController()
    let records = (0..<3).map { ClipboardRecord(text: "Synthetic deferred item \($0)") }
    var replies: [([ClipboardSelectionReference], (Result<[ClipboardRecord], Error>) -> Void)] = []
    var pasted: [UUID] = []
    var copied: [UUID] = []

    init() {
        let window = UnshownTestPanel(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 430),
                                     styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = panel.window?.contentView; window.delegate = panel; panel.window = window
        panel.resolveOutputSelection = { [weak self] refs, completion in self?.replies.append((refs, completion)) }
        panel.onPaste = { [weak self] record, _ in self?.pasted.append(record.id) }
        panel.onCopy = { [weak self] record in self?.copied.append(record.id) }
        panel.show(records: records)
        key(36, "\r") // Enter the result list without starting an output.
    }

    @discardableResult func key(_ code: UInt16, _ characters: String = "", flags: NSEvent.ModifierFlags = [], repeated: Bool = false) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1,
            windowNumber: panel.window!.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: repeated, keyCode: code)!
        return panel.handleKey(event)
    }

    func complete(_ index: Int) throws {
        let (refs, reply) = replies[index]
        let values = try refs.map { ref in try XCTUnwrap(records.first { $0.id == ref.id }) }
        reply(.success(values))
    }

    func searchField() throws -> NSSearchField {
        func find(_ view: NSView) -> NSSearchField? {
            (view as? NSSearchField) ?? view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(panel.window?.contentView.flatMap(find))
    }

    func close() { panel.dismiss() }
}

final class PanelPendingOutputTests: XCTestCase {
    @MainActor func testSearchFocusCancelsDeferredPasteWithoutChangingSelectionOrQuery() throws {
        let h = PendingOutputHarness(); defer { h.close() }
        XCTAssertTrue(h.key(36, "\r")); XCTAssertEqual(h.replies.count, 1)
        XCTAssertTrue(h.key(3, "f", flags: .command))
        XCTAssertEqual(try h.searchField().stringValue, "")
        try h.complete(0)
        XCTAssertTrue(h.pasted.isEmpty)
        // Returning to the list is a new explicit request, not a permanent lockout.
        h.key(36, "\r"); h.key(36, "\r")
        XCTAssertEqual(h.replies.count, 2)
        try h.complete(1)
        XCTAssertEqual(h.pasted.count, 1)
    }

    @MainActor func testNativeSearchEditingCancelsDeferredCopyBeforeTextChanges() throws {
        let h = PendingOutputHarness(); defer { h.close() }
        h.key(8, "c", flags: .command); XCTAssertEqual(h.replies.count, 1)
        let search = try h.searchField()
        h.panel.window?.makeFirstResponder(search)
        h.panel.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: search))
        try h.complete(0)
        XCTAssertTrue(h.copied.isEmpty)
        XCTAssertTrue(h.pasted.isEmpty)
    }

    @MainActor func testHeldReturnAndQuickPasteKeepOriginalPendingRequestAndDispatchOnlyOnce() throws {
        for (code, characters, flags) in [(UInt16(36), "\r", NSEvent.ModifierFlags()), (18, "1", .command)] {
            let h = PendingOutputHarness(); defer { h.close() }
            XCTAssertTrue(h.key(code, characters, flags: flags))
            XCTAssertEqual(h.replies.count, 1)
            for _ in 0..<5 { XCTAssertTrue(h.key(code, characters, flags: flags, repeated: true)) }
            h.panel.handleModifierFlags([]) // Releasing the shortcut modifiers is not a new intent.
            XCTAssertEqual(h.replies.count, 1)
            try h.complete(0); try h.complete(0)
            XCTAssertEqual(h.pasted.count, 1)
        }
    }

    @MainActor func testLatestExplicitOutputWinsAndOlderReplyCannotReplaceIt() throws {
        let h = PendingOutputHarness(); defer { h.close() }
        h.key(36, "\r"); h.key(19, "2", flags: .command)
        XCTAssertEqual(h.replies.count, 2)
        let latestID = try XCTUnwrap(h.replies[1].0.first?.id)
        try h.complete(0)
        XCTAssertTrue(h.pasted.isEmpty)
        try h.complete(1)
        XCTAssertEqual(h.pasted, [latestID])
    }

    @MainActor func testHiddenAndReopenedPanelRejectsOldPayloadEvenWithSameRecords() throws {
        let h = PendingOutputHarness(); defer { h.close() }
        h.key(36, "\r"); XCTAssertEqual(h.replies.count, 1)
        h.panel.hideForSuspension()
        h.panel.show(records: h.records)
        try h.complete(0)
        XCTAssertTrue(h.pasted.isEmpty)
    }
}
