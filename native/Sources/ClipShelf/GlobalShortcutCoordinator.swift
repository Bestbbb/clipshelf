import ClipShelfLocalization
import AppKit
import Carbon

@MainActor protocol GlobalHotKeyRegistration: AnyObject {
    var onPressed: (() -> Void)? { get set }
    func register(keyCode: UInt32, modifiers: UInt32) -> OSStatus
    func unregister()
}

extension GlobalHotKey: GlobalHotKeyRegistration {}

enum GlobalShortcutAction: CaseIterable, Hashable {
    case activation, stack
    var title: String { self == .activation ? L10n.text("打开剪贴板") : L10n.text("顺序粘贴 Stack") }
}

struct GlobalShortcutRegistrationError: LocalizedError {
    let action: GlobalShortcutAction
    let chord: ShortcutChord
    let status: OSStatus
    var errorDescription: String? {
        L10n.text("\(action.title)的快捷键 \(chord.displayName) 无法注册（\(status)），可能已被系统或其他应用占用。")
    }
}

/// Reuses registrations by chord. A failed replacement never releases an existing working chord.
@MainActor final class GlobalShortcutCoordinator {
    typealias Factory = @MainActor () -> any GlobalHotKeyRegistration
    var onPressed: ((GlobalShortcutAction, ShortcutChord) -> Void)?
    private let makeRegistration: Factory
    private var handles: [ShortcutChord: any GlobalHotKeyRegistration] = [:]
    private var actions: [ShortcutChord: GlobalShortcutAction] = [:]

    init(makeRegistration: @escaping Factory = { GlobalHotKey() }) {
        self.makeRegistration = makeRegistration
    }

    var activeBindings: [GlobalShortcutAction: ShortcutChord] {
        Dictionary(uniqueKeysWithValues: actions.map { ($0.value, $0.key) })
    }

    /// Startup retains whichever shortcuts can be registered and reports every unavailable action.
    func start(_ configuration: KeyboardShortcutConfiguration) throws -> [GlobalShortcutRegistrationError] {
        try configuration.validate()
        precondition(handles.isEmpty, "Start is only valid before registration or after stop")
        var failures: [GlobalShortcutRegistrationError] = []
        for (action, chord) in bindings(configuration) {
            do {
                handles[chord] = try register(chord, for: action)
                actions[chord] = action
            } catch let error as GlobalShortcutRegistrationError { failures.append(error) }
        }
        return failures
    }

    func apply(_ configuration: KeyboardShortcutConfiguration) throws {
        try configuration.validate()
        let desired = bindings(configuration)
        var staged: [ShortcutChord: any GlobalHotKeyRegistration] = [:]
        do {
            for (action, chord) in desired where handles[chord] == nil {
                staged[chord] = try register(chord, for: action)
            }
        } catch {
            staged.values.forEach { $0.unregister() }
            throw error
        }

        let previous = handles
        handles = Dictionary(uniqueKeysWithValues: desired.map { _, chord in (chord, previous[chord] ?? staged[chord]!) })
        actions = Dictionary(uniqueKeysWithValues: desired.map { ($0.1, $0.0) })
        for (chord, handle) in previous where handles[chord] == nil { handle.unregister() }
    }

    /// Registration is a point-in-time check, not proof of hardware delivery or a reservation for Save.
    func probe(_ configuration: KeyboardShortcutConfiguration) throws {
        try configuration.validate()
        var staged: [any GlobalHotKeyRegistration] = []
        defer { staged.forEach { $0.unregister() } }
        for (action, chord) in bindings(configuration) where handles[chord] == nil {
            staged.append(try register(chord, for: action))
        }
    }

    /// A layout change may turn a previously safe physical key into a reserved character command.
    /// Only affected bindings are removed; valid existing registrations are never released.
    func reconcileAfterInputSourceChange(_ configuration: KeyboardShortcutConfiguration,
                                          validating validator: ((ShortcutChord) throws -> Void)? = nil) -> [String] {
        let desired = bindings(configuration)
        let wanted = Set(desired.map(\.1))
        for chord in Array(handles.keys) where !wanted.contains(chord) {
            handles.removeValue(forKey: chord)?.unregister(); actions.removeValue(forKey: chord)
        }
        var failures: [String] = []
        for (action, chord) in desired {
            do {
                if let validator { try validator(chord) }
                else { try configuration.validateGlobalShortcut(chord) }
            } catch {
                handles.removeValue(forKey: chord)?.unregister(); actions.removeValue(forKey: chord)
                failures.append("\(action.title)：\(error.localizedDescription)")
                continue
            }
            do {
                if handles[chord] == nil { handles[chord] = try register(chord, for: action) }
                actions[chord] = action
            } catch { failures.append(error.localizedDescription) }
        }
        return failures
    }

    /// Encoding and validation precede registration, and system conflicts leave all preferences unchanged.
    func applyAndSave(_ configuration: KeyboardShortcutConfiguration, alwaysPlainText: Bool,
                      preferences: UserDefaults) throws {
        let data = try configuration.encodedData()
        try apply(configuration)
        preferences.set(data, forKey: KeyboardShortcutConfiguration.storageKey)
        preferences.set(alwaysPlainText, forKey: "alwaysPlainText")
    }

    func stop() {
        let previous = handles
        handles = [:]; actions = [:]
        previous.values.forEach { $0.unregister() }
    }

    private func bindings(_ configuration: KeyboardShortcutConfiguration) -> [(GlobalShortcutAction, ShortcutChord)] {
        [(.activation, configuration.activation), (.stack, configuration.stack)]
    }

    private func register(_ chord: ShortcutChord, for action: GlobalShortcutAction) throws -> any GlobalHotKeyRegistration {
        let handle = makeRegistration()
        handle.onPressed = { [weak self, weak handle] in
            guard let self, let handle, let current = self.handles[chord], current === handle,
                  let action = self.actions[chord] else { return }
            ValidationTrace.emit(.hotkeyReceived, state: .requested, shortcut: action == .activation ? .activation : .stack)
            self.onPressed?(action, chord)
        }
        let result = handle.register(keyCode: UInt32(chord.keyCode), modifiers: chord.carbonModifiers)
        ValidationTrace.emit(.hotkeyRegistered, state: result == noErr ? .ready : .unavailable,
                             status: result, shortcut: action == .activation ? .activation : .stack)
        guard result == noErr else {
            handle.unregister()
            throw GlobalShortcutRegistrationError(action: action, chord: chord, status: result)
        }
        return handle
    }
}
