import AppKit
import XCTest
@testable import ClipShelf
@testable import ClipShelfCore

@MainActor final class PanelFileCardPerformanceProbeTests: XCTestCase {
    private final class CardReference {
        weak var card: ClipboardCardView?
        init(_ card: ClipboardCardView) { self.card = card }
    }

    /// An opt-in, identical fixture for comparing revisions. No user database or pasteboard is opened.
    func testRepeatedFilePages() throws {
        guard ProcessInfo.processInfo.environment["CLIPSHELF_PERF_PROBE"] == "1" else { throw XCTSkip("probe only") }
        let records = (0..<300).map { index -> ClipboardRecord in
            let ext = ["mp3", "pdf", "docx"][index % 3]
            let url = URL(fileURLWithPath: "/synthetic-clipshelf-fixture/file-\(index).\(ext)")
            return ClipboardRecord(text: url.path, sourceApp: "Finder", sourceBundleID: "com.apple.finder",
                copiedAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(index)), parts: [
                    ClipboardPart(representations: [ClipboardRepresentation(typeIdentifier: "public.file-url",
                                                                          data: Data(url.absoluteString.utf8))])])
        }
        let panel = ClipboardPanelController()
        let window = UnshownTestPanel(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 330),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = panel.window?.contentView; window.delegate = panel; panel.window = window
        defer { panel.dismiss() }
        let boards = [Pinboard(name: "Synthetic")]
        panel.setPinboards(boards)
        panel.show(records: records)
        window.contentView?.layoutSubtreeIfNeeded()
        // Let async icon loaders finish in versions that have them.
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let collection = try XCTUnwrap(window.contentView.flatMap {
            descendants($0).compactMap { $0 as? NSCollectionView }.first
        })
        var references: [CardReference] = []
        var seen = Set<ObjectIdentifier>()
        var timings: [Double] = []
        let initialBytes = MemoryFootprint.bytes() ?? 0
        for iteration in 0..<80 {
            autoreleasepool {
                let start = DispatchTime.now().uptimeNanoseconds
                panel.setPinboards(boards)
                panel.update(records: iteration.isMultiple(of: 2) ? records : records.reversed())
                collection.scrollToItems(at: [IndexPath(item: (iteration * 7) % records.count, section: 0)], scrollPosition: .left)
                window.contentView?.layoutSubtreeIfNeeded()
                window.contentView?.displayIfNeeded()
                timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                for view in descendants(collection) {
                    if let card = view as? ClipboardCardView, seen.insert(ObjectIdentifier(card)).inserted {
                        references.append(CardReference(card))
                    }
                }
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let endBytes = MemoryFootprint.bytes() ?? 0
        timings.sort()
        print(String(format: "PERF file-pages rounds=80 p50=%.2fms p95=%.2fms start=%.2fMiB end=%.2fMiB delta=%.2fMiB sampledLiveCards=%d",
            timings[40], timings[75], Double(initialBytes) / 1_048_576, Double(endBytes) / 1_048_576,
            Double(endBytes) / 1_048_576 - Double(initialBytes) / 1_048_576,
            references.filter { $0.card != nil }.count))
    }
}
