import ClipShelfLocalization
import Foundation

enum AppUpdateEvent {
    case checking, found(String), downloading(String), downloaded(String), extracting(String)
    case waitingForQuit(String), installing(String), noCompatibleUpdate, cancelled
    case failed(String), cycleFinished
}

/// A fake implements this boundary without constructing Sparkle, accessing its
/// defaults, displaying its user driver, or making network requests.
@MainActor
protocol AppUpdateDriver: AnyObject {
    var canCheckForUpdates: Bool { get }
    var sessionInProgress: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var allowsAutomaticUpdates: Bool { get }
    var lastUpdateCheckDate: Date? { get }
    var onChange: (() -> Void)? { get set }
    var onEvent: ((AppUpdateEvent) -> Void)? { get set }
    var mayCheck: (() -> Bool)? { get set }
    var postponeRestart: ((String, @escaping () -> Void) -> Bool)? { get set }
    func start() throws
    func checkForUpdates()
}

@MainActor
final class AppUpdateCoordinator {
    typealias DriverFactory = @MainActor (UpdateConfiguration) throws -> any AppUpdateDriver
    private let configuration: UpdateConfiguration?
    private let factory: DriverFactory
    private var driver: (any AppUpdateDriver)?
    private var startAttempted = false
    private var started = false
    private var stopped = false
    private var pendingRestart: (() -> Void)?
    private var pendingVersion: String?
    private var lastFingerprint: Fingerprint?
    private(set) var status: String
    var onChange: (() -> Void)?
    /// Root supplies session suspension, termination decisions and active write
    /// transactions. The AppKit applicationShouldTerminate gate remains final.
    var isRestartBlocked: (() -> Bool)?

    convenience init(bundle: Bundle = .main, allowsBackgroundIntegrations: Bool,
                     factory: @escaping DriverFactory = { try SparkleUpdateDriver(configuration: $0) }) {
        self.init(configuration: Result { try UpdateConfiguration.read(bundle: bundle, allowsBackgroundIntegrations: allowsBackgroundIntegrations) }, factory: factory)
    }
    init(configuration: Result<UpdateConfiguration, Error>, factory: @escaping DriverFactory) {
        self.factory = factory
        switch configuration {
        case .success(let value): self.configuration = value; status = L10n.text("尚未检查更新。")
        case .failure(let error): self.configuration = nil; status = error.localizedDescription
        }
    }

    var isAvailable: Bool { configuration != nil && started && !stopped }
    var isBusy: Bool { isAvailable && (driver?.sessionInProgress == true || pendingRestart != nil) }
    var canCheck: Bool { isAvailable && driver?.canCheckForUpdates == true && pendingRestart == nil && isRestartBlocked?() != true }
    var canRetryPendingRestart: Bool { isAvailable && pendingRestart != nil && isRestartBlocked?() != true }
    var hasPendingRestart: Bool { pendingRestart != nil }
    var menuActionTitle: String { hasPendingRestart ? L10n.text("继续安装更新…") : L10n.text("检查更新…") }
    var canPerformMenuAction: Bool { hasPendingRestart ? canRetryPendingRestart : canCheck }
    var automaticallyChecksForUpdates: Bool { isAvailable && driver?.automaticallyChecksForUpdates == true }
    var automaticallyDownloadsUpdates: Bool { isAvailable && driver?.automaticallyDownloadsUpdates == true }
    var canChangeAutomaticDownloads: Bool { isAvailable && driver?.allowsAutomaticUpdates == true }
    var lastUpdateCheckDate: Date? { isAvailable ? driver?.lastUpdateCheckDate : nil }
    var versionDescription: String { configuration.map { L10n.text("\($0.version)（构建 \($0.build)）") } ?? L10n.text("当前版本未启用更新") }

    /// Call only after Root installs its lifetime guard. Invalid and isolated
    /// builds never invoke the driver factory, even when the user opens settings.
    func start() {
        guard !startAttempted, !stopped, let configuration else { refreshAvailability(); return }
        startAttempted = true
        do {
            let candidate = try factory(configuration)
            driver = candidate
            candidate.onChange = { [weak self] in self?.refreshAvailability() }
            candidate.onEvent = { [weak self] event in self?.receive(event) }
            candidate.mayCheck = { [weak self] in
                guard let self else { return false }
                return !self.stopped && self.isRestartBlocked?() != true
            }
            candidate.postponeRestart = { [weak self] version, continuation in
                guard let self, !self.stopped else { return true }
                guard self.isRestartBlocked?() == true else { return false }
                // A second delegate notification must not discard the first
                // continuation or run either continuation more than once.
                if self.pendingRestart == nil {
                    self.pendingRestart = continuation; self.pendingVersion = version
                }
                self.status = L10n.text("更新 \(version) 已准备好；请完成当前操作后重试安装重启。")
                self.refreshAvailability()
                return true
            }
            try candidate.start()
            started = true
        } catch {
            driver?.onChange = nil; driver?.onEvent = nil
            driver?.mayCheck = { false }; driver?.postponeRestart = { _, _ in true }
            status = L10n.text("更新器未能启动：\(error.localizedDescription)")
        }
        refreshAvailability()
    }

    func checkForUpdates() {
        guard canCheck else { refreshAvailability(); return }
        if driver?.sessionInProgress != true { status = L10n.text("正在检查更新…") }
        driver?.checkForUpdates()
        refreshAvailability()
    }
    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard isAvailable else { return }
        driver?.automaticallyChecksForUpdates = enabled
        refreshAvailability()
    }
    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        guard canChangeAutomaticDownloads else { return }
        driver?.automaticallyDownloadsUpdates = enabled
        refreshAvailability()
    }
    func retryPendingRestart() {
        guard canRetryPendingRestart, let continuation = pendingRestart else { refreshAvailability(); return }
        let version = pendingVersion ?? ""
        pendingRestart = nil; pendingVersion = nil
        status = L10n.text("正在请求安装更新 \(version)；退出仍需完成草稿与存储检查。")
        // Consume before invoking: Sparkle/Root may synchronously reenter us.
        refreshAvailability()
        continuation()
    }
    /// Only applicationWillTerminate calls this. A declined quit request must
    /// leave the updater and its native preferences intact.
    func stop() {
        guard !stopped else { return }
        stopped = true; pendingRestart = nil; pendingVersion = nil
        driver?.onChange = nil; driver?.onEvent = nil
        driver?.mayCheck = { false }; driver?.postponeRestart = { _, _ in true }
        if configuration != nil { status = L10n.text("应用正在退出，更新操作已停止。") }
        refreshAvailability()
    }

    private func receive(_ event: AppUpdateEvent) {
        guard !stopped, driver != nil else { return }
        switch event {
        case .checking: status = L10n.text("正在检查更新…")
        case .found(let version): status = L10n.text("发现可用更新 \(version)。")
        case .downloading(let version): status = L10n.text("正在下载更新 \(version)…")
        case .downloaded(let version): status = L10n.text("更新 \(version) 已下载，正在验证并准备。")
        case .extracting(let version): status = L10n.text("正在解包更新 \(version)…")
        case .waitingForQuit(let version): status = L10n.text("更新 \(version) 已准备好，将在正常退出后安装。")
        case .installing(let version): status = L10n.text("正在准备安装更新 \(version)；退出仍需完成草稿与存储检查。")
        case .noCompatibleUpdate: status = L10n.text("未发现此 Mac 可用的更新。")
        case .cancelled:
            pendingRestart = nil; pendingVersion = nil
            status = L10n.text("更新操作已取消。")
        case .failed(let message):
            pendingRestart = nil; pendingVersion = nil
            status = L10n.text("更新未完成：\(message)")
        case .cycleFinished:
            // A successful cycle can mean the offer was dismissed/skipped or
            // an update is staged. It is never evidence that we are up to date.
            if status == L10n.text("正在检查更新…") { status = L10n.text("本次更新检查已结束。") }
        }
        refreshAvailability()
    }
    private struct Fingerprint: Equatable {
        let status: String
        let available, busy, canCheck, canRetry, automaticChecks, automaticDownloads, canChangeDownloads: Bool
        let lastCheck: Date?
    }
    /// Safe to call from Root's render/onChange: unchanged state never reenters it.
    func refreshAvailability() {
        let value = Fingerprint(status: status, available: isAvailable, busy: isBusy, canCheck: canCheck,
                                canRetry: canRetryPendingRestart, automaticChecks: automaticallyChecksForUpdates,
                                automaticDownloads: automaticallyDownloadsUpdates, canChangeDownloads: canChangeAutomaticDownloads,
                                lastCheck: lastUpdateCheckDate)
        guard value != lastFingerprint else { return }
        lastFingerprint = value
        onChange?()
    }
}

/// Keep application lifetime flags and the updater's visible controls in sync at
/// the assignment itself, including `defer` and a declined termination decision.
/// The weak observer does not initialize an updater or hold an application alive.
@MainActor
@propertyWrapper
final class UpdateAvailabilityFlag {
    var wrappedValue: Bool {
        didSet { if wrappedValue != oldValue { updater?.refreshAvailability() } }
    }
    var projectedValue: UpdateAvailabilityFlag { self }
    weak var updater: AppUpdateCoordinator?
    init(wrappedValue: Bool) { self.wrappedValue = wrappedValue }
}
