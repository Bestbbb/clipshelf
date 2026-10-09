import AppKit
import ClipShelfLocalization

@MainActor
extension NSAlert {
    @discardableResult
    func runLocalizedModal() -> NSApplication.ModalResponse {
        layout()
        InterfaceLayout.apply(to: window.contentView)
        return runModal()
    }

    func beginLocalizedSheetModal(for parent: NSWindow, completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
        layout()
        InterfaceLayout.apply(to: window.contentView)
        beginSheetModal(for: parent, completionHandler: completionHandler)
    }
}
