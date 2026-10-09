import AppKit
import XCTest
@testable import ClipShelf

final class ShortcutRecorderTests: XCTestCase {
    @MainActor private func event(_ code: UInt16, flags: NSEvent.ModifierFlags = [],
                                  type: NSEvent.EventType = .keyDown, repeatKey: Bool = false,
                                  characters: String = "") -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 1,
                        windowNumber: 0, context: nil, characters: characters,
                        charactersIgnoringModifiers: characters, isARepeat: repeatKey, keyCode: code)!
    }

    @MainActor private func recorder() -> ShortcutRecorderView {
        ShortcutRecorderView(title: "打开剪贴板", chord: ShortcutChord(keyCode: 9, modifiers: [.command, .shift]))
    }

    @MainActor func testProgrammaticUpdateDoesNotEmitAndIdleCapturePassesThrough() {
        let view = recorder()
        var emitted = 0
        view.onChange = { _ in emitted += 1 }
        let replacement = ShortcutChord(keyCode: 8, modifiers: [.control, .option])
        view.chord = replacement
        XCTAssertEqual(view.title, replacement.displayName)
        XCTAssertFalse(view.capture(event(0, flags: .command)))
        XCTAssertFalse(view.captureRegisteredShortcut(replacement))
        XCTAssertEqual(emitted, 0)
        XCTAssertFalse(view.isRecording)
    }

    @MainActor func testBeginningCoordinatesOtherRecordersBeforeTakingOwnership() {
        let first = recorder(), second = recorder()
        first.beginRecording()
        var begins = 0
        second.onBeginRecording = {
            XCTAssertFalse(second.isRecording)
            first.cancelRecording()
            begins += 1
        }
        second.beginRecording()
        second.beginRecording()
        XCTAssertFalse(first.isRecording)
        XCTAssertTrue(second.isRecording)
        XCTAssertEqual(begins, 1)
        XCTAssertTrue(second.accessibilityHelp()?.contains("Escape") == true)
    }

    @MainActor func testCaptureUsesPhysicalCodeAndNormalizedModifiersThenEndsBeforeCallback() {
        let view = recorder()
        var captured: [ShortcutChord] = []
        view.onChange = {
            XCTAssertFalse(view.isRecording)
            XCTAssertEqual(view.chord, $0)
            captured.append($0)
        }
        view.beginRecording()
        XCTAssertTrue(view.capture(event(0, flags: [.command, .control, .option, .shift, .capsLock, .numericPad, .function], characters: "z")))
        XCTAssertEqual(captured, [ShortcutChord(keyCode: 0, modifiers: [.command, .control, .option, .shift])])
        XCTAssertFalse(view.capture(event(8, flags: .command)))
        XCTAssertEqual(captured.count, 1)
    }

    @MainActor func testUnmodifiedEscapeCancelsWithoutChangingDraft() {
        let view = recorder(), old = recorder().chord
        var emitted = false
        view.onChange = { _ in emitted = true }
        view.beginRecording()
        XCTAssertTrue(view.capture(event(53, flags: .capsLock)))
        XCTAssertFalse(view.isRecording)
        XCTAssertEqual(view.chord, old)
        XCTAssertFalse(emitted)
        XCTAssertEqual(view.title, old.displayName)
    }

    @MainActor func testModifiedEscapeIsARecordableDraft() {
        let view = recorder()
        view.beginRecording()
        XCTAssertTrue(view.capture(event(53, flags: .command)))
        XCTAssertFalse(view.isRecording)
        XCTAssertEqual(view.chord, ShortcutChord(keyCode: 53, modifiers: .command))
    }

    @MainActor func testModifierChangesAndRepeatedKeyDownNeverCommit() {
        let view = recorder(), old = recorder().chord
        var emitted = false
        view.onChange = { _ in emitted = true }
        view.beginRecording()
        XCTAssertTrue(view.capture(event(55, flags: [.command, .option], type: .flagsChanged)))
        XCTAssertTrue(view.title.contains("⌘"))
        XCTAssertTrue(view.title.contains("⌥"))
        XCTAssertTrue(view.capture(event(55, flags: .command)))
        XCTAssertTrue(view.capture(event(8, flags: .command, repeatKey: true)))
        XCTAssertTrue(view.capture(event(53, repeatKey: true)))
        XCTAssertFalse(view.capture(event(8, flags: .command, type: .keyUp)))
        XCTAssertEqual(view.chord, old)
        XCTAssertTrue(view.isRecording)
        XCTAssertFalse(emitted)
        XCTAssertTrue(view.capture(event(55, type: .flagsChanged)))
        XCTAssertFalse(view.title.contains("⌘"))
    }

    @MainActor func testRegisteredShortcutCompletesOnlyActiveRecording() {
        let view = recorder()
        let registered = ShortcutChord(keyCode: 8, modifiers: [.command, .shift])
        var emitted: [ShortcutChord] = []
        view.onChange = { emitted.append($0) }
        view.beginRecording()
        XCTAssertTrue(view.captureRegisteredShortcut(registered))
        XCTAssertEqual(view.chord, registered)
        XCTAssertFalse(view.isRecording)
        XCTAssertFalse(view.captureRegisteredShortcut(registered))
        XCTAssertEqual(emitted, [registered])
    }

    @MainActor func testFocusLossCancelsAndPlainSpaceOrReturnStartsRecording() {
        let view = recorder()
        for code: UInt16 in [49, 36, 76] {
            view.keyDown(with: event(code, repeatKey: true))
            XCTAssertFalse(view.isRecording)
            view.keyDown(with: event(code))
            XCTAssertTrue(view.isRecording)
            XCTAssertTrue(view.resignFirstResponder())
            XCTAssertFalse(view.isRecording)
        }
    }

    @MainActor func testDisabledButtonDoesNotStartRecording() {
        let view = recorder()
        var began = false
        view.onBeginRecording = { began = true }
        view.isEnabled = false
        view.beginRecording()
        XCTAssertFalse(view.isRecording)
        XCTAssertFalse(began)
    }
}
