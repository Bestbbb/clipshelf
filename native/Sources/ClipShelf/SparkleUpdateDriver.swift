import Foundation
import Sparkle

/// Constructed only after release configuration and runtime isolation pass.
/// Sparkle remains the sole owner of update preferences and all update UI.
@MainActor
final class SparkleUpdateDriver: NSObject, AppUpdateDriver, SPUUpdaterDelegate {
    private let configuration: UpdateConfiguration
    private var controller: SPUStandardUpdaterController!
    private var observations: [NSKeyValueObservation] = []
    var onChange: (() -> Void)?
    var onEvent: ((AppUpdateEvent) -> Void)?
    var mayCheck: (() -> Bool)?
    var postponeRestart: ((String, @escaping () -> Void) -> Bool)?

    init(configuration: UpdateConfiguration) throws {
        // The standard controller targets Bundle.main. A fixture or another
        // bundle must never accidentally authorize an unconfigured host app.
        guard try UpdateConfiguration.read(bundle: .main, allowsBackgroundIntegrations: true) == configuration else {
            throw UpdateConfiguration.Unavailable.invalidReleaseConfiguration("更新配置与当前应用不匹配。")
        }
        self.configuration = configuration
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        let updater = controller.updater
        func observe<Value>(_ keyPath: KeyPath<SPUUpdater, Value>) {
            observations.append(updater.observe(keyPath, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.onChange?() }
            })
        }
        observe(\.canCheckForUpdates); observe(\.sessionInProgress)
        observe(\.automaticallyChecksForUpdates); observe(\.automaticallyDownloadsUpdates)
        observe(\.allowsAutomaticUpdates); observe(\.lastUpdateCheckDate)
    }
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    var sessionInProgress: Bool { controller.updater.sessionInProgress }
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }
    var allowsAutomaticUpdates: Bool { controller.updater.allowsAutomaticUpdates }
    var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }
    func start() throws { try controller.updater.start() }
    func checkForUpdates() { controller.checkForUpdates(nil) }

    // The bundle-validated feed wins over historical Sparkle defaults overrides.
    func feedURLString(for updater: SPUUpdater) -> String? { configuration.feedURL.absoluteString }
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard mayCheck?() == true else {
            throw NSError(domain: "ClipShelf.Update", code: 1, userInfo: [NSLocalizedDescriptionKey: "当前操作尚未完成，请稍后检查更新。"])
        }
        onEvent?(.checking)
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) { onEvent?(.found(item.displayVersionString)) }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) { onEvent?(.noCompatibleUpdate) }
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) { onEvent?(.downloading(item.displayVersionString)) }
    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) { onEvent?(.downloaded(item.displayVersionString)) }
    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) { onEvent?(.extracting(item.displayVersionString)) }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { onEvent?(.installing(item.displayVersionString)) }
    func userDidCancelDownload(_ updater: SPUUpdater) { onEvent?(.cancelled) }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeRestart?(item.displayVersionString, installHandler) ?? true
    }
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        onEvent?(.waitingForQuit(item.displayVersionString))
        // Never invoke the silent immediate-install handler. Normal app quit is
        // authorized through Root's applicationShouldTerminate draft/commit gate.
        return false
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { report(error) }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error { report(error) } else { onEvent?(.cycleFinished) }
        onChange?()
    }
    private func report(_ error: Error) {
        let error = error as NSError
        if error.domain == SUSparkleErrorDomain, error.code == SUError.noUpdateError.rawValue { onEvent?(.noCompatibleUpdate) }
        else if error.domain == SUSparkleErrorDomain, error.code == SUError.installationCanceledError.rawValue { onEvent?(.cancelled) }
        else { onEvent?(.failed(error.localizedDescription)) }
    }
}
