import AppKit
import ClipShelfCore
import XCTest
@testable import ClipShelf

final class ClipboardCardDragTests: XCTestCase {
    @MainActor private func event(_ type: NSEvent.EventType, location: NSPoint = NSPoint(x: 40, y: 60)) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 1,
                          windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @MainActor func testOrderingDragUsesOnlyMetadataAndCannotLeaveApplication() {
        let records = [ClipboardRecord(text: "first", revision: 7), ClipboardRecord(text: "second", revision: 11)]
        let contents = records.map(ClipboardCardContent.init)
        let items = ClipboardCardView.orderingDragItems(for: contents)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.string(forType: ClipboardCardView.recordIDType), "clipshelf-selection")
        XCTAssertTrue(items.allSatisfy { $0.types == [ClipboardCardView.recordIDType] })
        let card = ClipboardCardView(record: contents[0], position: 0)
        card.mouseDown(with: event(.leftMouseDown))
        card.prepareOrderingDrag(contents: contents, originID: UUID())
        XCTAssertEqual(card.draggedRecordIDs, records.map(\.id))
        XCTAssertEqual(card.draggedRecordRevisions, [records[0].id: 7, records[1].id: 11])
        XCTAssertEqual(card.dragOperationMask(for: .withinApplication), .move)
        XCTAssertTrue(card.dragOperationMask(for: .outsideApplication).isEmpty)
        card.mouseUp(with: event(.leftMouseUp))
    }

    @MainActor func testPayloadDragPreservesPDFAndImageBytesWithoutDisplayTitle() throws {
        let pdf = Data("%PDF-synthetic".utf8), png = Data([137, 80, 78, 71])
        let records = [
            ClipboardRecord(text: "扫描文稿（PDF）", parts: [.init(representations: [.init(typeIdentifier: "com.adobe.pdf", data: pdf)])]),
            ClipboardRecord(text: "图片 640 × 400", parts: [.init(representations: [.init(typeIdentifier: "public.png", data: png)])])
        ]
        let items = try ClipboardCardView.payloadDragItems(for: records)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].data(forType: .pdf), pdf)
        XCTAssertEqual(items[1].data(forType: .png), png)
        XCTAssertTrue(items.allSatisfy { !$0.types.contains(.string) && !$0.types.contains(ClipboardCardView.recordIDType) })
    }

    @MainActor func testPayloadDragKeepsOrderedRichPartsAndSeparateRecords() throws {
        let rtf = Data("{\\rtf1 rich}".utf8), html = Data("<b>rich</b>".utf8)
        let rich = ClipboardRecord(text: "display", parts: [
            .init(representations: [.init(typeIdentifier: NSPasteboard.PasteboardType.rtf.rawValue, data: rtf)]),
            .init(representations: [.init(typeIdentifier: NSPasteboard.PasteboardType.html.rawValue, data: html)])
        ])
        let items = try ClipboardCardView.payloadDragItems(for: [rich, ClipboardRecord(text: "last")])
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].data(forType: .rtf), rtf)
        XCTAssertEqual(items[1].data(forType: .html), html)
        XCTAssertEqual(items[2].string(forType: .string), "last")
        XCTAssertNil(items[0].string(forType: .string))
        XCTAssertNil(items[1].string(forType: .string))
    }

    @MainActor func testReleasedOrReplacedMouseGestureRejectsDelayedPayload() throws {
        let record = ClipboardRecord(text: "synthetic")
        let card = ClipboardCardView(record: ClipboardCardContent(record), position: 0)
        card.mouseDown(with: event(.leftMouseDown))
        let firstGesture = try XCTUnwrap(card.activeGestureID)
        card.preparePayloadDrag(originID: UUID())
        card.mouseUp(with: event(.leftMouseUp))
        XCTAssertFalse(card.providePreparedPayload(records: [record], gestureID: firstGesture))
        XCTAssertTrue(card.draggedRecordIDs.isEmpty)
        card.mouseDown(with: event(.leftMouseDown))
        card.preparePayloadDrag(originID: UUID())
        XCTAssertFalse(card.providePreparedPayload(records: [record], gestureID: firstGesture))
        let secondGesture = try XCTUnwrap(card.activeGestureID)
        XCTAssertTrue(card.providePreparedPayload(records: [record], gestureID: secondGesture))
        XCTAssertEqual(card.dragOperationMask(for: .outsideApplication), .copy)
        card.mouseUp(with: event(.leftMouseUp))
        XCTAssertTrue(card.draggedRecordIDs.isEmpty)
    }

    @MainActor func testDecorativeTextAndImageHitTheCard() {
        let card = ClipboardCardView(record: ClipboardCardContent(ClipboardRecord(text: "body")), position: 0)
        card.frame = NSRect(x: 0, y: 0, width: 220, height: 240)
        card.layoutSubtreeIfNeeded()
        for child in card.subviews where !child.isHidden && !child.frame.isEmpty {
            XCTAssertTrue(card.hitTest(NSPoint(x: child.frame.midX, y: child.frame.midY)) === card)
            if let label = child as? NSTextField { XCTAssertFalse(label.isSelectable) }
        }
    }

    @MainActor func testDeliveredDragEventsPrepareGestureWithoutPhysicalButtonState() {
        let content = ClipboardCardContent(ClipboardRecord(text: "synthetic"))
        let card = ClipboardCardView(record: content, position: 0)
        card.mouseDown(with: event(.leftMouseDown))
        card.prepareOrderingDrag(contents: [content], originID: UUID())
        XCTAssertFalse(card.hasPreparedDragGesture)
        // No window is shown and no physical mouse event is generated by this test.
        card.mouseDragged(with: event(.leftMouseDragged, location: NSPoint(x: 90, y: 60)))
        XCTAssertTrue(card.hasPreparedDragGesture)
        card.mouseUp(with: event(.leftMouseUp))
        XCTAssertFalse(card.hasPreparedDragGesture)
    }

    @MainActor func testCancelledGestureRejectsDelayedPayloadAndLaterDragEvent() throws {
        let record = ClipboardRecord(text: "synthetic")
        let card = ClipboardCardView(record: ClipboardCardContent(record), position: 0)
        card.mouseDown(with: event(.leftMouseDown))
        card.preparePayloadDrag(originID: UUID())
        let gestureID = try XCTUnwrap(card.activeGestureID)
        card.cancelOperation(nil)
        XCTAssertFalse(card.providePreparedPayload(records: [record], gestureID: gestureID))
        card.mouseDragged(with: event(.leftMouseDragged, location: NSPoint(x: 90, y: 60)))
        XCTAssertFalse(card.hasPreparedDragGesture)
    }

    @MainActor func testRemovingCardFromWindowRejectsDelayedPayload() throws {
        let record = ClipboardRecord(text: "synthetic")
        let card = ClipboardCardView(record: ClipboardCardContent(record), position: 0)
        // An unshown window exercises AppKit's actual detach callback without desktop UI.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 240),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView?.addSubview(card)
        card.mouseDown(with: event(.leftMouseDown))
        card.preparePayloadDrag(originID: UUID())
        let gestureID = try XCTUnwrap(card.activeGestureID)
        card.removeFromSuperview()
        XCTAssertNil(card.window)
        XCTAssertNil(card.activeGestureID)
        XCTAssertFalse(card.providePreparedPayload(records: [record], gestureID: gestureID))
    }
}
