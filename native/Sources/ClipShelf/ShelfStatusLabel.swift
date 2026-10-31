import AppKit

/// Routine capture status lives in the tooltip. Errors and operation feedback
/// remain visible, including assignments from asynchronous panel callbacks.
@MainActor
final class ShelfStatusLabel: NSTextField {
    var routineStatus: String? { didSet { updateVisibility() } }
    override var stringValue: String { didSet { updateVisibility() } }
    /// Lets the shelf collapse its footer whenever no status needs attention.
    var onVisibilityChange: (() -> Void)?

    private func updateVisibility() {
        toolTip = stringValue
        isHidden = stringValue.isEmpty || stringValue == routineStatus
        onVisibilityChange?()
    }
}
