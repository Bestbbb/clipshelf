import AppKit
import ClipShelfCore
import XCTest
@testable import ClipShelf

final class ShortClipboardCardLayoutTests: XCTestCase {
    @MainActor private func resize(_ card: ClipboardCardView, height: CGFloat, width: CGFloat = 222) {
        card.setFrameSize(NSSize(width: width, height: height))
        card.layoutSubtreeIfNeeded()
    }

    @MainActor private func shortTitle(_ card: ClipboardCardView) throws -> NSTextField {
        try XCTUnwrap(card.subviews.compactMap { $0 as? NSTextField }.first {
            $0.accessibilityIdentifier() == "clipboard.short-title"
        })
    }

    @MainActor private func visibleSubviews(_ card: ClipboardCardView) -> Set<ObjectIdentifier> {
        Set(card.subviews.filter { !$0.isHidden }.map(ObjectIdentifier.init))
    }

    @MainActor private func assertShortLayout(_ card: ClipboardCardView,
                                              file: StaticString = #filePath, line: UInt = #line) throws {
        let title = try shortTitle(card)
        XCTAssertEqual(visibleSubviews(card), [ObjectIdentifier(title)], file: file, line: line)
        XCTAssertEqual(title.stringValue, card.record.title, file: file, line: line)
        XCTAssertEqual(title.maximumNumberOfLines, 1, file: file, line: line)
        XCTAssertEqual(title.frame.midY, card.bounds.midY, accuracy: 0.001, file: file, line: line)
        XCTAssertGreaterThanOrEqual(title.frame.width, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(title.frame.height, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(title.frame.minX, card.bounds.minX, file: file, line: line)
        XCTAssertGreaterThanOrEqual(title.frame.minY, card.bounds.minY, file: file, line: line)
        XCTAssertLessThanOrEqual(title.frame.maxX, card.bounds.maxX, file: file, line: line)
        XCTAssertLessThanOrEqual(title.frame.maxY, card.bounds.maxY, file: file, line: line)
        XCTAssertFalse(title.isSelectable, file: file, line: line)
        XCTAssertFalse(title.isEditable, file: file, line: line)
        XCTAssertFalse(card.constraints.contains {
            $0.isActive && ($0.firstItem as? NSView) !== title && ($0.secondItem as? NSView) !== title
                && ($0.firstAttribute == .top || $0.firstAttribute == .bottom)
        },
                       "Tall-card constraints must not force hidden previews to a negative height", file: file, line: line)
    }

    @MainActor func testTextRestoresFullPresentationAndQuickPasteAfterShortLayout() throws {
        let record = ClipboardRecord(text: "Original text body", sourceApp: "Synthetic source", renamedTitle: "Saved title")
        let card = ClipboardCardView(record: .init(record), position: 2)
        card.setQuickPasteLabel("⌘3")
        resize(card, height: 224)
        let originalViews = visibleSubviews(card)
        XCTAssertTrue(try shortTitle(card).isHidden)
        XCTAssertTrue(card.subviews.compactMap { $0 as? NSImageView }.filter { $0.accessibilityIdentifier() == "clipboard.preview" }.allSatisfy(\.isHidden))
        resize(card, height: 40)
        try assertShortLayout(card)
        card.setQuickPasteLabel("⌥3")
        try assertShortLayout(card)
        resize(card, height: 120)
        XCTAssertEqual(visibleSubviews(card), originalViews)
        XCTAssertTrue(try shortTitle(card).isHidden)
        let shortcut = try XCTUnwrap(card.subviews.compactMap { $0 as? NSTextField }.first {
            $0.accessibilityLabel()?.hasPrefix("Quick Paste ") == true
        })
        XCTAssertFalse(shortcut.isHidden)
        XCTAssertEqual(shortcut.stringValue, "⌥3")
        XCTAssertEqual(card.record.id, record.id)
        XCTAssertEqual(card.record.text, record.text)
    }

    @MainActor func testImageArrivingWhileShortStaysHiddenAndAppearsAfterExpansion() throws {
        let record = ClipboardRecord(text: "Synthetic image", parts: [.init(representations: [
            .init(typeIdentifier: "public.png", data: Data([137, 80, 78, 71]))
        ])])
        let card = ClipboardCardView(record: .init(record), position: 0)
        XCTAssertEqual(card.record.kind, .image)
        resize(card, height: 224)
        let originalViews = visibleSubviews(card)
        let preview = try XCTUnwrap(card.subviews.compactMap { $0 as? NSImageView }.first { $0.accessibilityIdentifier() == "clipboard.preview" })
        XCTAssertFalse(preview.isHidden)
        resize(card, height: 20)
        let latest = NSImage(size: NSSize(width: 3, height: 2))
        card.applyThumbnail(latest)
        try assertShortLayout(card)
        XCTAssertTrue(preview.image === latest)
        resize(card, height: 180)
        XCTAssertEqual(visibleSubviews(card), originalViews)
        XCTAssertTrue(preview.image === latest)
        XCTAssertGreaterThan(preview.frame.height, 0)
    }

    @MainActor func testColorRestoresSwatchAndFooterInsteadOfTextBody() throws {
        let record = ClipboardRecord(text: "#46AABB")
        let card = ClipboardCardView(record: .init(record), position: 0, compact: true)
        XCTAssertEqual(card.record.kind, .color)
        resize(card, height: 130)
        let originalViews = visibleSubviews(card)
        let preview = try XCTUnwrap(card.subviews.compactMap { $0 as? NSImageView }.first { $0.accessibilityIdentifier() == "clipboard.preview" })
        let color = preview.layer?.backgroundColor
        XCTAssertFalse(preview.isHidden)
        XCTAssertNotNil(color)
        resize(card, height: 119)
        try assertShortLayout(card)
        resize(card, height: 130)
        XCTAssertEqual(visibleSubviews(card), originalViews)
        XCTAssertEqual(preview.layer?.backgroundColor, color)
        XCTAssertGreaterThan(preview.frame.height, 0)
    }

    @MainActor func testTinyViewportsHaveOnlyBoundedTitleAndRecoverRepeatedly() throws {
        let record = ClipboardRecord(text: String(repeating: "Very long title ", count: 20))
        let card = ClipboardCardView(record: .init(record), position: 0)
        for size in [NSSize(width: 222, height: 1), NSSize(width: 8, height: 8),
                     NSSize(width: 1, height: 0), NSSize(width: 222, height: 119)] {
            resize(card, height: 180)
            resize(card, height: size.height, width: size.width)
            try assertShortLayout(card)
            for child in card.subviews {
                XCTAssertGreaterThanOrEqual(child.frame.width, 0)
                XCTAssertGreaterThanOrEqual(child.frame.height, 0)
            }
        }
        resize(card, height: 180)
        XCTAssertTrue(try shortTitle(card).isHidden)
    }

    @MainActor func testRemovingShortcutWhileShortDoesNotReshowItOnExpansion() throws {
        let card = ClipboardCardView(record: .init(ClipboardRecord(text: "body")), position: 0)
        card.setQuickPasteLabel("⌘1")
        resize(card, height: 180)
        let shortcut = try XCTUnwrap(card.subviews.compactMap { $0 as? NSTextField }.first {
            $0.accessibilityLabel()?.hasPrefix("Quick Paste ") == true
        })
        resize(card, height: 40)
        card.setQuickPasteLabel(nil)
        resize(card, height: 180)
        XCTAssertTrue(shortcut.isHidden)
    }

    @MainActor func testShortTitleKeepsClickAndOrderingDragBoundToOriginalRecord() throws {
        let record = ClipboardRecord(text: "Original payload", renamedTitle: "Display title", revision: 7)
        let card = ClipboardCardView(record: .init(record), position: 0)
        resize(card, height: 40)
        let title = try shortTitle(card)
        XCTAssertTrue(card.hitTest(NSPoint(x: title.frame.midX, y: title.frame.midY)) === card)
        var selected = 0, clicked = 0
        card.onSelect = { selected += 1 }
        card.onClick = { _ in clicked += 1 }
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 40, y: 20), modifierFlags: [],
                                             timestamp: 1, windowNumber: 0, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1))
        }
        card.mouseDown(with: try event(.leftMouseDown))
        card.prepareOrderingDrag(contents: [card.record], originID: UUID())
        XCTAssertEqual(card.draggedRecordIDs, [record.id])
        XCTAssertEqual(card.draggedRecordRevisions, [record.id: 7])
        card.mouseUp(with: try event(.leftMouseUp))
        XCTAssertEqual(selected, 1)
        XCTAssertEqual(clicked, 1)
        XCTAssertEqual(card.record.text, record.text)
    }
}
