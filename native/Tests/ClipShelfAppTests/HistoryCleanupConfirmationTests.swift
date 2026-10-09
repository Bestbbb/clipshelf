import AppKit
import ClipShelfCore
import XCTest
@testable import ClipShelf

@MainActor
private final class CleanupConfirmationHarness {
    let controller: HistoryCleanupConfirmationController
    var replies: [Bool] = []
    var presentations = 0
    init(request: HistoryCleanupRequest = .clearHistory,
         summary: HistoryCleanupSummary = .init(deletedCount: 12, preservedPinnedCount: 3,
             privateSyncCount: 4, sharedSyncCount: 5, excludedCount: 6)) {
        controller = HistoryCleanupConfirmationController(request: request, summary: summary)
        controller.presentWindow = { [weak self] _, _ in self?.presentations += 1 }
    }
    func present() { controller.present { [weak self] in self?.replies.append($0) } }
    func all<T: NSView>(_ type: T.Type) -> [T] {
        func collect(_ view: NSView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap(collect) }
        return controller.window?.contentView.map(collect) ?? []
    }
    func text(_ label: String) throws -> String {
        try XCTUnwrap(all(NSTextField.self).first { $0.accessibilityLabel() == label }).stringValue
    }
    func button(_ title: String) throws -> NSButton { try XCTUnwrap(all(NSButton.self).first { $0.title == title }) }
    func click(_ title: String) throws { try button(title).performClick(nil) }
    func dismiss() { controller.dismiss() }
}

@MainActor
final class HistoryCleanupConfirmationTests: XCTestCase {
    private var empty: HistoryCleanupSummary {
        .init(deletedCount: 0, preservedPinnedCount: 0, privateSyncCount: 0, sharedSyncCount: 0, excludedCount: 7)
    }

    func testSummarySeparatesDeletionPinnedAndSyncSubsetsAndExcludedItems() throws {
        let h = CleanupConfirmationHarness(); defer { h.dismiss() }; h.present()
        XCTAssertEqual(h.presentations, 1)
        XCTAssertEqual(try h.text("删除记录数量"), "删除 12 条未固定记录。")
        XCTAssertTrue(try h.text("保留固定记录数量").contains("3 条固定记录仅移出历史，仍保留在分组中"))
        XCTAssertTrue(try h.text("清理同步影响").contains("4 条关联私有同步，5 条关联共享分组"))
        XCTAssertTrue(try h.text("清理同步影响").contains("不是额外删除"))
        XCTAssertTrue(try h.text("不修改记录数量").contains("6 条"))
        XCTAssertTrue(try h.text("不修改记录数量").contains("本次不会修改"))
        let sync = try h.text("同步范围说明")
        XCTAssertTrue(sync.contains("共享参与者")); XCTAssertTrue(sync.contains("离线只会延后同步"))
        XCTAssertTrue(sync.contains("停用传输也不代表仅在本机清理"))
        XCTAssertTrue(try h.text("不可撤销说明").contains("不能通过撤销恢复"))
        XCTAssertTrue(try h.text("不可撤销说明").contains("不保证立即释放磁盘空间"))
        XCTAssertFalse(try XCTUnwrap(h.controller.window).isVisible)
        XCTAssertTrue(h.replies.isEmpty)
    }

    func testRequestScopeAndConfirmationLabelsAreExplicit() throws {
        for (request, scope, confirm): (HistoryCleanupRequest, String, String) in [
            (.clearHistory, "当前全部剪贴板历史", "确认清空历史"),
            (.retention(days: 30), "设为 30 天，并立即清理超过期限", "确认更改期限"),
            (.automatic(days: 7), "当前规则：保留最近 7 天", "确认清理")
        ] {
            let h = CleanupConfirmationHarness(request: request); defer { h.dismiss() }; h.present()
            XCTAssertTrue(try h.text("清理范围").contains(scope))
            XCTAssertFalse(try h.text("清理范围").contains("自动清理需要确认"))
            try h.click(confirm)
            XCTAssertEqual(h.replies, [true])
        }
    }

    func testNoAffectedClearOffersOnlyCloseAndNeverConfirms() throws {
        let h = CleanupConfirmationHarness(summary: empty); defer { h.dismiss() }; h.present()
        XCTAssertEqual(h.all(NSButton.self).map(\.title), ["关闭"])
        XCTAssertEqual(try h.text("清理标题"), "没有可清理的历史")
        XCTAssertTrue(try h.text("不修改记录数量").contains("7 条"))
        h.controller.perform(NSSelectorFromString("confirmCleanup"))
        XCTAssertTrue(h.replies.isEmpty)
        try h.click("关闭")
        XCTAssertEqual(h.replies, [false])
    }

    func testRetentionWithNoAffectedItemsCanStillChangePolicy() throws {
        let h = CleanupConfirmationHarness(request: .retention(days: 90), summary: empty)
        defer { h.dismiss() }; h.present()
        XCTAssertTrue(try h.text("空清理说明").contains("仍可确认更改保留期限"))
        try h.click("确认更改期限")
        XCTAssertEqual(h.replies, [true])
    }

    func testCancelEscapeAndWindowCloseRespondFalseExactlyOnce() throws {
        for route in 0..<4 {
            let h = CleanupConfirmationHarness(); defer { h.dismiss() }; h.present()
            let window = try XCTUnwrap(h.controller.window)
            switch route {
            case 0: try h.click("取消")
            case 1: window.cancelOperation(nil)
            case 2: window.performClose(nil)
            default: h.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
            }
            h.controller.perform(NSSelectorFromString("cancelCleanup"))
            h.controller.perform(NSSelectorFromString("confirmCleanup"))
            h.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
            XCTAssertEqual(h.replies, [false], "route \(route)")
        }
    }

    func testConfirmationIsOnceOnlyAndUnmodifiedReturnDefaultsToCancel() throws {
        let h = CleanupConfirmationHarness(); defer { h.dismiss() }; h.present()
        XCTAssertEqual(try h.button("取消").keyEquivalent, "\r")
        XCTAssertEqual(try h.button("确认清空历史").keyEquivalent, "")
        XCTAssertTrue(try h.button("取消").nextKeyView === h.button("确认清空历史"))
        try h.click("确认清空历史")
        h.controller.perform(NSSelectorFromString("confirmCleanup"))
        h.controller.perform(NSSelectorFromString("cancelCleanup"))
        XCTAssertEqual(h.replies, [true])
        XCTAssertFalse(try h.button("确认清空历史").isEnabled)

        let keyboard = CleanupConfirmationHarness(); defer { keyboard.dismiss() }; keyboard.present()
        let window = try XCTUnwrap(keyboard.controller.window)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36))
        XCTAssertTrue(window.performKeyEquivalent(with: enter))
        XCTAssertEqual(keyboard.replies, [false])
    }

    func testProgrammaticDismissDoesNotRespondAndOldActionsCannotAffectReplacement() throws {
        let old = CleanupConfirmationHarness(), next = CleanupConfirmationHarness(request: .retention(days: 10))
        defer { old.dismiss(); next.dismiss() }
        old.present(); old.dismiss(); next.present()
        old.controller.perform(NSSelectorFromString("confirmCleanup"))
        old.controller.perform(NSSelectorFromString("cancelCleanup"))
        old.controller.window?.cancelOperation(nil)
        old.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: old.controller.window))
        old.present()
        XCTAssertEqual(old.presentations, 1)
        XCTAssertTrue(old.replies.isEmpty); XCTAssertTrue(next.replies.isEmpty)
        try next.click("确认更改期限")
        XCTAssertEqual(next.replies, [true]); XCTAssertTrue(old.replies.isEmpty)
    }

    func testDuplicatePresentationAndActionsBeforePresentationCannotReplaceResponse() throws {
        let h = CleanupConfirmationHarness(); defer { h.dismiss() }
        h.controller.perform(NSSelectorFromString("confirmCleanup"))
        h.controller.perform(NSSelectorFromString("cancelCleanup"))
        h.present()
        var replacementCalls = 0
        h.controller.present { _ in replacementCalls += 1 }
        try h.click("取消")
        XCTAssertEqual(h.replies, [false]); XCTAssertEqual(replacementCalls, 0)
        XCTAssertEqual(h.presentations, 1)
    }

    func testLargeCountsKeepFullSummaryScrollableAndActionsReachableAtMinimumSize() throws {
        let count = Int.max / 4
        let h = CleanupConfirmationHarness(request: .retention(days: 365), summary: .init(
            deletedCount: count, preservedPinnedCount: count, privateSyncCount: count,
            sharedSyncCount: count, excludedCount: count))
        defer { h.dismiss() }; h.present()
        let window = try XCTUnwrap(h.controller.window)
        window.setContentSize(NSSize(width: 420, height: 320))
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(h.all(NSScrollView.self).first)
        let document = try XCTUnwrap(scroll.documentView)
        document.layoutSubtreeIfNeeded()
        XCTAssertTrue(scroll.hasVerticalScroller)
        XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height)
        for title in ["取消", "确认更改期限"] {
            let button = try h.button(title), rect = root.convert(button.bounds, from: button)
            XCTAssertTrue(root.bounds.contains(rect), "\(title): \(rect) outside \(root.bounds)")
            XCTAssertGreaterThan(rect.height, 0); XCTAssertGreaterThan(rect.width, 0)
        }
        for field in h.all(NSTextField.self) {
            XCTAssertEqual(field.maximumNumberOfLines, 0)
            XCTAssertEqual(field.lineBreakMode, .byWordWrapping)
            XCTAssertGreaterThan(field.frame.height, 0)
            XCTAssertLessThanOrEqual(field.frame.width, scroll.contentView.bounds.width + 1)
        }
        XCTAssertTrue(try h.text("删除记录数量").contains(String(count)))
        XCTAssertTrue(try h.text("不修改记录数量").contains(String(count)))
    }
}
