import Foundation

/// Freezes the application at the physical gesture without reading AX in a key callback.
@MainActor
final class StackPasteGestureCoordinator<Target> {
    private let ownProcessIdentifier: pid_t
    private let isAvailable: () -> Bool
    private let foregroundPID: () -> pid_t?
    private let captureTarget: () -> Target?
    private let targetPID: (Target) -> pid_t
    private var generation = UUID()

    init(ownProcessIdentifier: pid_t,
         isAvailable: @escaping () -> Bool,
         foregroundPID: @escaping () -> pid_t?,
         captureTarget: @escaping () -> Target?,
         targetPID: @escaping (Target) -> pid_t) {
        self.ownProcessIdentifier = ownProcessIdentifier
        self.isAvailable = isAvailable
        self.foregroundPID = foregroundPID
        self.captureTarget = captureTarget
        self.targetPID = targetPID
    }

    func invalidate() { generation = UUID() }

    func prepare(perform: @escaping (Target, @escaping () -> Bool) -> Void) -> (() -> Void)? {
        let capturedGeneration = generation
        guard isAvailable(), let pid = foregroundPID(), pid != ownProcessIdentifier,
              generation == capturedGeneration else { return nil }
        let isCurrent: () -> Bool = { [weak self] in
            guard let self, self.generation == capturedGeneration, self.isAvailable() else { return false }
            let matches = self.foregroundPID() == pid
            // Availability and foreground providers may themselves invalidate context.
            return matches && self.generation == capturedGeneration
        }
        var started = false
        return { [weak self] in
            // A delayed action belongs to one physical gesture, including failed attempts.
            guard !started else { return }
            started = true
            guard let self, isCurrent(), let target = self.captureTarget() else { return }
            guard isCurrent(), self.targetPID(target) == pid, isCurrent() else { return }
            perform(target, isCurrent)
        }
    }
}
