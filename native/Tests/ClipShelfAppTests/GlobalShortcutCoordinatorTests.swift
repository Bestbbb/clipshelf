import AppKit
import Carbon
import XCTest
@testable import ClipShelf

@MainActor private final class FakeGlobalRegistration: GlobalHotKeyRegistration {
    var onPressed: (() -> Void)?
    var unregisterCount = 0
    var arguments: (UInt32, UInt32)?
    let result: (UInt32, UInt32) -> OSStatus
    init(result: @escaping (UInt32, UInt32) -> OSStatus) { self.result = result }
    func register(keyCode: UInt32, modifiers: UInt32) -> OSStatus {
        arguments = (keyCode, modifiers)
        return result(keyCode, modifiers)
    }
    func unregister() { unregisterCount += 1 }
}

@MainActor private final class RegistrationRig {
    var handles: [FakeGlobalRegistration] = []
    var failingChords: Set<ShortcutChord> = []
    lazy var coordinator = GlobalShortcutCoordinator { [unowned self] in
        let handle = FakeGlobalRegistration { [unowned self] keyCode, modifiers in
            self.failingChords.contains { UInt32($0.keyCode) == keyCode && $0.carbonModifiers == modifiers } ? OSStatus(eventHotKeyExistsErr) : noErr
        }
        handles.append(handle)
        return handle
    }
}

@MainActor final class GlobalShortcutCoordinatorTests: XCTestCase {
    private func replacement() -> KeyboardShortcutConfiguration {
        var configuration = KeyboardShortcutConfiguration.defaults
        configuration.activation = ShortcutChord(keyCode: UInt16(kVK_ANSI_V), modifiers: [.control, .option])
        configuration.stack = ShortcutChord(keyCode: UInt16(kVK_ANSI_C), modifiers: [.control, .option])
        return configuration
    }

    func testStartupKeepsAvailableShortcutAndReportsOtherAction() throws {
        let rig = RegistrationRig(), configuration = KeyboardShortcutConfiguration.defaults
        rig.failingChords = [configuration.activation]
        let failures = try rig.coordinator.start(configuration)
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.action, .activation)
        XCTAssertEqual(failures.first?.chord, configuration.activation)
        XCTAssertEqual(rig.coordinator.activeBindings, [.stack: configuration.stack])
        var fired: [GlobalShortcutAction] = []
        rig.coordinator.onPressed = { fired.append($0); _ = $1 }
        rig.handles[0].onPressed?(); rig.handles[1].onPressed?()
        XCTAssertEqual(fired, [.stack])
        rig.failingChords = []
        try rig.coordinator.apply(configuration)
        XCTAssertEqual(rig.coordinator.activeBindings.count, 2)
        XCTAssertEqual(rig.handles.count, 3)
        XCTAssertEqual(rig.handles[1].unregisterCount, 0)
        rig.coordinator.stop()
    }

    func testSwappingActionsReusesHandlesAndDispatchesTheirNewMeaning() throws {
        let rig = RegistrationRig(), defaults = KeyboardShortcutConfiguration.defaults
        XCTAssertTrue(try rig.coordinator.start(defaults).isEmpty)
        try rig.coordinator.apply(defaults)
        XCTAssertEqual(rig.handles.count, 2)
        var swapped = defaults
        swapped.activation = defaults.stack; swapped.stack = defaults.activation
        try rig.coordinator.apply(swapped)
        XCTAssertEqual(rig.handles.count, 2)
        XCTAssertEqual(rig.handles.map(\.unregisterCount), [0, 0])
        var fired: [GlobalShortcutAction] = []
        rig.coordinator.onPressed = { fired.append($0); _ = $1 }
        rig.handles[0].onPressed?(); rig.handles[1].onPressed?()
        XCTAssertEqual(fired, [.stack, .activation])
        rig.coordinator.stop()
    }

    func testFailedSecondRegistrationRollsBackStagedOnlyAndLeavesPreferencesUnchanged() throws {
        let rig = RegistrationRig(), defaults = KeyboardShortcutConfiguration.defaults, changed = replacement()
        _ = try rig.coordinator.start(defaults)
        let domain = "clipshelf-shortcut-commit-test-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { preferences.removePersistentDomain(forName: domain); rig.coordinator.stop() }
        try defaults.save(to: preferences)
        preferences.set(false, forKey: "alwaysPlainText")
        let before = preferences.data(forKey: KeyboardShortcutConfiguration.storageKey)
        rig.failingChords = [changed.stack]
        XCTAssertThrowsError(try rig.coordinator.applyAndSave(changed, alwaysPlainText: true, preferences: preferences))
        XCTAssertEqual(preferences.data(forKey: KeyboardShortcutConfiguration.storageKey), before)
        XCTAssertFalse(preferences.bool(forKey: "alwaysPlainText"))
        XCTAssertEqual(rig.coordinator.activeBindings, [.activation: defaults.activation, .stack: defaults.stack])
        XCTAssertEqual(rig.handles.map(\.unregisterCount), [0, 0, 1, 1])
        var fired: [GlobalShortcutAction] = []
        rig.coordinator.onPressed = { fired.append($0); _ = $1 }
        rig.handles.forEach { $0.onPressed?() }
        XCTAssertEqual(fired, [.activation, .stack])
    }

    func testSuccessfulReplacementSavesTogetherAndRetiredCallbacksCannotFire() throws {
        let rig = RegistrationRig(), changed = replacement()
        _ = try rig.coordinator.start(.defaults)
        let domain = "clipshelf-shortcut-commit-test-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { preferences.removePersistentDomain(forName: domain) }
        try rig.coordinator.applyAndSave(changed, alwaysPlainText: true, preferences: preferences)
        XCTAssertEqual(KeyboardShortcutConfiguration.load(from: preferences), changed)
        XCTAssertTrue(preferences.bool(forKey: "alwaysPlainText"))
        XCTAssertEqual(rig.handles.map(\.unregisterCount), [1, 1, 0, 0])
        var fired: [GlobalShortcutAction] = []
        rig.coordinator.onPressed = { fired.append($0); _ = $1 }
        rig.handles.forEach { $0.onPressed?() }
        XCTAssertEqual(fired, [.activation, .stack])
        rig.coordinator.stop()
        rig.handles.forEach { $0.onPressed?() }
        XCTAssertEqual(fired, [.activation, .stack])
        XCTAssertTrue(rig.coordinator.activeBindings.isEmpty)
    }

    func testInvalidConfigurationDoesNotTouchRegistrationsOrStoredValues() throws {
        let rig = RegistrationRig()
        _ = try rig.coordinator.start(.defaults)
        var invalid = KeyboardShortcutConfiguration.defaults
        invalid.stack = invalid.activation
        XCTAssertThrowsError(try rig.coordinator.apply(invalid))
        XCTAssertEqual(rig.handles.count, 2)
        XCTAssertTrue(rig.handles.allSatisfy { $0.unregisterCount == 0 })
        rig.coordinator.stop()
    }

    func testProbeNeverChangesBindingsAndSaveRechecksAConflictThatAppearedLater() throws {
        let rig = RegistrationRig(), defaults = KeyboardShortcutConfiguration.defaults, changed = replacement()
        _ = try rig.coordinator.start(defaults)
        try rig.coordinator.probe(changed)
        XCTAssertEqual(rig.coordinator.activeBindings, [.activation: defaults.activation, .stack: defaults.stack])
        XCTAssertEqual(rig.handles.map(\.unregisterCount), [0, 0, 1, 1])
        rig.failingChords = [changed.stack]
        XCTAssertThrowsError(try rig.coordinator.apply(changed))
        XCTAssertEqual(rig.handles.map(\.unregisterCount), [0, 0, 1, 1, 1, 1])
        XCTAssertEqual(rig.coordinator.activeBindings, [.activation: defaults.activation, .stack: defaults.stack])
        rig.coordinator.stop()
    }

    func testLayoutChangeDisablesOnlyInvalidBindingAndCanRestoreItLater() throws {
        let rig = RegistrationRig(), configuration = KeyboardShortcutConfiguration.defaults
        _ = try rig.coordinator.start(configuration)
        let failures = rig.coordinator.reconcileAfterInputSourceChange(configuration) { chord in
            if chord == configuration.activation { throw NSError(domain: "SyntheticLayoutConflict", code: 1) }
        }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(rig.coordinator.activeBindings, [.stack: configuration.stack])
        XCTAssertEqual(rig.handles.map(\.unregisterCount), [1, 0])
        var fired: [GlobalShortcutAction] = []
        rig.coordinator.onPressed = { fired.append($0); _ = $1 }
        rig.handles.forEach { $0.onPressed?() }
        XCTAssertEqual(fired, [.stack])
        rig.failingChords = [configuration.activation]
        XCTAssertEqual(rig.coordinator.reconcileAfterInputSourceChange(configuration, validating: { _ in }).count, 1)
        XCTAssertEqual(rig.handles[1].unregisterCount, 0)
        rig.failingChords = []
        XCTAssertTrue(rig.coordinator.reconcileAfterInputSourceChange(configuration, validating: { _ in }).isEmpty)
        XCTAssertEqual(rig.coordinator.activeBindings.count, 2)
        XCTAssertEqual(rig.handles[1].unregisterCount, 0)
        rig.coordinator.stop()
    }
}
