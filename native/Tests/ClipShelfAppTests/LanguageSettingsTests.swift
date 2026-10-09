import AppKit
import XCTest
import ClipShelfLocalization
@testable import ClipShelf
@testable import ClipShelfCore

private final class LanguagePreferenceFixture {
    let name = "clipshelf-language-tests.\(UUID().uuidString)"
    let preferences: UserDefaults
    init() { preferences = UserDefaults(suiteName: name)!; preferences.removePersistentDomain(forName: name) }
    deinit { preferences.removePersistentDomain(forName: name) }
    var domain: NSDictionary { (preferences.persistentDomain(forName: name) ?? [:]) as NSDictionary }
}

@MainActor final class LanguageSettingsTests: XCTestCase {
    func testMissingAndUnknownChoiceUseSystemWithoutWritingPreferences() {
        let fixture = LanguagePreferenceFixture()
        XCTAssertEqual(LanguagePreferences.selectedLanguage(in: fixture.preferences), .system)
        XCTAssertEqual(fixture.domain.count, 0)
        fixture.preferences.set("not-a-supported-language", forKey: LanguagePreferences.selectionKey)
        let before = fixture.domain
        XCTAssertEqual(LanguagePreferences.selectedLanguage(in: fixture.preferences), .system)
        XCTAssertEqual(fixture.domain, before)
    }

    func testExplicitChoicesPersistToAppAndAuthorizedSharedDomainWithoutChangingRunningLanguage() throws {
        let app = LanguagePreferenceFixture(), group = LanguagePreferenceFixture(), unrelated = LanguagePreferenceFixture()
        app.preferences.set("keep draft", forKey: "draft")
        group.preferences.set("keep inbox", forKey: "inbox")
        unrelated.preferences.set(["fr"], forKey: LanguagePreferences.appleLanguagesKey)
        let untouched = unrelated.domain, active = L10n.language
        let preferences = LanguagePreferences(preferences: app.preferences, allowsChanges: true, sharedPreferences: group.preferences)
        for language in [InterfaceLanguage.en, .zhHans, .zhHant] {
            try preferences.save(language)
            XCTAssertEqual(preferences.selectedLanguage, language)
            for fixture in [app, group] {
                XCTAssertEqual(fixture.domain[LanguagePreferences.selectionKey] as? String, language.rawValue)
                XCTAssertEqual(fixture.domain[LanguagePreferences.appleLanguagesKey] as? [String], [language.rawValue])
            }
            XCTAssertEqual(L10n.language, active, "Saving is a next-launch preference, never a runtime reconfiguration")
        }
        XCTAssertEqual(app.preferences.string(forKey: "draft"), "keep draft")
        XCTAssertEqual(group.preferences.string(forKey: "inbox"), "keep inbox")
        XCTAssertEqual(unrelated.domain, untouched)
    }

    func testSystemChoiceRemovesOnlyAppAndSharedOverridesAndRevealsInheritedLanguage() throws {
        let app = LanguagePreferenceFixture(), group = LanguagePreferenceFixture(), inherited = LanguagePreferenceFixture()
        inherited.preferences.set(["fr", "en"], forKey: LanguagePreferences.appleLanguagesKey)
        app.preferences.addSuite(named: inherited.name)
        defer { app.preferences.removeSuite(named: inherited.name) }
        let inheritedBefore = inherited.domain
        let preferences = LanguagePreferences(preferences: app.preferences, allowsChanges: true, sharedPreferences: group.preferences)
        try preferences.save(.zhHant)
        try preferences.save(.system)
        for fixture in [app, group] {
            XCTAssertEqual(fixture.domain[LanguagePreferences.selectionKey] as? String, "system")
            XCTAssertNil(fixture.domain[LanguagePreferences.appleLanguagesKey])
        }
        XCTAssertEqual(app.preferences.stringArray(forKey: LanguagePreferences.appleLanguagesKey), ["fr", "en"])
        XCTAssertEqual(inherited.domain, inheritedBefore)
    }

    func testIsolatedRuntimeRejectsWritesEvenWhenSharedDomainWasInjected() {
        let app = LanguagePreferenceFixture(), group = LanguagePreferenceFixture()
        app.preferences.set("en", forKey: LanguagePreferences.selectionKey)
        group.preferences.set(["en"], forKey: LanguagePreferences.appleLanguagesKey)
        let beforeApp = app.domain, beforeGroup = group.domain
        let preferences = LanguagePreferences(preferences: app.preferences, allowsChanges: false, sharedPreferences: group.preferences)
        XCTAssertThrowsError(try preferences.save(.zhHant))
        XCTAssertThrowsError(try preferences.save(.system))
        XCTAssertEqual(app.domain, beforeApp); XCTAssertEqual(group.domain, beforeGroup)
        XCTAssertNil(LanguagePreferences.configuredSharedPreferences(allowsChanges: false))
    }

    func testSelectionSaveIsExplicitAndDoesNotPresentOrReconfigureRunningInterface() throws {
        let fixture = LanguagePreferenceFixture()
        var presentations = 0
        let controller = LanguageSettingsController(preferences: .init(preferences: fixture.preferences, allowsChanges: true),
                                                    presentWindow: { _ in presentations += 1 })
        let picker: NSPopUpButton = try view(controller, identifier: "language.selection")
        XCTAssertEqual(picker.itemArray.compactMap { $0.representedObject as? String }, ["system", "en", "zh-Hans", "zh-Hant"])
        picker.selectItem(at: 1)
        XCTAssertEqual(fixture.domain.count, 0)
        let active = L10n.language
        controller.saveSelection()
        XCTAssertEqual(LanguagePreferences.selectedLanguage(in: fixture.preferences), .en)
        XCTAssertEqual(L10n.language, active)
        XCTAssertEqual(presentations, 0)
        let status: NSTextField = try view(controller, identifier: "language.status")
        XCTAssertTrue(status.stringValue.contains("下次启动"))
        XCTAssertFalse(try XCTUnwrap(controller.window).isVisible)
        controller.present()
        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(picker.selectedItem?.representedObject as? String, "en")
    }

    func testDisabledControlsCannotBypassIsolationViaDirectAction() throws {
        let fixture = LanguagePreferenceFixture()
        let controller = LanguageSettingsController(preferences: .init(preferences: fixture.preferences, allowsChanges: false),
                                                    presentWindow: { _ in XCTFail("Must remain unshown") })
        let picker: NSPopUpButton = try view(controller, identifier: "language.selection")
        let button: NSButton = try view(controller, identifier: "language.save")
        XCTAssertFalse(picker.isEnabled); XCTAssertFalse(button.isEnabled)
        picker.selectItem(at: 3); controller.saveSelection()
        XCTAssertEqual(fixture.domain.count, 0)
        let status: NSTextField = try view(controller, identifier: "language.status")
        XCTAssertTrue(status.stringValue.contains("不能保存"))
    }

    func testPresentationRechecksSessionAfterPreparationAndSuspendNeverSavesPendingSelection() throws {
        let fixture = LanguagePreferenceFixture()
        var allowed = false, preparations = 0, presentations = 0
        let controller = LanguageSettingsController(preferences: .init(preferences: fixture.preferences, allowsChanges: true),
                                                    presentWindow: { _ in presentations += 1 })
        controller.isPresentationAllowed = { allowed }
        controller.onPreparePresentation = { preparations += 1; allowed = false }
        controller.present()
        XCTAssertEqual(preparations, 0); XCTAssertEqual(presentations, 0)
        allowed = true; controller.present()
        XCTAssertEqual(preparations, 1); XCTAssertEqual(presentations, 0)
        controller.onPreparePresentation = { preparations += 1 }
        allowed = true; controller.present()
        XCTAssertEqual(preparations, 2); XCTAssertEqual(presentations, 1)
        let picker: NSPopUpButton = try view(controller, identifier: "language.selection")
        picker.selectItem(at: 3); controller.suspend()
        XCTAssertEqual(fixture.domain.count, 0)
        XCTAssertFalse(try XCTUnwrap(controller.window).isVisible)
    }

    func testLanguagePresentationAndSavePreserveRealEditorContentsUndoAndSnapshotWithoutDiscardGate() throws {
        let fixture = LanguagePreferenceFixture(), panel = ClipboardPanelController()
        let record = ClipboardRecord(text: "original")
        let snapshot = ClipboardEditSnapshot(record: record,
            syncConfiguration: .init(accountID: "synthetic", generation: 11),
            sharingConfiguration: .init(accountID: nil, generation: 7))
        let parent = UnshownTestPanel(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 430),
                                     styleMask: .borderless, backing: .buffered, defer: false)
        parent.contentView = panel.window?.contentView; parent.delegate = panel; panel.window = parent
        var detail: NSPanel?, preparations = 0, saves = 0, confirmations = 0, outputs = 0
        var submitted: ClipboardEditSnapshot?
        panel.presentDetailPanel = { window, _ in detail = window }
        panel.onPrepareEdit = { _, reply in preparations += 1; reply(.success(snapshot)) }
        panel.onEdit = { captured, _, _ in saves += 1; submitted = captured }
        panel.confirmDiscardEdits = { _, _ in confirmations += 1; return {} }
        panel.onCopy = { _ in outputs += 1 }; panel.onPaste = { _, _ in outputs += 1 }
        defer { panel.perform(NSSelectorFromString("discardDetail")); panel.dismiss() }
        panel.show(records: [record]); panel.edit(record)
        let originalDetail = try XCTUnwrap(detail)
        let editor: NSTextView = try descendant(originalDetail.contentView) { $0.accessibilityLabel() == "编辑内容" }
        editor.insertText("preserved draft", replacementRange: NSRange(location: 0, length: editor.attributedString().length))
        editor.textStorage?.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 4))
        editor.didChangeText(); editor.setSelectedRange(NSRange(location: 2, length: 4))
        let contents = NSAttributedString(attributedString: editor.attributedString())
        let undo = try XCTUnwrap(editor.undoManager)
        XCTAssertTrue(undo.canUndo)
        var presentations = 0
        let controller = LanguageSettingsController(preferences: .init(preferences: fixture.preferences, allowsChanges: true),
                                                    presentWindow: { _ in presentations += 1 })
        controller.onPreparePresentation = { panel.hidePreservingDraft() }
        controller.present()
        let picker: NSPopUpButton = try view(controller, identifier: "language.selection")
        picker.selectItem(at: 1); controller.saveSelection(); controller.suspend()
        XCTAssertTrue(panel.hasPreservedDraft); XCTAssertTrue(panel.ownsWindow(originalDetail))
        XCTAssertFalse(parent.isVisible); XCTAssertEqual(presentations, 1)
        XCTAssertTrue(editor.attributedString().isEqual(to: contents))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 4))
        XCTAssertTrue(editor.undoManager === undo); XCTAssertTrue(undo.canUndo)
        XCTAssertEqual(preparations, 1); XCTAssertEqual(saves, 0); XCTAssertEqual(confirmations, 0); XCTAssertEqual(outputs, 0)
        panel.show(records: [record])
        XCTAssertTrue(detail === originalDetail); XCTAssertFalse(panel.hasPreservedDraft)
        panel.perform(NSSelectorFromString("saveDetail"))
        XCTAssertEqual(saves, 1); XCTAssertEqual(submitted, snapshot)
        XCTAssertEqual(preparations, 1); XCTAssertEqual(confirmations, 0); XCTAssertEqual(outputs, 0)
    }

    func testCompactWindowKeepsSaveAndCloseReachableWhileLongExplanationScrolls() throws {
        let fixture = LanguagePreferenceFixture()
        let controller = LanguageSettingsController(preferences: .init(preferences: fixture.preferences, allowsChanges: true),
                                                    presentWindow: { _ in XCTFail("Layout test must remain unshown") })
        let window = try XCTUnwrap(controller.window), content = try XCTUnwrap(window.contentView)
        window.setContentSize(NSSize(width: 540, height: 300))
        let status: NSTextField = try view(controller, identifier: "language.status")
        status.stringValue = String(repeating: "A deliberately long translated status remains readable. ", count: 40)
        content.layoutSubtreeIfNeeded()
        let scroll: NSScrollView = try descendant(content) { _ in true }
        XCTAssertTrue(scroll.hasVerticalScroller)
        for identifier in ["language.save", "language.close"] {
            let button: NSButton = try view(controller, identifier: identifier)
            XCTAssertTrue(button.isEnabled)
            let rect = button.convert(button.bounds, to: content)
            XCTAssertTrue(content.bounds.insetBy(dx: -1, dy: -1).contains(rect), "\(identifier) must remain within the compact content area")
            XCTAssertFalse(button.isDescendant(of: scroll))
        }
        XCTAssertFalse(window.isVisible)
    }

    private func view<T: NSView>(_ controller: NSWindowController, identifier: String) throws -> T {
        try descendant(controller.window?.contentView) { $0.accessibilityIdentifier() == identifier }
    }
    private func descendant<T: NSView>(_ parent: NSView?, matching: @escaping (T) -> Bool) throws -> T {
        func find(_ candidate: NSView) -> T? {
            if let typed = candidate as? T, matching(typed) { return typed }
            return candidate.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(parent.flatMap(find))
    }
}
