import AppKit
import Carbon
import XCTest
@testable import ClipShelf

final class KeyboardShortcutConfigurationTests: XCTestCase {
    private func withPreferences(_ body: (UserDefaults) throws -> Void) throws {
        let name = "clipshelf-shortcuts-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        try body(preferences)
    }

    private func event(code: UInt16, flags: NSEvent.ModifierFlags, characters: String = "x", ignoringModifiers: String? = nil,
                       type: NSEvent.EventType = .keyDown) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 1,
                                      windowNumber: 0, context: nil, characters: characters,
                                      charactersIgnoringModifiers: ignoringModifiers ?? characters, isARepeat: false, keyCode: code))
    }

    func testDefaultsAndAllDistinctModifierPairsAreValid() throws {
        let configuration = KeyboardShortcutConfiguration.defaults
        XCTAssertNoThrow(try configuration.validate())
        XCTAssertEqual(configuration.activation, ShortcutChord(keyCode: 9, modifiers: [.command, .shift]))
        XCTAssertEqual(configuration.stack, ShortcutChord(keyCode: 8, modifiers: [.command, .shift]))
        XCTAssertEqual(configuration.previousPinboard, ShortcutChord(keyCode: 123, modifiers: .command))
        XCTAssertEqual(configuration.nextPinboard, ShortcutChord(keyCode: 124, modifiers: .command))
        for quick in ShortcutModifier.allCases {
            for plain in ShortcutModifier.allCases {
                var changed = configuration
                changed.quickPaste = quick; changed.plainText = plain
                if quick == plain {
                    XCTAssertThrowsError(try changed.validate()) { XCTAssertEqual($0 as? KeyboardShortcutError, .ambiguousModifiers) }
                } else { XCTAssertNoThrow(try changed.validate()) }
            }
        }
    }

    func testKeyCodeMatchingIgnoresInputTextAndNonShortcutFlagsButRequiresExactModifiers() throws {
        let chord = ShortcutChord(keyCode: 9, modifiers: [.command, .option, .capsLock, .numericPad, .function])
        XCTAssertEqual(chord.modifiers, [.command, .option])
        let captured = try event(code: 9, flags: [.command, .option, .capsLock, .numericPad, .function], characters: "中")
        XCTAssertTrue(chord.matches(captured))
        XCTAssertEqual(ShortcutChord(event: captured), chord)
        XCTAssertFalse(chord.matches(try event(code: 8, flags: [.command, .option])))
        XCTAssertFalse(chord.matches(try event(code: 9, flags: [.command, .option, .shift])))
        XCTAssertFalse(chord.matches(try event(code: 9, flags: .command)))
        XCTAssertFalse(chord.matches(try event(code: 9, flags: [.command, .option], type: .keyUp)))
    }

    func testCarbonModifiersAndLabelsAreConsistentWithRecordedKeys() throws {
        let chord = ShortcutChord(keyCode: 9, modifiers: [.command, .shift, .control, .option])
        XCTAssertEqual(chord.carbonModifiers, UInt32(cmdKey | shiftKey | controlKey | optionKey))
        XCTAssertEqual(chord.displayName(using: { code, _ in code == 9 ? "v" : nil }), "⌃⌥⇧⌘V")
        XCTAssertEqual(ShortcutChord(keyCode: 123, modifiers: .command).displayName, "⌘←")
        XCTAssertEqual(ShortcutChord(keyCode: 122, modifiers: []).displayName, "F1")
        XCTAssertEqual(ShortcutChord(keyCode: 76, modifiers: .shift).displayName, "⇧⌤")
        XCTAssertTrue(ShortcutChord(keyCode: 83, modifiers: []).displayName.contains("小键盘"))
        XCTAssertNoThrow(try ShortcutChord(keyCode: 93, modifiers: .option).validate())
        XCTAssertTrue(ShortcutChord(keyCode: 65535, modifiers: []).displayName.contains("65535"))
    }

    func testAllFourShortcutPairsMustBeDifferent() {
        let paths: [WritableKeyPath<KeyboardShortcutConfiguration, ShortcutChord>] = [
            \.activation, \.stack, \.previousPinboard, \.nextPinboard
        ]
        for first in paths.indices {
            for second in paths.indices where second > first {
                var configuration = KeyboardShortcutConfiguration.defaults
                configuration[keyPath: paths[second]] = configuration[keyPath: paths[first]]
                XCTAssertThrowsError(try configuration.validate()) { error in
                    guard case .duplicateShortcut = error as? KeyboardShortcutError else { return XCTFail("Unexpected error: \(error)") }
                }
            }
        }
    }

    func testGlobalKeysNeedStrongModifierOrFunctionKeyButLocalKeysMayBeUnmodified() throws {
        for flags: NSEvent.ModifierFlags in [[], .shift] {
            var configuration = KeyboardShortcutConfiguration.defaults
            configuration.activation = ShortcutChord(keyCode: 11, modifiers: flags)
            XCTAssertThrowsError(try configuration.validate())
            configuration = .defaults
            configuration.stack = ShortcutChord(keyCode: 11, modifiers: flags)
            XCTAssertThrowsError(try configuration.validate())
        }
        for flags: NSEvent.ModifierFlags in [.command, .option, .control, [.control, .shift]] {
            var configuration = KeyboardShortcutConfiguration.defaults
            configuration.activation = ShortcutChord(keyCode: 11, modifiers: flags)
            XCTAssertNoThrow(try configuration.validate())
        }
        var configuration = KeyboardShortcutConfiguration.defaults
        configuration.activation = ShortcutChord(keyCode: 122, modifiers: [])
        configuration.stack = ShortcutChord(keyCode: 120, modifiers: .shift)
        configuration.previousPinboard = ShortcutChord(keyCode: 38, modifiers: [])
        configuration.nextPinboard = ShortcutChord(keyCode: 40, modifiers: .shift)
        XCTAssertNoThrow(try configuration.validate())
    }

    func testFixedCommandsAndDynamicOutputShortcutsCannotBeShadowed() {
        let fixed = [
            ShortcutChord(keyCode: 0, modifiers: .command), // Select all.
            ShortcutChord(keyCode: 3, modifiers: .command), // Search.
            ShortcutChord(keyCode: 43, modifiers: .command), // Settings.
            ShortcutChord(keyCode: 45, modifiers: [.command, .shift]), // New board.
            ShortcutChord(keyCode: 123, modifiers: [.command, .option]), // Reorder.
            ShortcutChord(keyCode: 123, modifiers: .shift), // Extend selection.
            ShortcutChord(keyCode: 126, modifiers: [.command, .shift]),
            ShortcutChord(keyCode: 53, modifiers: [.command, .option]), // Escape always cancels.
            ShortcutChord(keyCode: 36, modifiers: []),
            ShortcutChord(keyCode: 76, modifiers: .shift),
            ShortcutChord(keyCode: 48, modifiers: .shift),
            ShortcutChord(keyCode: 49, modifiers: []),
            ShortcutChord(keyCode: 117, modifiers: []),
            ShortcutChord(keyCode: 18, modifiers: .command),
            ShortcutChord(keyCode: 25, modifiers: [.command, .shift])
        ]
        for chord in fixed {
            var configuration = KeyboardShortcutConfiguration.defaults
            configuration.nextPinboard = chord
            XCTAssertThrowsError(try configuration.validate(), chord.displayName)
        }
        var configuration = KeyboardShortcutConfiguration.defaults
        configuration.quickPaste = .option; configuration.plainText = .control
        for chord in [ShortcutChord(keyCode: 18, modifiers: .option),
                      ShortcutChord(keyCode: 25, modifiers: [.option, .control]),
                      ShortcutChord(keyCode: 36, modifiers: .control)] {
            configuration.nextPinboard = chord
            XCTAssertThrowsError(try configuration.validate())
        }
        configuration.nextPinboard = ShortcutChord(keyCode: 18, modifiers: .command)
        XCTAssertNoThrow(try configuration.validate(), "Old Quick Paste combination becomes available after remapping.")
    }

    func testUnknownAndModifierOnlyKeyCodesAreRejected() {
        for code: UInt16 in [52, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 66, 127, 65535] {
            var configuration = KeyboardShortcutConfiguration.defaults
            configuration.nextPinboard = ShortcutChord(keyCode: code, modifiers: .option)
            XCTAssertThrowsError(try configuration.validate()) { XCTAssertEqual($0 as? KeyboardShortcutError, .unsupportedKeyCode(code)) }
        }
    }

    func testSavedSchemaRoundTripsAndTakesPrecedenceOverLegacyPreset() throws {
        try withPreferences { preferences in
            preferences.set(2, forKey: "shortcutPreset")
            var configuration = KeyboardShortcutConfiguration.defaults
            configuration.activation = ShortcutChord(keyCode: 122, modifiers: .control)
            configuration.previousPinboard = ShortcutChord(keyCode: 38, modifiers: .option)
            configuration.quickPaste = .option; configuration.plainText = .control
            try configuration.save(to: preferences)
            let data = try XCTUnwrap(preferences.data(forKey: KeyboardShortcutConfiguration.storageKey))
            XCTAssertEqual(data, try configuration.encodedData())
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["schemaVersion"] as? Int, 1)
            XCTAssertEqual(KeyboardShortcutConfiguration.load(from: preferences), configuration)
            XCTAssertNil(KeyboardShortcutConfiguration.loadResult(from: preferences).warning)
        }
    }

    func testAllLegacyPresetsMigrateReadOnlyWithoutChangingOtherDefaults() throws {
        for (index, expected): (Int, NSEvent.ModifierFlags) in [(.zero, [.command, .shift]), (1, [.control, .option]), (2, [.command, .option])] {
            try withPreferences { preferences in
                preferences.set(index, forKey: "shortcutPreset")
                let result = KeyboardShortcutConfiguration.loadResult(from: preferences)
                var expectedConfiguration = KeyboardShortcutConfiguration.defaults
                expectedConfiguration.activation = ShortcutChord(keyCode: 9, modifiers: expected)
                XCTAssertEqual(result.configuration, expectedConfiguration)
                XCTAssertNil(result.warning)
                XCTAssertNil(preferences.object(forKey: KeyboardShortcutConfiguration.storageKey))
                XCTAssertEqual(preferences.integer(forKey: "shortcutPreset"), index)
            }
        }
        try withPreferences { preferences in
            XCTAssertEqual(KeyboardShortcutConfiguration.load(from: preferences), .defaults)
            XCTAssertNil(KeyboardShortcutConfiguration.loadResult(from: preferences).warning)
        }
    }

    func testMalformedLegacyPresetFallsBackWithWarningWithoutWriting() throws {
        for value: Any in [-1, 3, 1.5, "1", true] {
            try withPreferences { preferences in
                preferences.set(value, forKey: "shortcutPreset")
                let result = KeyboardShortcutConfiguration.loadResult(from: preferences)
                XCTAssertEqual(result.configuration, .defaults)
                XCTAssertNotNil(result.warning)
                XCTAssertNil(preferences.object(forKey: KeyboardShortcutConfiguration.storageKey))
            }
        }
    }

    func testMalformedCurrentConfigurationDoesNotOverwriteOriginalOrUseLegacy() throws {
        let good = try KeyboardShortcutConfiguration.defaults.encodedData()
        var cases: [Data] = [Data("broken".utf8), Data(repeating: 0, count: 16_385)]
        for patch in ["future", "missing", "modifier", "key", "duplicate", "flags"] {
            var value = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [String: Any])
            switch patch {
            case "future": value["schemaVersion"] = 999
            case "missing": value.removeValue(forKey: "plainText")
            case "modifier": value["quickPaste"] = "capsLock"
            case "key": value["activation"] = ["keyCode": 999, "modifierMask": NSEvent.ModifierFlags.command.rawValue]
            case "duplicate": value["stack"] = value["activation"]
            default: value["activation"] = ["keyCode": 9, "modifierMask": NSEvent.ModifierFlags.capsLock.rawValue]
            }
            cases.append(try JSONSerialization.data(withJSONObject: value))
        }
        for stored in cases {
            try withPreferences { preferences in
                preferences.set(1, forKey: "shortcutPreset")
                preferences.set(stored, forKey: KeyboardShortcutConfiguration.storageKey)
                let result = KeyboardShortcutConfiguration.loadResult(from: preferences)
                XCTAssertEqual(result.configuration, .defaults)
                XCTAssertNotNil(result.warning)
                XCTAssertEqual(preferences.data(forKey: KeyboardShortcutConfiguration.storageKey), stored)
            }
        }
        try withPreferences { preferences in
            preferences.set("not data", forKey: KeyboardShortcutConfiguration.storageKey)
            XCTAssertNotNil(KeyboardShortcutConfiguration.loadResult(from: preferences).warning)
            XCTAssertEqual(preferences.string(forKey: KeyboardShortcutConfiguration.storageKey), "not data")
        }
    }

    func testFailedValidationNeverChangesPersistedConfiguration() throws {
        try withPreferences { preferences in
            let original = KeyboardShortcutConfiguration.defaults
            try original.save(to: preferences)
            let data = preferences.data(forKey: KeyboardShortcutConfiguration.storageKey)
            var invalid = original
            invalid.stack = invalid.activation
            XCTAssertThrowsError(try invalid.save(to: preferences))
            XCTAssertEqual(preferences.data(forKey: KeyboardShortcutConfiguration.storageKey), data)
        }
    }

    func testGermanLogicalUndoIsReservedAndFormerANSIPositionIsAvailable() throws {
        let german: ShortcutKeyTranslator = { code, _ in [9: "v", 8: "c", 16: "z", 6: "y"][code] }
        var configuration = KeyboardShortcutConfiguration.defaults
        configuration.previousPinboard = ShortcutChord(keyCode: 16, modifiers: .command)
        XCTAssertEqual(configuration.previousPinboard.displayName(using: german), "⌘Z")
        XCTAssertThrowsError(try configuration.validate(using: german)) { error in
            guard case .fixedCommandConflict = error as? KeyboardShortcutError else { return XCTFail("Unexpected error: \(error)") }
        }
        configuration.previousPinboard = ShortcutChord(keyCode: 6, modifiers: .command)
        XCTAssertEqual(configuration.previousPinboard.displayName(using: german), "⌘Y")
        XCTAssertNoThrow(try configuration.validate(using: german))
        XCTAssertEqual(KeyboardShortcutConfiguration.fixedCommand(for: try event(code: 16, flags: .command, characters: "z")), .undo)
        XCTAssertNil(KeyboardShortcutConfiguration.fixedCommand(for: try event(code: 6, flags: .command, characters: "y")))
    }

    func testLayoutSpecificPunctuationAndShiftedNewBoardUseSharedFixedCommandClassifier() throws {
        let translated: ShortcutKeyTranslator = { code, _ in [9: "v", 8: "c", 46: ",", 43: ";", 38: "n"][code] }
        var configuration = KeyboardShortcutConfiguration.defaults
        configuration.previousPinboard = ShortcutChord(keyCode: 46, modifiers: .command)
        XCTAssertEqual(configuration.previousPinboard.displayName(using: translated), "⌘,")
        XCTAssertThrowsError(try configuration.validate(using: translated))
        XCTAssertEqual(KeyboardShortcutConfiguration.fixedCommand(for: try event(code: 46, flags: .command, characters: ",")), .settings)
        configuration.previousPinboard = ShortcutChord(keyCode: 43, modifiers: .command)
        XCTAssertNoThrow(try configuration.validate(using: translated))
        configuration.previousPinboard = ShortcutChord(keyCode: 38, modifiers: [.command, .shift])
        XCTAssertThrowsError(try configuration.validate(using: translated))
        XCTAssertEqual(KeyboardShortcutConfiguration.fixedCommand(for: try event(code: 38, flags: [.command, .shift], characters: "N")), .newPinboard)
        XCTAssertNil(KeyboardShortcutConfiguration.fixedCommand(for: try event(code: 38, flags: [.command, .option], characters: "n")))
    }

    func testMissingKeyboardLayoutLabelsFallbackButNeverGuessesFixedCommandSafety() throws {
        let unavailable: ShortcutKeyTranslator = { _, _ in nil }
        let chord = ShortcutChord(keyCode: 16, modifiers: .command)
        XCTAssertEqual(chord.displayName(using: unavailable), "⌘Y（ANSI 键位）")
        XCTAssertEqual(ShortcutChord(keyCode: 123, modifiers: .option).displayName(using: unavailable), "⌥←")
        XCTAssertThrowsError(try KeyboardShortcutConfiguration.defaults.validateGlobalShortcut(chord, using: unavailable)) {
            XCTAssertEqual($0 as? KeyboardShortcutError, .keyboardLayoutUnavailable)
        }
        XCTAssertNoThrow(try KeyboardShortcutConfiguration.defaults.validateGlobalShortcut(ShortcutChord(keyCode: 122, modifiers: []), using: unavailable))
        XCTAssertNoThrow(try KeyboardShortcutConfiguration.defaults.validateGlobalShortcut(ShortcutChord(keyCode: 16, modifiers: .control), using: unavailable))
        // Real event characters remain authoritative if the layout service is unavailable.
        XCTAssertEqual(KeyboardShortcutConfiguration.fixedCommand(for: try event(code: 16, flags: .command, characters: "z")), .undo)
    }

    func testGlobalRevalidationRejectsNewLayoutConflictAndKeepsOtherBindingsUsable() throws {
        let configuration = KeyboardShortcutConfiguration.defaults
        let before: ShortcutKeyTranslator = { code, _ in [9: "v", 8: "c"][code] }
        let after: ShortcutKeyTranslator = { code, _ in [9: "n", 8: "c"][code] }
        XCTAssertNoThrow(try configuration.validateGlobalShortcut(configuration.activation, using: before))
        XCTAssertThrowsError(try configuration.validateGlobalShortcut(configuration.activation, using: after))
        XCTAssertNoThrow(try configuration.validateGlobalShortcut(configuration.stack, using: after))
        XCTAssertThrowsError(try configuration.validateGlobalShortcut(ShortcutChord(keyCode: 18, modifiers: .command), using: after))
        XCTAssertThrowsError(try configuration.validateGlobalShortcut(ShortcutChord(keyCode: 11, modifiers: []), using: after))
        XCTAssertThrowsError(try configuration.validateGlobalShortcut(ShortcutChord(keyCode: 36, modifiers: .shift), using: after))
    }

    func testCommandSpecificLayoutUsesActualModifiersForDisplayValidationAndEventRouting() throws {
        let dvorakCommand: ShortcutKeyTranslator = { code, modifiers in
            guard code == 45 else { return [9: "v", 8: "c"][code] }
            if modifiers.contains(.command) { return modifiers.contains(.shift) ? "N" : "n" }
            return "b"
        }
        let plain = ShortcutChord(keyCode: 45, modifiers: [])
        let command = ShortcutChord(keyCode: 45, modifiers: .command)
        let shifted = ShortcutChord(keyCode: 45, modifiers: [.command, .shift])
        XCTAssertEqual(plain.displayName(using: dvorakCommand), "B")
        XCTAssertEqual(command.displayName(using: dvorakCommand), "⌘N")
        XCTAssertEqual(shifted.displayName(using: dvorakCommand), "⇧⌘N")
        XCTAssertThrowsError(try KeyboardShortcutConfiguration.defaults.validateGlobalShortcut(command, using: dvorakCommand))
        XCTAssertThrowsError(try KeyboardShortcutConfiguration.defaults.validateGlobalShortcut(shifted, using: dvorakCommand))
        let actual = try event(code: 45, flags: .command, characters: "n", ignoringModifiers: "b")
        XCTAssertEqual(KeyboardShortcutConfiguration.fixedCommand(for: actual), .newText)
        let actualShifted = try event(code: 45, flags: [.command, .shift], characters: "N", ignoringModifiers: "B")
        XCTAssertEqual(KeyboardShortcutConfiguration.fixedCommand(for: actualShifted), .newPinboard)
        // Do not fall back to a reserved unmodified letter when the real command
        // character is different and not itself a fixed command.
        let inverse = try event(code: 45, flags: .command, characters: "b", ignoringModifiers: "n")
        XCTAssertNil(KeyboardShortcutConfiguration.fixedCommand(for: inverse))
    }

    @MainActor func testInstalledDvorakCommandLayoutDataWithoutSelectingInputSource() throws {
        let query = [kTISPropertyInputSourceID as String: "com.apple.keylayout.DVORAK-QWERTYCMD"] as CFDictionary
        let sources = TISCreateInputSourceList(query, true).takeRetainedValue()
        guard CFArrayGetCount(sources) > 0, let source = CFArrayGetValueAtIndex(sources, 0) else {
            throw XCTSkip("Dvorak–Qwerty Command layout is not installed.")
        }
        let input = unsafeBitCast(source, to: TISInputSource.self)
        let pointer = try XCTUnwrap(TISGetInputSourceProperty(input, kTISPropertyUnicodeKeyLayoutData))
        let data = unsafeBitCast(pointer, to: CFData.self) as Data
        let translate = ShortcutKeyboardLayout.translator(layoutData: data, keyboardType: UInt32(LMGetKbdType()))
        XCTAssertEqual(translate(45, []), "b")
        XCTAssertEqual(translate(45, .command), "n")
        // This system layout emits a lower-case command character even with
        // Shift; fixed command routing intentionally normalizes letter case.
        XCTAssertEqual(translate(45, [.command, .shift])?.lowercased(), "n")
        XCTAssertEqual(ShortcutChord(keyCode: 45, modifiers: .command).displayName(using: translate), "⌘N")
        XCTAssertThrowsError(try KeyboardShortcutConfiguration.defaults.validateGlobalShortcut(ShortcutChord(keyCode: 45, modifiers: .command), using: translate))
        XCTAssertThrowsError(try KeyboardShortcutConfiguration.defaults.validateGlobalShortcut(ShortcutChord(keyCode: 45, modifiers: [.command, .shift]), using: translate))
    }
}
