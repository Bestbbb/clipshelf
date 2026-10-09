import AppKit

/// Routes interaction boundaries without owning application state or system services.
@MainActor
final class ApplicationInteractionLifecycle {
    private let allowsInteraction: () -> Bool
    private let cancelPendingPaste: () -> Void
    private let cancelSuggestions: () -> Void
    private let hideHistory: () -> Void
    private let hideStack: () -> Void
    private var spaceCenter: NotificationCenter?
    private var spaceObserver: NSObjectProtocol?
    private var observationGeneration: UInt64 = 0

    init(allowsInteraction: @escaping () -> Bool,
         cancelPendingPaste: @escaping () -> Void,
         cancelSuggestions: @escaping () -> Void,
         hideHistory: @escaping () -> Void,
         hideStack: @escaping () -> Void) {
        self.allowsInteraction = allowsInteraction
        self.cancelPendingPaste = cancelPendingPaste
        self.cancelSuggestions = cancelSuggestions
        self.hideHistory = hideHistory
        self.hideStack = hideStack
    }

    var isAllowed: Bool { allowsInteraction() }

    func prepareForInvocation(_ action: () -> Void) {
        guard isAllowed else { return }
        cancelPendingPaste()
        cancelSuggestions()
        // Cancellation callbacks may reenter the app and suspend the session.
        guard isAllowed else { return }
        action()
    }

    func invalidateContext() {
        cancelPendingPaste()
        cancelSuggestions()
        hideHistory()
        hideStack()
    }

    func observeSpaces(in center: NotificationCenter) {
        stopObserving()
        let generation = observationGeneration
        spaceCenter = center
        spaceObserver = center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.observationGeneration == generation else { return }
                self.invalidateContext()
            }
        }
    }

    func stopObserving() {
        observationGeneration &+= 1
        if let spaceObserver { spaceCenter?.removeObserver(spaceObserver) }
        spaceObserver = nil
        spaceCenter = nil
    }

    deinit {
        if let spaceObserver { spaceCenter?.removeObserver(spaceObserver) }
    }
}
