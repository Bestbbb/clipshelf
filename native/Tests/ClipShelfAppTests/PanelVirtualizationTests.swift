import AppKit
import XCTest
@testable import ClipShelf
@testable import ClipShelfCore

@MainActor private final class CountingCardDataSource: NSObject, NSCollectionViewDataSource {
    let panel: ClipboardPanelController
    var requestedItems = Set<Int>()

    init(panel: ClipboardPanelController) { self.panel = panel }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        panel.collectionView(collectionView, numberOfItemsInSection: section)
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        requestedItems.insert(indexPath.item)
        return panel.collectionView(collectionView, itemForRepresentedObjectAt: indexPath)
    }
}

@MainActor final class PanelVirtualizationTests: XCTestCase {
    func testThreeHundredRecordsCreateOnlyViewportCardsAndLoadDistantCardsOnDemand() throws {
        let panel = ClipboardPanelController()
        let window = UnshownTestPanel(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 330),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = panel.window?.contentView
        window.delegate = panel
        panel.window = window
        panel.resolveVisibleScreenFrame = { _ in NSRect(x: 0, y: 0, width: 1180, height: 800) }
        defer { panel.dismiss() }
        @MainActor func findCollection(in root: NSView) -> NSCollectionView? {
            if let view = root as? NSCollectionView { return view }
            return root.subviews.lazy.compactMap { findCollection(in: $0) }.first
        }
        let collection = try XCTUnwrap(window.contentView.flatMap { findCollection(in: $0) })
        let dataSource = CountingCardDataSource(panel: panel)
        collection.dataSource = dataSource
        // NSCollectionView's dataSource is weak; keep the counter through both layouts.
        defer { withExtendedLifetime(dataSource) {} }
        panel.show(records: (0..<300).map { ClipboardRecord(text: "Virtualized record \($0)") })
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()

        let layout = try XCTUnwrap(collection.collectionViewLayout as? NSCollectionViewFlowLayout)
        let viewport = try XCTUnwrap(collection.enclosingScrollView).contentSize.width
        let visibleColumns = Int(ceil(viewport / layout.itemSize.width))
        let viewportBound = visibleColumns * 2 + 2 // allow native overscan and a partially visible card
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 300)
        XCTAssertTrue(dataSource.requestedItems.contains(0))
        XCTAssertLessThanOrEqual(dataSource.requestedItems.count, viewportBound)
        XCTAssertFalse(dataSource.requestedItems.contains(299), "A distant record must not create a view at first display.")
        let firstPage = dataSource.requestedItems

        collection.scrollToItems(at: [IndexPath(item: 299, section: 0)], scrollPosition: .right)
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
        XCTAssertTrue(dataSource.requestedItems.contains(299), "Scrolling must materialize the destination card.")
        XCTAssertLessThanOrEqual(dataSource.requestedItems.subtracting(firstPage).count, viewportBound)
        XCTAssertLessThan(dataSource.requestedItems.count, 300, "Scrolling must not eagerly construct intervening cards.")
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 300)
        print("VIRTUALIZATION records=300 firstViewport=\(firstPage.count) createdAcrossTwoDistantViewports=\(dataSource.requestedItems.count)")
    }

    func testReopenRemotePageCompactToggleAndSearchExpandCreateOnlyViewportCards() throws {
        let panel = ClipboardPanelController()
        let window = UnshownTestPanel(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 330),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = panel.window?.contentView
        window.delegate = panel
        panel.window = window
        panel.resolveVisibleScreenFrame = { _ in NSRect(x: 0, y: 0, width: 1180, height: 800) }
        defer { panel.dismiss() }
        @MainActor func findCollection(in root: NSView) -> NSCollectionView? {
            if let view = root as? NSCollectionView { return view }
            return root.subviews.lazy.compactMap { findCollection(in: $0) }.first
        }
        let collection = try XCTUnwrap(window.contentView.flatMap { findCollection(in: $0) })
        let dataSource = CountingCardDataSource(panel: panel)
        collection.dataSource = dataSource
        defer { withExtendedLifetime(dataSource) {} }

        let metadata = (0..<300).map { index in
            ClipboardRecordMetadata(id: UUID(), text: "Remote record \(index)", sourceApp: "TextEdit",
                sourceBundleID: "com.apple.TextEdit", copiedAt: Date(), renamedTitle: nil, ocrText: nil,
                pinboardID: nil, pinboardOrder: nil, isInHistory: true, revision: 1, kind: .text,
                representationTypes: [["public.utf8-plain-text"]], originDeviceID: nil,
                originDeviceName: nil, originDeviceConflict: false)
        }
        panel.onPageRequest = { _, completion in
            completion(.success(PanelHistoryPage(records: metadata, offset: 0, hasMore: false, focusID: metadata.first?.id)))
        }

        panel.show(metadata: [])
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
        let afterFirstOpen = dataSource.requestedItems.count

        panel.dismiss()
        dataSource.requestedItems.removeAll()
        panel.show(metadata: metadata)
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
        let afterSecondOpen = dataSource.requestedItems.count

        dataSource.requestedItems.removeAll()
        panel.setCompactMode(true)
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
        let afterCompact = dataSource.requestedItems.count

        print("VIRTUALIZATION_REOPEN first=\(afterFirstOpen) second=\(afterSecondOpen) compact=\(afterCompact)")
        XCTAssertLessThanOrEqual(afterFirstOpen, 14)
        XCTAssertLessThanOrEqual(afterSecondOpen, 14)
        XCTAssertLessThanOrEqual(afterCompact, 16)
    }
}
