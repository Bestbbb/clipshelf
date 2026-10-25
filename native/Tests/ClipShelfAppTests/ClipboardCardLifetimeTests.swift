import AppKit
import XCTest
@testable import ClipShelf
@testable import ClipShelfCore

@MainActor final class ClipboardCardLifetimeTests: XCTestCase {
    func testDiscardingItemWithoutReuseRetiresExternallyRetainedCard() {
        let card = ClipboardCardView(record: ClipboardCardContent(ClipboardRecord(text: "Tooltip lifetime fixture")), position: 0)
        let child = NSView()
        child.toolTip = "Child tooltip"
        card.addSubview(child)
        card.toolTip = "Card tooltip"
        card.menu = NSMenu()
        let retainedContainer = NSView()
        weak var releasedItem: ClipboardCollectionItem?
        autoreleasepool {
            let item = ClipboardCollectionItem()
            item.view = retainedContainer
            item.configure(card)
            releasedItem = item
        }
        XCTAssertNil(releasedItem)
        // Keep the card alive just as a native tooltip registry can. The owner
        // must unregister it before releasing its own reference, even on teardown.
        XCTAssertNil(card.toolTip)
        XCTAssertNil(child.toolTip)
        XCTAssertNil(card.menu)
        XCTAssertNil(card.superview)
        XCTAssertTrue(retainedContainer.subviews.isEmpty,
                      "AppKit may retain the item view after dropping its controller; detach the old card explicitly.")
    }

    func testDetachedCardReleasesItsSubviewsAndConstraints() {
        weak var releasedCard: ClipboardCardView?
        autoreleasepool {
            let card = ClipboardCardView(record: ClipboardCardContent(ClipboardRecord(text: "Lifetime fixture")), position: 0)
            card.setFrameSize(NSSize(width: 248, height: 260))
            card.layoutSubtreeIfNeeded()
            releasedCard = card
        }
        XCTAssertNil(releasedCard, "Discarded cards must not retain their view/constraint graph.")
    }

    func testReplacingResultsReleasesThePreviousVisibleCard() throws {
        let panel = ClipboardPanelController()
        let window = UnshownTestPanel(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 330),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = panel.window?.contentView
        window.delegate = panel
        panel.window = window
        defer { panel.dismiss() }
        weak var releasedCard: ClipboardCardView?
        try autoreleasepool {
            panel.show(records: [ClipboardRecord(text: "Previous page")])
            window.contentView?.layoutSubtreeIfNeeded()
            @MainActor func cards(_ view: NSView) -> [ClipboardCardView] {
                ([view as? ClipboardCardView].compactMap { $0 }) + view.subviews.flatMap(cards)
            }
            let card = try XCTUnwrap(window.contentView.flatMap { cards($0).first })
            releasedCard = card
            panel.update(records: [ClipboardRecord(text: "Replacement page")])
            window.contentView?.layoutSubtreeIfNeeded()
        }
        XCTAssertNil(releasedCard, "Refreshing history must release replaced cards, including their menus.")
    }

    func testUnchangedPinboardsDoNotRecreateVisibleResults() throws {
        let panel = ClipboardPanelController()
        let window = UnshownTestPanel(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 330),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = panel.window?.contentView
        window.delegate = panel
        panel.window = window
        defer { panel.dismiss() }
        let boards = [Pinboard(name: "Fixture board")]
        panel.setPinboards(boards)
        panel.show(records: [ClipboardRecord(text: "Visible result")])
        window.contentView?.layoutSubtreeIfNeeded()
        @MainActor func firstCard(_ view: NSView) -> ClipboardCardView? {
            if let card = view as? ClipboardCardView { return card }
            return view.subviews.lazy.compactMap(firstCard).first
        }
        let original = try XCTUnwrap(window.contentView.flatMap(firstCard))
        panel.setPinboards(boards)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(original === window.contentView.flatMap(firstCard),
                      "The facet read that accompanies every search must not redraw the previous page.")
    }
}
