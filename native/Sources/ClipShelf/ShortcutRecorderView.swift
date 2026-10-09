import AppKit

/// Records a draft shortcut. Validation, registration and persistence belong to settings.
@MainActor final class ShortcutRecorderView: NSButton {
    var chord: ShortcutChord {
        didSet { updatePresentation() }
    }
    private(set) var isRecording = false
    var onChange: ((ShortcutChord) -> Void)?
    var onBeginRecording: (() -> Void)?

    private let actionTitle: String
    private var heldModifiers: NSEvent.ModifierFlags = []
    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    init(title: String, chord: ShortcutChord) {
        actionTitle = title
        self.chord = chord
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(startRecording)
        setAccessibilityLabel(title)
        updatePresentation()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { isEnabled }

    func beginRecording() {
        guard isEnabled, !isRecording else { return }
        onBeginRecording?()
        isRecording = true
        heldModifiers = []
        updatePresentation()
        if let window, !window.makeFirstResponder(self) { cancelRecording() }
    }

    func cancelRecording() {
        isRecording = false
        heldModifiers = []
        updatePresentation()
    }

    /// Returns true only for events consumed by an active recording session.
    @discardableResult func capture(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        if event.type == .flagsChanged {
            heldModifiers = ShortcutChord.normalizedModifiers(event.modifierFlags)
            updatePresentation()
            return true
        }
        guard event.type == .keyDown else { return false }
        guard !event.isARepeat, !Self.modifierKeyCodes.contains(event.keyCode) else { return true }
        if event.keyCode == 53, ShortcutChord.normalizedModifiers(event.modifierFlags).isEmpty {
            cancelRecording()
        } else {
            commit(ShortcutChord(event: event))
        }
        return true
    }

    /// Carbon may consume a registered global shortcut before a local key event arrives.
    @discardableResult func captureRegisteredShortcut(_ chord: ShortcutChord) -> Bool {
        guard isRecording else { return false }
        commit(chord)
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isEnabled, window?.firstResponder === self, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        if capture(event) { return true }
        if ShortcutChord.normalizedModifiers(event.modifierFlags).isEmpty,
           [UInt16(36), 49, 76].contains(event.keyCode) {
            if !event.isARepeat { beginRecording() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if capture(event) { return }
        if ShortcutChord.normalizedModifiers(event.modifierFlags).isEmpty,
           [UInt16(36), 49, 76].contains(event.keyCode) {
            if !event.isARepeat { beginRecording() }
            return
        }
        super.keyDown(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        if !capture(event) { super.flagsChanged(with: event) }
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { cancelRecording() }
        return resigned
    }

    @objc private func startRecording() { beginRecording() }

    private func commit(_ value: ShortcutChord) {
        isRecording = false
        heldModifiers = []
        chord = value
        onChange?(value)
    }

    private func updatePresentation() {
        let modifierText: String = [
            (NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")
        ].compactMap { heldModifiers.contains($0.0) ? $0.1 : nil }.joined()
        title = isRecording ? (modifierText.isEmpty ? "按下快捷键…" : "\(modifierText) + 按键…") : chord.displayName
        let help = isRecording ? "正在录制\(actionTitle)快捷键。按 Escape 取消；只按修饰键不会保存。" : "按空格、Return 或点击以录制\(actionTitle)快捷键。"
        toolTip = help
        setAccessibilityValue(isRecording ? "正在录制，\(title)" : chord.displayName)
        setAccessibilityHelp(help)
    }
}
