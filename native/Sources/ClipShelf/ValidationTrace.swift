import Foundation

/// Explicit diagnostics. The schema cannot carry clipboard contents, titles,
/// paths, record identifiers or arbitrary error messages. Unflagged launches emit nothing.
enum ValidationTrace {
    enum Shortcut: String, Codable, Sendable { case activation, stack }
    enum Event: String, Codable, Sendable {
        case hotkeyRegistered = "hotkey_registered", hotkeyReceived = "hotkey_received"
        case invocationBlocked = "invocation_blocked"
        case invocation, reopen
        case panelShown = "panel_shown", panelDismissed = "panel_dismissed"
        case panelEntranceStarted = "panel_entrance_started"
        case panelEntranceCompleted = "panel_entrance_completed"
        case panelEntranceCancelled = "panel_entrance_cancelled"
        case workspaceActivated = "workspace_activated", workspaceHidesPanel = "workspace_hides_panel"
        case outsideClick = "outside_click", interactionCancelled = "interaction_cancelled"
        case targetCaptured = "target_captured", pastePrepared = "paste_prepared"
        case focusChecked = "focus_checked", pasteDispatch = "paste_dispatch"
        case pasteCompleted = "paste_completed", pasteCancelledByActivation = "paste_cancelled_by_activation"
    }

    enum State: String, Codable, Sendable {
        case requested, visible, hidden, captured, unavailable, prepared, ready
        case differentWindow = "different_window", differentElement = "different_element"
        case dispatched, copiedOnly = "copied_only", cancelled, failed, busy
    }

    enum Failure: String, Codable, Sendable {
        case writeFailed = "write_failed", restoreUnavailable = "restore_unavailable"
        case activationFailed = "activation_failed", windowRaiseFailed = "window_raise_failed"
        case eventCreationFailed = "event_creation_failed", contextChanged = "context_changed"
        case clipboardChanged = "clipboard_changed", changedForeground = "changed_foreground"
        case permissionOrProcessUnavailable = "permission_or_process_unavailable"
        case deadline, waitCancelled = "wait_cancelled", explicitCancellation = "explicit_cancellation"
        case finalReadinessChanged = "final_readiness_changed"
    }

    private struct Entry: Encodable {
        let timestamp: TimeInterval
        let event: Event
        let pid: Int32?
        let bundleID: String?
        let hasTargetWindow: Bool?
        let hasInputElement: Bool?
        let state: State?
        let failure: Failure?
        let status: Int32?
        let shortcut: Shortcut?
    }

    static let enabled = isEnabled(arguments: CommandLine.arguments)

    static func isEnabled(arguments: [String]) -> Bool {
        arguments.contains("--diagnostic-trace") ||
            (arguments.contains("--validation") && arguments.contains("--validation-trace"))
    }

    /// Pure formatting seam; tests never need to write stderr or invoke system input.
    static func encodedLine(event: Event, timestamp: TimeInterval, pid: Int32? = nil,
                            bundleID: String? = nil, hasTargetWindow: Bool? = nil,
                            hasInputElement: Bool? = nil, state: State? = nil,
                            failure: Failure? = nil, status: Int32? = nil, shortcut: Shortcut? = nil) -> Data? {
        guard timestamp.isFinite else { return nil }
        let entry = Entry(timestamp: timestamp, event: event, pid: pid, bundleID: bundleID,
                          hasTargetWindow: hasTargetWindow, hasInputElement: hasInputElement,
                          state: state, failure: failure, status: status, shortcut: shortcut)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(entry) else { return nil }
        data.append(0x0a)
        return data
    }

    static func emit(_ event: Event, pid: Int32? = nil, bundleID: String? = nil,
                     hasTargetWindow: Bool? = nil, hasInputElement: Bool? = nil,
                     state: State? = nil, failure: Failure? = nil, status: Int32? = nil, shortcut: Shortcut? = nil) {
        guard enabled, let data = encodedLine(event: event, timestamp: Date().timeIntervalSince1970,
            pid: pid, bundleID: bundleID, hasTargetWindow: hasTargetWindow,
            hasInputElement: hasInputElement, state: state, failure: failure, status: status, shortcut: shortcut) else { return }
        try? FileHandle.standardError.write(contentsOf: data)
    }
}
