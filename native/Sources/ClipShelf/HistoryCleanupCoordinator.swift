import ClipShelfCore
import Foundation

enum HistoryCleanupRequest: Equatable, Sendable {
    case clearHistory
    case retention(days: Int)
    case automatic(days: Int)

    var isAutomatic: Bool { if case .automatic = self { return true }; return false }
}

enum HistoryCleanupFlowError: LocalizedError, Equatable {
    case invalidRequest
    case unavailable
    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "清理期限无效；永久保留不会执行清理。"
        case .unavailable: return "清理流程暂不可用，现有内容与保留期限未改变。"
        }
    }
}

/// Main-thread workflow only. The caller supplies background Core operations and owns
/// preferences: onSuccess is the sole boundary at which a retention change can be saved.
@MainActor
final class HistoryCleanupCoordinator {
    enum StartDisposition: Equatable { case started, deferred, ignored }
    var onPrepare: ((HistoryCleanupRequest, @escaping (Result<HistoryCleanupPlan, Error>) -> Void) -> Void)?
    var onCommit: ((HistoryCleanupPlan, @escaping (Result<HistoryCleanupResult, Error>) -> Void) -> Void)?
    var confirm: ((HistoryCleanupSummary, HistoryCleanupRequest, @escaping (Bool) -> Void) -> (() -> Void))?
    var isExternalMutationBusy: (() -> Bool)?
    var onBusyChanged: ((Bool) -> Void)?
    var onSuccess: ((HistoryCleanupResult, HistoryCleanupRequest) -> Void)?
    var onFailure: ((Error, HistoryCleanupRequest) -> Void)?
    var onCancelled: ((HistoryCleanupRequest) -> Void)?
    private(set) var isBusy = false
    var isCommitting: Bool { active?.phase == .committing }

    private enum Phase { case preparing, confirming, waitingToCommit, committing }
    private struct Operation {
        let id: UUID
        let request: HistoryCleanupRequest
        var phase: Phase
        var plan: HistoryCleanupPlan?
    }
    private enum Outcome { case success(HistoryCleanupResult), failure(Error), cancelled }
    private var active: Operation?
    private var cancelConfirmation: (() -> Void)?
    private var pendingManual: HistoryCleanupRequest?
    private var deferredAutomatic: HistoryCleanupRequest?
    private var deliveringCallbacks = false
    private var terminated = false

    @discardableResult
    func start(_ request: HistoryCleanupRequest) -> StartDisposition {
        guard !terminated else { return .ignored }
        switch request {
        case .automatic(let days) where days <= 0:
            deferredAutomatic = nil
            if let operation = active, operation.request.isAutomatic, operation.phase != .committing {
                finish(operation.id, outcome: .cancelled)
            }
            return .ignored
        case .retention(let days) where days <= 0:
            deliverFailure(HistoryCleanupFlowError.invalidRequest, request: request)
            return .ignored
        default: break
        }
        if deliveringCallbacks {
            enqueue(request)
            return .deferred
        }
        if let operation = active {
            if request.isAutomatic {
                // Repeated timer ticks for the active automatic request do not schedule a second pass.
                if operation.request != request { deferredAutomatic = request }
                return operation.request == request ? .ignored : .deferred
            }
            guard operation.request.isAutomatic else { return .ignored }
            guard pendingManual == nil else { return .ignored }
            pendingManual = request
            deferredAutomatic = nil
            if operation.phase != .committing { finish(operation.id, outcome: .cancelled) }
            return .deferred
        }
        if pendingManual != nil {
            enqueue(request)
            resumeDeferred()
            return .deferred
        }
        guard isExternalMutationBusy?() != true else {
            enqueue(request)
            return .deferred
        }
        begin(request)
        return .started
    }

    /// The app calls this after an external mutation/session suspension ends. No polling timer
    /// is owned here; at most one queued manual and the latest automatic request are retained.
    func resumeDeferred() {
        guard !terminated, !deliveringCallbacks, isExternalMutationBusy?() != true else { return }
        if let operation = active {
            if operation.phase == .waitingToCommit { commit(operation.id) }
            return
        }
        if let request = pendingManual {
            pendingManual = nil
            begin(request)
        } else if let request = deferredAutomatic {
            deferredAutomatic = nil
            begin(request)
        }
    }

    /// False means the write has already started. Its success/failure callback will still run;
    /// closing a confirmation or a window cannot roll back an already dispatched transaction.
    @discardableResult
    func cancelPending() -> Bool {
        let waiting = pendingManual
        pendingManual = nil; deferredAutomatic = nil
        guard let operation = active else {
            if let waiting { deliverCancelled(waiting) }
            return true
        }
        guard operation.phase != .committing else { return false }
        finish(operation.id, outcome: .cancelled)
        return true
    }

    /// The app must defer termination while this returns false. Once true, late preparation
    /// and sheet replies are permanently ignored and new requests cannot start.
    @discardableResult
    func terminate() -> Bool {
        guard !isCommitting else { return false }
        terminated = true
        _ = cancelPending()
        return true
    }

    private func begin(_ request: HistoryCleanupRequest) {
        guard !terminated, active == nil else { return }
        let id = UUID()
        active = Operation(id: id, request: request, phase: .preparing)
        setBusy(true)
        guard active?.id == id, !terminated else { return } // onBusyChanged may cancel/reenter.
        guard let onPrepare, onCommit != nil else { finish(id, outcome: .failure(HistoryCleanupFlowError.unavailable)); return }
        onPrepare(request) { [weak self] response in
            guard let self, self.active?.id == id, self.active?.phase == .preparing, !self.terminated else { return }
            switch response {
            case .failure(let error): self.finish(id, outcome: .failure(error))
            case .success(let plan):
                self.active?.plan = plan
                if request.isAutomatic { self.commit(id) }
                else { self.showConfirmation(id, plan: plan, request: request) }
            }
        }
    }

    private func showConfirmation(_ id: UUID, plan: HistoryCleanupPlan, request: HistoryCleanupRequest) {
        guard active?.id == id else { return }
        guard let confirm else { finish(id, outcome: .failure(HistoryCleanupFlowError.unavailable)); return }
        active?.phase = .confirming
        let cancel = confirm(plan.summary, request) { [weak self] accepted in
            guard let self, self.active?.id == id, self.active?.phase == .confirming, !self.terminated else { return }
            if accepted { self.commit(id) }
            else { self.finish(id, outcome: .cancelled) }
        }
        // An injected/native presenter can respond synchronously. Never install its handle on
        // a different operation or a phase which has already submitted the proof.
        if active?.id == id, active?.phase == .confirming { cancelConfirmation = cancel }
        else { cancel() }
    }

    private func commit(_ id: UUID) {
        guard let operation = active, operation.id == id, operation.phase != .committing,
              let plan = operation.plan, !terminated else { return }
        active?.phase = .waitingToCommit
        let cancel = cancelConfirmation; cancelConfirmation = nil; cancel?()
        guard active?.id == id, !terminated else { return }
        guard isExternalMutationBusy?() != true else { return }
        guard let onCommit else { finish(id, outcome: .failure(HistoryCleanupFlowError.unavailable)); return }
        active?.phase = .committing
        onCommit(plan) { [weak self] response in
            guard let self, self.active?.id == id, self.active?.phase == .committing else { return }
            switch response {
            case .success(let result): self.finish(id, outcome: .success(result))
            case .failure(let error): self.finish(id, outcome: .failure(error))
            }
        }
    }

    private func finish(_ id: UUID, outcome: Outcome) {
        guard let operation = active, operation.id == id else { return }
        active = nil
        let cancel = cancelConfirmation; cancelConfirmation = nil
        deliveringCallbacks = true
        cancel?() // An old sheet's false reply can no longer affect the retired operation.
        switch outcome {
        case .success(let result):
            if case .retention = operation.request { deferredAutomatic = nil }
            onSuccess?(result, operation.request)
        case .failure(let error):
            // A failure needs a fresh request (and manual confirmation), never an implicit retry.
            deferredAutomatic = nil
            onFailure?(error, operation.request)
        case .cancelled: onCancelled?(operation.request)
        }
        deliveringCallbacks = false
        setBusy(false)
        resumeDeferred()
    }

    private func enqueue(_ request: HistoryCleanupRequest) {
        if request.isAutomatic { deferredAutomatic = request }
        else if pendingManual == nil { pendingManual = request }
    }
    private func setBusy(_ value: Bool) {
        guard isBusy != value else { return }
        isBusy = value; onBusyChanged?(value)
    }
    private func deliverFailure(_ error: Error, request: HistoryCleanupRequest) {
        // Invalid input cannot disturb an operation which is already running.
        guard !deliveringCallbacks else { return }
        deliveringCallbacks = true; onFailure?(error, request); deliveringCallbacks = false
        resumeDeferred()
    }
    private func deliverCancelled(_ request: HistoryCleanupRequest) {
        guard !deliveringCallbacks else { return }
        deliveringCallbacks = true; onCancelled?(request); deliveringCallbacks = false
        resumeDeferred()
    }
}
