import AppKit
import XCTest
@testable import ClipShelf
@testable import ClipShelfCore
@testable import ClipShelfLocalization

@MainActor final class LocalizedLayoutTests: XCTestCase {
    private func english() -> LocalizationRuntime {
        let runtime = LocalizationRuntime()
        runtime.configure(language: .en, preferredLanguages: ["en"], hostBundle: Bundle(for: LocalizedLayoutTests.self))
        XCTAssertEqual(runtime.text("取消"), "Cancel", "Layout fixtures must use the actual English catalog")
        return runtime
    }

    func testStackEnglishActionsFitWithoutEqualWidthTruncation() throws {
        let runtime = english(), controller = StackPanelController()
        let window = try XCTUnwrap(controller.window), content = try XCTUnwrap(window.contentView)
        let buttons = all(NSButton.self, in: content)
        let restore = try XCTUnwrap(buttons.first { $0.action.map(NSStringFromSelector) == "restorePrevious" })
        let direction = try XCTUnwrap(buttons.first { $0.action.map(NSStringFromSelector) == "reverse" })
        let end = try XCTUnwrap(buttons.first { $0.action.map(NSStringFromSelector) == "endSession" })
        restore.title = runtime.text("恢复上一项")
        direction.title = runtime.text("反序 ↑")
        end.title = runtime.text("结束")
        content.layoutSubtreeIfNeeded()
        for button in [restore, direction, end] {
            XCTAssertGreaterThanOrEqual(button.bounds.width + 0.5, button.fittingSize.width, button.title)
            XCTAssertTrue(content.bounds.contains(button.convert(button.bounds, to: content)), button.title)
        }
        XCTAssertGreaterThan(restore.bounds.width, end.bounds.width)
        XCTAssertFalse(window.isVisible)
    }

    func testUploadScopeWrapsAndReservesEnoughHeightForEnglishAndLongerText() throws {
        let runtime = english()
        let englishTitle = runtime.text("同时上传此前未归属其他账号的本地历史与分组")
        for title in [englishTitle, String(repeating: englishTitle + " ", count: 4)] {
            let choice = CloudSyncSettingsController.makeLocalHistoryUploadChoice(title: title)
            let cell = try XCTUnwrap(choice.cell)
            XCTAssertTrue(cell.wraps)
            XCTAssertEqual(cell.lineBreakMode, .byWordWrapping)
            XCTAssertEqual(choice.title, title)
            XCTAssertEqual(choice.state, .off, "Wrapping must not opt in to uploading existing content")
            let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: choice.bounds.width, height: .greatestFiniteMagnitude))
            XCTAssertGreaterThanOrEqual(choice.bounds.height, needed.height)
            XCTAssertGreaterThan(needed.height, 16, "The account restriction must remain on visible additional lines")
            XCTAssertEqual(choice.bounds.width, 430)
        }
    }

    func testInclusiveDateLabelsExpandTogetherAndKeepPickersInsidePopover() throws {
        let runtime = english()
        let controller = HistoryFilterController(query: HistoryQuery(),
            options: .init(pinboards: [], sources: [:], devices: [:], localDeviceID: nil))
        let window = NSPanel(contentRect: NSRect(origin: .zero, size: controller.preferredContentSize),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = controller.view
        let labels = all(NSButton.self, in: controller.view).filter {
            $0.action.map(NSStringFromSelector) == "datesChanged"
        }
        XCTAssertEqual(labels.count, 2)
        labels[0].title = runtime.text("开始（含）")
        labels[1].title = runtime.text("结束（含）")
        controller.view.layoutSubtreeIfNeeded()
        for label in labels {
            XCTAssertGreaterThanOrEqual(label.bounds.width + 0.5, label.fittingSize.width)
            XCTAssertTrue(controller.view.bounds.contains(label.convert(label.bounds, to: controller.view)))
        }
        XCTAssertEqual(labels[0].bounds.width, labels[1].bounds.width, accuracy: 0.5)
        for picker in all(NSDatePicker.self, in: controller.view) {
            XCTAssertTrue(controller.view.bounds.contains(picker.convert(picker.bounds, to: controller.view)))
        }
        XCTAssertFalse(window.isVisible)
    }

    func testMCPPermissionSummaryUsesDisplayLabelsWithoutChangingWireValues() throws {
        let permissions: Set<MCPAuthorizationStore.Permission> = [.read, .write, .delete]
        let before = try JSONEncoder().encode(permissions.sorted { $0.rawValue < $1.rawValue })
        XCTAssertEqual(MCPSettingsController.permissionSummary(permissions),
                       [L10n.text("删除"), L10n.text("读取"), L10n.text("新增与修改")].joined(separator: " / "))
        XCTAssertEqual(MCPSettingsController.permissionSummary([]), "")
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: before), ["delete", "read", "write"])
        XCTAssertEqual(try JSONEncoder().encode(permissions.sorted { $0.rawValue < $1.rawValue }), before)
    }

    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }
}
