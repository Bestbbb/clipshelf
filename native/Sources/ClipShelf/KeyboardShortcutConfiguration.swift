import AppKit
import Carbon

typealias ShortcutKeyTranslator = (UInt16, NSEvent.ModifierFlags) -> String?

/// A snapshot avoids mixing two keyboard layouts during a single validation.
enum ShortcutKeyboardLayout {
    static func currentTranslator() -> ShortcutKeyTranslator {
        // TextInputSources is documented as main-thread-only for UI applications.
        // Background callers can inject a captured translator; do not dispatch
        // synchronously to the main thread and risk deadlocking a worker.
        guard Thread.isMainThread,
              let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return { _, _ in nil } }
        let data = unsafeBitCast(pointer, to: CFData.self) as Data
        return translator(layoutData: data, keyboardType: UInt32(LMGetKbdType()))
    }

    static func translator(layoutData data: Data, keyboardType: UInt32) -> ShortcutKeyTranslator {
        return { code, modifiers in
            data.withUnsafeBytes { bytes in
                guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
                var state: UInt32 = 0
                var count = 0
                var characters = [UniChar](repeating: 0, count: 8)
                // Command-dependent layouts (for example Dvorak–Qwerty ⌘)
                // change the character itself. A zero modifier state would let
                // a reserved ⌘N pass validation as an unrelated plain letter.
                let carbonState = ShortcutChord(keyCode: code, modifiers: modifiers).carbonModifiers >> 8
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), carbonState, keyboardType,
                                            OptionBits(kUCKeyTranslateNoDeadKeysMask), &state,
                                            characters.count, &count, &characters)
                guard status == noErr, count > 0 else { return nil }
                let result = String(utf16CodeUnits: characters, count: count)
                guard result.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
                return result
            }
        }
    }
}

enum FixedShortcutCommand: Equatable {
    case search, settings, pause, newText, newPinboard, open, reveal, copy, undo, selectAll, edit, rename, cut, paste, quit
}

enum ShortcutModifier: String, Codable, CaseIterable, Sendable {
    case command, shift, control, option

    var eventFlags: NSEvent.ModifierFlags {
        switch self {
        case .command: return .command
        case .shift: return .shift
        case .control: return .control
        case .option: return .option
        }
    }

    var displayName: String {
        switch self {
        case .command: return "⌘ Command"
        case .shift: return "⇧ Shift"
        case .control: return "⌃ Control"
        case .option: return "⌥ Option"
        }
    }

    var symbol: String { String(displayName.prefix(1)) }
}

/// Stores physical key codes, not characters produced by the current input method.
/// Caps Lock, Fn and the numeric-pad event marker are not shortcut modifiers.
struct ShortcutChord: Codable, Hashable, Sendable {
    let keyCode: UInt16
    private let modifierMask: UInt

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        modifierMask = Self.normalizedModifiers(modifiers).rawValue
    }

    init(event: NSEvent) {
        self.init(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierMask) }

    static func normalizedModifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.command, .shift, .control, .option])
    }

    func matches(_ event: NSEvent) -> Bool {
        event.type == .keyDown && keyCode == event.keyCode && modifiers == Self.normalizedModifiers(event.modifierFlags)
    }

    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.command) { value |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { value |= UInt32(shiftKey) }
        if modifiers.contains(.control) { value |= UInt32(controlKey) }
        if modifiers.contains(.option) { value |= UInt32(optionKey) }
        return value
    }

    var displayName: String { displayName(using: ShortcutKeyboardLayout.currentTranslator()) }

    func displayName(using translate: ShortcutKeyTranslator) -> String {
        let prefix = [ShortcutModifier.control, .option, .shift, .command]
            .filter { modifiers.contains($0.eventFlags) }.map(\.symbol).joined()
        guard let fallback = Self.keyNames[keyCode] else { return prefix + "未知按键（\(keyCode)）" }
        guard isPrintableKey else { return prefix + fallback }
        guard let character = translate(keyCode, modifiers), !character.isEmpty else { return prefix + fallback + "（ANSI 键位）" }
        return prefix + character.uppercased()
    }

    var isFunctionKey: Bool { Self.functionKeyCodes.contains(keyCode) }
    var isPrintableKey: Bool { Self.printableKeyCodes.contains(keyCode) }

    func validate() throws {
        guard Self.keyNames[keyCode] != nil else { throw KeyboardShortcutError.unsupportedKeyCode(keyCode) }
    }

    private enum CodingKeys: String, CodingKey { case keyCode, modifierMask }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try values.decode(UInt16.self, forKey: .keyCode)
        modifierMask = try values.decode(UInt.self, forKey: .modifierMask)
        guard Self.normalizedModifiers(modifiers).rawValue == modifierMask else {
            throw KeyboardShortcutError.unsupportedModifiers
        }
        try validate()
    }

    // Non-printing keys use stable labels. Printable keys use the live layout;
    // these physical ANSI/ISO/JIS names are explicitly labelled fallback text.
    private static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        10: "§", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "−", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 48: "⇥", 49: "空格", 50: "`", 51: "⌫", 53: "⎋",
        64: "F17", 65: "小键盘 .", 67: "小键盘 ×", 69: "小键盘 +", 71: "小键盘 Clear",
        72: "音量 +", 73: "音量 −", 74: "静音", 75: "小键盘 ÷", 76: "⌤", 78: "小键盘 −",
        79: "F18", 80: "F19", 81: "小键盘 =", 82: "小键盘 0", 83: "小键盘 1", 84: "小键盘 2",
        85: "小键盘 3", 86: "小键盘 4", 87: "小键盘 5", 88: "小键盘 6", 89: "小键盘 7",
        90: "F20", 91: "小键盘 8", 92: "小键盘 9", 93: "¥", 94: "_", 95: "小键盘 ,",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 102: "英数",
        103: "F11", 104: "かな", 105: "F13", 106: "F16", 107: "F14", 109: "F10",
        110: "菜单", 111: "F12", 113: "F15", 114: "Help", 115: "↖", 116: "⇞", 117: "⌦",
        118: "F4", 119: "↘", 120: "F2", 121: "⇟", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
    private static let functionKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
                                                      103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
    private static let printableKeyCodes = Set<UInt16>([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17,
                                                       18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35,
                                                       37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 50, 93, 94])
}

enum KeyboardShortcutError: Error, LocalizedError, Equatable {
    case unsupportedKeyCode(UInt16)
    case unsupportedModifiers
    case unsupportedVersion(Int)
    case duplicateShortcut(String, String)
    case fixedCommandConflict(String, String)
    case invalidGlobalShortcut(String)
    case ambiguousModifiers
    case keyboardLayoutUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedKeyCode(let code): return "不支持按键代码 \(code)，请重新录制快捷键。"
        case .unsupportedModifiers: return "快捷键包含不支持的修饰键，请重新录制。"
        case .unsupportedVersion(let version): return "无法读取快捷键设置版本 \(version)。"
        case .duplicateShortcut(let first, let second): return "“\(first)”与“\(second)”使用了相同快捷键，请为它们选择不同组合。"
        case .fixedCommandConflict(let action, let shortcut): return "“\(action)”的 \(shortcut) 与固定应用内命令冲突，请换一个组合。"
        case .invalidGlobalShortcut(let action): return "“\(action)”是全局快捷键，请包含 Command、Control 或 Option，或使用 F1–F20。"
        case .ambiguousModifiers: return "Quick Paste 和纯文本不能使用同一个修饰键，否则无法区分普通与纯文本输出。"
        case .keyboardLayoutUnavailable: return "暂时无法读取当前键盘布局，无法确认此 Command 组合是否覆盖固定命令；请在键盘布局可用后重试。"
        }
    }
}

struct KeyboardShortcutConfiguration: Codable, Equatable, Sendable {
    static let storageKey = "keyboardShortcutConfiguration"
    static let schemaVersion = 1

    var activation: ShortcutChord
    var stack: ShortcutChord
    var previousPinboard: ShortcutChord
    var nextPinboard: ShortcutChord
    var quickPaste: ShortcutModifier
    var plainText: ShortcutModifier

    static let defaults = Self(
        activation: ShortcutChord(keyCode: UInt16(kVK_ANSI_V), modifiers: [.command, .shift]),
        stack: ShortcutChord(keyCode: UInt16(kVK_ANSI_C), modifiers: [.command, .shift]),
        previousPinboard: ShortcutChord(keyCode: UInt16(kVK_LeftArrow), modifiers: .command),
        nextPinboard: ShortcutChord(keyCode: UInt16(kVK_RightArrow), modifiers: .command),
        quickPaste: .command, plainText: .shift
    )

    init(activation: ShortcutChord, stack: ShortcutChord, previousPinboard: ShortcutChord,
         nextPinboard: ShortcutChord, quickPaste: ShortcutModifier, plainText: ShortcutModifier) {
        self.activation = activation; self.stack = stack
        self.previousPinboard = previousPinboard; self.nextPinboard = nextPinboard
        self.quickPaste = quickPaste; self.plainText = plainText
    }

    func validate() throws { try validate(using: ShortcutKeyboardLayout.currentTranslator()) }

    func validate(using translate: ShortcutKeyTranslator) throws {
        guard quickPaste != plainText else { throw KeyboardShortcutError.ambiguousModifiers }
        let actions = [("激活面板", activation), ("激活 Paste Stack", stack),
                       ("上一个分组", previousPinboard), ("下一个分组", nextPinboard)]
        var seen: [ShortcutChord: String] = [:]
        for (index, (name, chord)) in actions.enumerated() {
            if let previous = seen[chord] { throw KeyboardShortcutError.duplicateShortcut(previous, name) }
            seen[chord] = name
            try validateChord(chord, name: name, isGlobal: index < 2, using: translate)
        }
    }

    func validateGlobalShortcut(_ chord: ShortcutChord) throws {
        try validateGlobalShortcut(chord, using: ShortcutKeyboardLayout.currentTranslator())
    }

    func validateGlobalShortcut(_ chord: ShortcutChord, using translate: ShortcutKeyTranslator) throws {
        guard quickPaste != plainText else { throw KeyboardShortcutError.ambiguousModifiers }
        try validateChord(chord, name: "全局快捷键", isGlobal: true, using: translate)
    }

    private func validateChord(_ chord: ShortcutChord, name: String, isGlobal: Bool, using translate: ShortcutKeyTranslator) throws {
        try chord.validate()
        if isGlobal, chord.modifiers.intersection([.command, .control, .option]).isEmpty, !chord.isFunctionKey {
            throw KeyboardShortcutError.invalidGlobalShortcut(name)
        }
        if reservedChords().contains(chord) || chord.keyCode == UInt16(kVK_Escape) {
            throw KeyboardShortcutError.fixedCommandConflict(name, chord.displayName(using: translate))
        }
        if chord.isPrintableKey, chord.modifiers == .command || chord.modifiers == [.command, .shift] {
            guard let character = translate(chord.keyCode, chord.modifiers), !character.isEmpty else {
                throw KeyboardShortcutError.keyboardLayoutUnavailable
            }
            if Self.fixedCommand(character: character, modifiers: chord.modifiers) != nil {
                throw KeyboardShortcutError.fixedCommandConflict(name, chord.displayName(using: translate))
            }
        }
    }

    /// Fixed commands take precedence over configurable board chords, including
    /// after the keyboard layout changes while the panel is open.
    static func fixedCommand(for event: NSEvent) -> FixedShortcutCommand? {
        guard event.type == .keyDown else { return nil }
        let character: String
        // characters includes the actual Command-specific layout mapping;
        // charactersIgnoringModifiers may instead contain the unmodified letter.
        if let value = event.characters, !value.isEmpty { character = value }
        else if let value = event.charactersIgnoringModifiers, !value.isEmpty { character = value }
        else if let value = ShortcutKeyboardLayout.currentTranslator()(event.keyCode, event.modifierFlags) { character = value }
        else { return nil }
        return fixedCommand(character: character, modifiers: ShortcutChord.normalizedModifiers(event.modifierFlags))
    }

    static func fixedCommand(character: String, modifiers: NSEvent.ModifierFlags) -> FixedShortcutCommand? {
        let value = character.lowercased()
        if modifiers == [.command, .shift] { return value == "n" ? .newPinboard : nil }
        guard modifiers == .command else { return nil }
        switch value {
        case "f": return .search
        case ",": return .settings
        case "t": return .pause
        case "n": return .newText
        case "o": return .open
        case "g": return .reveal
        case "c": return .copy
        case "z": return .undo
        case "a": return .selectAll
        case "e": return .edit
        case "r": return .rename
        case "x": return .cut
        case "v": return .paste
        case "q": return .quit
        default: return nil
        }
    }

    /// Validate/encode before registering global shortcuts so a registration failure
    /// never requires rolling back already-written preferences.
    func encodedData() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    func save(to defaults: UserDefaults) throws {
        defaults.set(try encodedData(), forKey: Self.storageKey)
    }

    static func load(from defaults: UserDefaults) -> Self { loadResult(from: defaults).configuration }

    /// Loading is read-only. A valid legacy preset is migrated in memory; only an
    /// explicit successful save replaces preferences, including malformed data.
    static func loadResult(from defaults: UserDefaults) -> (configuration: Self, warning: String?) {
        if let stored = defaults.object(forKey: storageKey) {
            guard let data = stored as? Data, data.count <= 16_384 else {
                return (.defaults, "保存的快捷键设置无法读取，暂时使用默认值；原设置尚未覆盖。")
            }
            do { return (try JSONDecoder().decode(Self.self, from: data), nil) }
            catch { return (.defaults, "保存的快捷键设置无法读取，暂时使用默认值；原设置尚未覆盖。\(error.localizedDescription)") }
        }
        guard let legacy = defaults.object(forKey: "shortcutPreset") else { return (.defaults, nil) }
        guard let number = legacy as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              [0.0, 1.0, 2.0].contains(number.doubleValue) else {
            return (.defaults, "旧版快捷键预设无效，暂时使用默认值。")
        }
        var configuration = Self.defaults
        let flags: [NSEvent.ModifierFlags] = [[.command, .shift], [.control, .option], [.command, .option]]
        configuration.activation = ShortcutChord(keyCode: UInt16(kVK_ANSI_V), modifiers: flags[number.intValue])
        return (configuration, nil)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, activation, stack, previousPinboard, nextPinboard, quickPaste, plainText
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.schemaVersion else { throw KeyboardShortcutError.unsupportedVersion(version) }
        activation = try values.decode(ShortcutChord.self, forKey: .activation)
        stack = try values.decode(ShortcutChord.self, forKey: .stack)
        previousPinboard = try values.decode(ShortcutChord.self, forKey: .previousPinboard)
        nextPinboard = try values.decode(ShortcutChord.self, forKey: .nextPinboard)
        quickPaste = try values.decode(ShortcutModifier.self, forKey: .quickPaste)
        plainText = try values.decode(ShortcutModifier.self, forKey: .plainText)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.schemaVersion, forKey: .schemaVersion)
        try values.encode(activation, forKey: .activation); try values.encode(stack, forKey: .stack)
        try values.encode(previousPinboard, forKey: .previousPinboard); try values.encode(nextPinboard, forKey: .nextPinboard)
        try values.encode(quickPaste, forKey: .quickPaste); try values.encode(plainText, forKey: .plainText)
    }

    private func reservedChords() -> Set<ShortcutChord> {
        var values = Set<ShortcutChord>()
        func add(_ codes: [UInt16], _ modifiers: NSEvent.ModifierFlags) {
            for code in codes { values.insert(ShortcutChord(keyCode: code, modifiers: modifiers)) }
        }
        // Printable fixed commands are classified by the current layout above;
        // reserving their ANSI key codes would block unrelated non-US shortcuts.
        add([123, 124], [.command, .option]) // Manual ordering.
        add([125, 126], .command)
        add([125, 126], [.command, .shift])
        add([123, 124], [])
        add([123, 124], .shift)
        add([36, 76, 48, 49, 51, 117], []) // Return, keypad Enter, Tab, preview, Delete.
        add([48], .shift)
        add([36, 76], plainText.eventFlags)
        let numberCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        add(numberCodes, quickPaste.eventFlags)
        add(numberCodes, quickPaste.eventFlags.union(plainText.eventFlags))
        return values
    }
}
