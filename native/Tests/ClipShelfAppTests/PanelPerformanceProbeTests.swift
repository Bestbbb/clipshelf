import AppKit
import XCTest
@testable import ClipShelf
@testable import ClipShelfCore

/// Allocation microbenchmarks, not input-to-display latency. Runs only with CLIPSHELF_PERF_PROBE=1.
@MainActor final class PanelPerformanceProbeTests: XCTestCase {
    private func ms(_ block: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds; block()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func waitForSourceIcons(_ bundles: [String]) async {
        let loaded = expectation(description: "all fixture icons loaded or confirmed missing")
        loaded.expectedFulfillmentCount = bundles.count
        for bundle in bundles {
            CardIconCache.shared.request(.application(bundle)) { _ in loaded.fulfill() }
        }
        await fulfillment(of: [loaded], timeout: 10)
    }

    func testProbeCardAndShelfCost() async throws {
        guard ProcessInfo.processInfo.environment["CLIPSHELF_PERF_PROBE"] == "1" else { throw XCTSkip("probe only") }
        let bundles = ["com.apple.Notes", "com.apple.Safari", "com.apple.dt.Xcode", "com.apple.TextEdit", "com.apple.Terminal",
                       "com.apple.finder", "com.google.Chrome", "com.microsoft.VSCode", "com.tencent.xinWeChat", "com.apple.Preview"]
        let records = (0..<300).map { index in
            ClipboardRecord(text: "第 \(index) 条：把复制的内容，放回你的工作流。\nline two \(index)\n    let value = \(index)",
                            sourceApp: "App", sourceBundleID: bundles[index % bundles.count],
                            copiedAt: Date().addingTimeInterval(TimeInterval(-index * 60)))
        }
        let contents = records.map(ClipboardCardContent.init)
        if ProcessInfo.processInfo.environment["CLIPSHELF_PERF_PREWARM"] == "1" {
            await waitForSourceIcons(bundles)
        }
        let cold = ms { for (i, c) in contents.prefix(10).enumerated() { _ = ClipboardCardView(record: c, position: i) } }
        // This deliberately constructs every card with icon callbacks still pending.
        // The real collection view creates only items needed for its viewport.
        let burst = ms { for (i, c) in contents.enumerated() { _ = ClipboardCardView(record: c, position: i) } }
        await waitForSourceIcons(bundles)
        let cached = ms { for (i, c) in contents.enumerated() { _ = ClipboardCardView(record: c, position: i) } }
        let tint = ms { for _ in 0..<10 { _ = ClipboardCardView.headerTint(for: NSWorkspace.shared.icon(for: .pdf)) } } / 10

        var showTimes: [Double] = []
        for _ in 0..<5 {
            let panel = ClipboardPanelController()
            let window = UnshownTestPanel(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 330),
                                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.contentView = panel.window?.contentView; window.delegate = panel; panel.window = window
            showTimes.append(ms {
                panel.show(records: records, status: nil)
                window.contentView?.layoutSubtreeIfNeeded()
                window.contentView?.displayIfNeeded()
            })
            panel.dismiss()
        }
        let report = String(format: "PERF cold10Cards=%.1fms burst300Cards=%.1fms cached300Cards=%.1fms headerTint=%.2fms show300Records=[%@]ms",
                            cold, burst, cached, tint, showTimes.map { String(format: "%.1f", $0) }.joined(separator: ", "))
        print(report)
    }

    func testProbePasteWriteCost() throws {
        guard ProcessInfo.processInfo.environment["CLIPSHELF_PERF_PROBE"] == "1" else { throw XCTSkip("probe only") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-perf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let record = try store.create(ClipboardRecord(text: "性能探针：一段普通文本", sourceApp: "TextEdit"))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("clipshelf-perf-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let publications = OwnedFilePublicationCoordinator(store: store, pasteboard: pasteboard)
        var retain: [Double] = [], publish: [Double] = [], encode: [Double] = [], write: [Double] = [], reconcile: [Double] = []
        for _ in 0..<20 {
            var lease: OwnedAssetLease!
            retain.append(ms { lease = try! publications.retain([record]) })
            var items: [NSPasteboardItem] = []
            encode.append(ms { items = try! ClipboardCodec.items(for: [record], plainText: false) })
            publish.append(ms { _ = try! publications.publish(lease: lease, purpose: .clipboard) })
            write.append(ms { pasteboard.clearContents(); _ = pasteboard.writeObjects(items) })
            reconcile.append(ms { publications.reconcileClipboard() })
        }
        func median(_ v: [Double]) -> String { String(format: "%.2f", v.sorted()[v.count / 2]) }
        print("PERF paste-write median ms: retain=\(median(retain)) encode=\(median(encode)) publish=\(median(publish)) pasteboard=\(median(write)) reconcile=\(median(reconcile))")
    }
}
