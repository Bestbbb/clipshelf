import AppKit
import XCTest
@testable import ClipShelf

private func releaseUpdateInfo() -> [String: Any] {
    ["ClipShelfDistribution": "release", "SUFeedURL": "https://updates.example.invalid/appcast.xml",
     "SUPublicEDKey": Data(repeating: 0x42, count: 32).base64EncodedString(),
     "CFBundleIdentifier": "io.example.clipshelf", "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "42",
     "SUEnableAutomaticChecks": false, "SUAutomaticallyUpdate": false, "SUEnableSystemProfiling": false,
     "SUVerifyUpdateBeforeExtraction": true, "SURequireSignedFeed": true, "SUSignedFeedFailureExpirationInterval": 0]
}

final class UpdateConfigurationTests: XCTestCase {
    func testReadsRealFixtureBundleAndStrictCanonicalReleaseValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("update-config-\(UUID()).bundle")
        defer { try? FileManager.default.removeItem(at: directory) }
        let contents = directory.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: releaseUpdateInfo(), format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let configuration = try UpdateConfiguration.read(bundle: XCTUnwrap(Bundle(url: directory)), allowsBackgroundIntegrations: true)
        XCTAssertEqual(configuration.version, "1.2.3"); XCTAssertEqual(configuration.build, "42")
        XCTAssertEqual(configuration.feedURL.scheme, "https"); XCTAssertEqual(configuration.bundleIdentifier, "io.example.clipshelf")
    }

    func testRejectsDevelopmentIsolatedAndIncompleteSignedFeedPolicy() throws {
        XCTAssertThrowsError(try UpdateConfiguration.read(info: releaseUpdateInfo(), allowsBackgroundIntegrations: false)) {
            XCTAssertEqual($0 as? UpdateConfiguration.Unavailable, .isolatedRuntime)
        }
        for marker: Any in ["development", "Release", true, ""] {
            var info = releaseUpdateInfo(); info["ClipShelfDistribution"] = marker
            XCTAssertThrowsError(try UpdateConfiguration.read(info: info, allowsBackgroundIntegrations: true))
        }
        for key in ["SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed", "SUSignedFeedFailureExpirationInterval",
                    "SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUEnableSystemProfiling"] {
            var info = releaseUpdateInfo(); info.removeValue(forKey: key)
            XCTAssertThrowsError(try UpdateConfiguration.read(info: info, allowsBackgroundIntegrations: true), key)
        }
        for (key, invalidValue): (String, Any) in [
            ("SUVerifyUpdateBeforeExtraction", false), ("SUVerifyUpdateBeforeExtraction", 1),
            ("SURequireSignedFeed", "YES"), ("SUSignedFeedFailureExpirationInterval", 3_600),
            ("SUSignedFeedFailureExpirationInterval", false), ("SUSignedFeedFailureExpirationInterval", "0"),
            ("SUEnableAutomaticChecks", true), ("SUAutomaticallyUpdate", true), ("SUEnableSystemProfiling", true),
        ] {
            var info = releaseUpdateInfo(); info[key] = invalidValue
            XCTAssertThrowsError(try UpdateConfiguration.read(info: info, allowsBackgroundIntegrations: true), "\(key)=\(invalidValue)")
        }
    }

    func testRejectsMalformedFeedKeyVersionAndDevelopmentIdentity() {
        let invalid: [(String, [String])] = [
            ("SUFeedURL", ["", "http://updates.example.invalid/feed", "file:///tmp/feed", "https:///feed", "https://user:pass@example.invalid/feed", "https://example.invalid/feed#fragment", "https://example.invalid/a b"]),
            ("SUPublicEDKey", ["", Data(repeating: 1, count: 31).base64EncodedString(), Data(repeating: 1, count: 33).base64EncodedString(), " \(Data(repeating: 1, count: 32).base64EncodedString())", "not-base64"]),
            ("CFBundleIdentifier", ["", "io.example.dev", "io.DEV.clipshelf", "io.validation.clipshelf", "io.demo.clipshelf", "one-component", "io.example.$(NAME)", "io.example.clipshelf\n"]),
            ("CFBundleShortVersionString", ["", "$(VERSION)", "1.2.3.4", "release-1", "1.2.3\n"]),
            ("CFBundleVersion", ["", "0", "-2", "42beta", "$(BUILD)", "42\n"]),
        ]
        for (key, values) in invalid {
            for value in values {
                var info = releaseUpdateInfo(); info[key] = value
                XCTAssertThrowsError(try UpdateConfiguration.read(info: info, allowsBackgroundIntegrations: true), "\(key)=\(value)")
            }
        }
    }
}

@MainActor
private final class FakeUpdateDriver: AppUpdateDriver {
    var canCheckForUpdates = true
    var sessionInProgress = false
    var checkPreferenceWrites: [Bool] = []
    var downloadPreferenceWrites: [Bool] = []
    private var checkPreference = false
    private var downloadPreference = false
    var automaticallyChecksForUpdates: Bool {
        get { checkPreference }
        set { checkPreference = newValue; checkPreferenceWrites.append(newValue); onChange?() }
    }
    var automaticallyDownloadsUpdates: Bool {
        get { downloadPreference }
        set { downloadPreference = newValue; downloadPreferenceWrites.append(newValue); onChange?() }
    }
    var allowsAutomaticUpdates: Bool { automaticallyChecksForUpdates }
    var lastUpdateCheckDate: Date?
    var onChange: (() -> Void)?
    var onEvent: ((AppUpdateEvent) -> Void)?
    var mayCheck: (() -> Bool)?
    var postponeRestart: ((String, @escaping () -> Void) -> Bool)?
    var starts = 0, checks = 0
    var startError: Error?
    func start() throws { starts += 1; if let startError { throw startError } }
    func checkForUpdates() { checks += 1 }
    func seedPreferences(checks: Bool, downloads: Bool) { checkPreference = checks; downloadPreference = downloads }
}

@MainActor
final class AppUpdateCoordinatorTests: XCTestCase {
    @MainActor private final class ApplicationActivity {
        @UpdateAvailabilityFlag var mutation = false
        @UpdateAvailabilityFlag var terminationDecision = false
        var suspended = false
        func connect(_ subject: AppUpdateCoordinator) {
            $mutation.updater = subject; $terminationDecision.updater = subject
            subject.isRestartBlocked = { [weak self] in
                guard let self else { return true }
                return self.mutation || self.terminationDecision || self.suspended
            }
        }
    }
    private func coordinator(_ fake: FakeUpdateDriver) throws -> AppUpdateCoordinator {
        AppUpdateCoordinator(configuration: .success(try UpdateConfiguration.read(info: releaseUpdateInfo(), allowsBackgroundIntegrations: true)), factory: { _ in fake })
    }

    func testUnavailableRuntimeAndMissingConfigurationNeverCreateDriverOrEnableActions() throws {
        let inputs: [([String: Any], Bool)] = [([:], true), (releaseUpdateInfo(), false), (["ClipShelfDistribution": "release"], true)]
        for (info, allowed) in inputs {
            var creations = 0
            let subject = AppUpdateCoordinator(configuration: Result { try UpdateConfiguration.read(info: info, allowsBackgroundIntegrations: allowed) }, factory: { _ in
                creations += 1; return FakeUpdateDriver()
            })
            subject.start(); subject.start(); subject.checkForUpdates()
            subject.setAutomaticallyChecksForUpdates(true); subject.setAutomaticallyDownloadsUpdates(true)
            subject.retryPendingRestart(); subject.refreshAvailability()
            XCTAssertEqual(creations, 0); XCTAssertFalse(subject.isAvailable); XCTAssertFalse(subject.canCheck)
            XCTAssertFalse(subject.isBusy); XCTAssertFalse(subject.automaticallyChecksForUpdates)
            XCTAssertFalse(subject.automaticallyDownloadsUpdates); XCTAssertNil(subject.lastUpdateCheckDate)
            XCTAssertFalse(subject.status.contains("最新")); XCTAssertFalse(subject.status.contains("未发现"))
        }
    }

    func testStartUsesNativePreferencesWithoutOverwritingPersistedOptInAndRemainsIdempotent() throws {
        let fake = FakeUpdateDriver(); fake.seedPreferences(checks: true, downloads: true)
        let subject = try coordinator(fake)
        XCTAssertEqual(fake.starts, 0)
        subject.start(); subject.start()
        XCTAssertEqual(fake.starts, 1); XCTAssertTrue(subject.isAvailable)
        XCTAssertTrue(subject.automaticallyChecksForUpdates); XCTAssertTrue(subject.automaticallyDownloadsUpdates)
        XCTAssertTrue(fake.checkPreferenceWrites.isEmpty); XCTAssertTrue(fake.downloadPreferenceWrites.isEmpty)
        subject.setAutomaticallyChecksForUpdates(false)
        XCTAssertEqual(fake.checkPreferenceWrites, [false]); XCTAssertFalse(subject.canChangeAutomaticDownloads)
        subject.setAutomaticallyDownloadsUpdates(false)
        XCTAssertTrue(fake.downloadPreferenceWrites.isEmpty, "A disabled control must not write another preference")
        subject.setAutomaticallyChecksForUpdates(true); subject.setAutomaticallyDownloadsUpdates(false)
        XCTAssertEqual(fake.downloadPreferenceWrites, [false])
    }

    func testCanCheckTracksNativeCapabilityAndExternalGuardInsteadOfEquatingBusyWithDisabled() throws {
        let fake = FakeUpdateDriver(), subject = try coordinator(fake)
        var blocked = false; subject.isRestartBlocked = { blocked }
        subject.start(); XCTAssertTrue(subject.canCheck)
        fake.sessionInProgress = true; fake.onChange?()
        XCTAssertTrue(subject.isBusy); XCTAssertTrue(subject.canCheck, "Sparkle can focus an existing update UI")
        subject.checkForUpdates(); XCTAssertEqual(fake.checks, 1)
        fake.canCheckForUpdates = false; fake.onChange?()
        subject.checkForUpdates(); XCTAssertEqual(fake.checks, 1)
        fake.canCheckForUpdates = true; blocked = true; subject.refreshAvailability()
        XCTAssertFalse(subject.canCheck); XCTAssertEqual(fake.mayCheck?(), false)
        subject.checkForUpdates(); XCTAssertEqual(fake.checks, 1)
        blocked = false; subject.refreshAvailability()
        XCTAssertTrue(subject.canCheck); XCTAssertEqual(fake.mayCheck?(), true)
    }

    func testCycleCompletionAndErrorsNeverClaimLatestAndStagedInstallDoesNotRequestQuit() throws {
        let fake = FakeUpdateDriver(), subject = try coordinator(fake)
        subject.start(); subject.checkForUpdates()
        fake.onEvent?(.cycleFinished)
        XCTAssertEqual(subject.status, "本次更新检查已结束。")
        fake.onEvent?(.found("1.3")); fake.onEvent?(.downloaded("1.3"))
        XCTAssertTrue(subject.status.contains("正在验证"))
        fake.onEvent?(.waitingForQuit("1.3")); fake.onEvent?(.cycleFinished)
        XCTAssertTrue(subject.status.contains("正常退出后安装")); XCTAssertFalse(subject.hasPendingRestart)
        XCTAssertEqual(fake.checks, 1, "Reporting a staged update must not start another action")
        fake.onEvent?(.noCompatibleUpdate)
        XCTAssertEqual(subject.status, "未发现此 Mac 可用的更新。")
        fake.onEvent?(.failed("网络不可用")); fake.onEvent?(.cycleFinished)
        XCTAssertTrue(subject.status.contains("网络不可用")); XCTAssertFalse(subject.status.contains("最新"))
    }

    func testBlockedRestartRequiresExplicitRetryAndConsumesContinuationBeforeReentry() throws {
        let fake = FakeUpdateDriver(), subject = try coordinator(fake)
        var blocked = true, installs = 0, duplicateInstalls = 0
        subject.isRestartBlocked = { blocked }; subject.start()
        XCTAssertEqual(fake.postponeRestart?("1.3", { installs += 1; subject.retryPendingRestart() }), true)
        XCTAssertEqual(fake.postponeRestart?("1.3", { duplicateInstalls += 1 }), true)
        XCTAssertTrue(subject.hasPendingRestart); XCTAssertTrue(subject.isBusy); XCTAssertFalse(subject.canRetryPendingRestart)
        subject.retryPendingRestart(); XCTAssertEqual(installs, 0)
        blocked = false; subject.refreshAvailability()
        XCTAssertEqual(installs, 0, "Finishing a transaction must not silently restart the application")
        XCTAssertTrue(subject.canRetryPendingRestart)
        subject.retryPendingRestart(); subject.retryPendingRestart()
        XCTAssertEqual(installs, 1); XCTAssertEqual(duplicateInstalls, 0); XCTAssertFalse(subject.hasPendingRestart)
        // The subsequent Apple quit event can be declined by Root's draft gate.
        // Refreshing that gate must not stop Sparkle or reset native settings.
        blocked = true; subject.refreshAvailability(); blocked = false; subject.refreshAvailability()
        XCTAssertTrue(subject.isAvailable); XCTAssertTrue(subject.canCheck); XCTAssertEqual(fake.starts, 1)
        XCTAssertTrue(fake.checkPreferenceWrites.isEmpty); XCTAssertTrue(fake.downloadPreferenceWrites.isEmpty)
    }

    func testUnblockedInstallUsesNormalQuitAndStopRejectsLateCallbacksAndContinuations() throws {
        let fake = FakeUpdateDriver(), subject = try coordinator(fake)
        var blocked = false, installs = 0
        subject.isRestartBlocked = { blocked }; subject.start()
        XCTAssertEqual(fake.postponeRestart?("1.3", { installs += 1 }), false)
        XCTAssertEqual(installs, 0, "Returning false lets Sparkle send its standard quit event")
        blocked = true
        XCTAssertEqual(fake.postponeRestart?("1.3", { installs += 1 }), true)
        let staleEvent = fake.onEvent, staleRestart = fake.postponeRestart, staleChange = fake.onChange
        subject.stop(); let stoppedStatus = subject.status
        blocked = false; subject.retryPendingRestart(); subject.checkForUpdates(); subject.start()
        staleEvent?(.found("stale")); staleChange?()
        XCTAssertEqual(staleRestart?("late", { installs += 1 }), true)
        XCTAssertEqual(installs, 0); XCTAssertEqual(fake.starts, 1); XCTAssertEqual(fake.checks, 0)
        XCTAssertEqual(subject.status, stoppedStatus); XCTAssertFalse(subject.isAvailable); XCTAssertFalse(subject.hasPendingRestart)
    }

    func testStartFailureIsUnavailableAndRefreshNotificationCannotRecurse() throws {
        let fake = FakeUpdateDriver(), subject = try coordinator(fake)
        fake.startError = NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture startup failure"])
        var renders = 0
        subject.onChange = { renders += 1; subject.refreshAvailability() }
        subject.start(); subject.start(); subject.refreshAvailability()
        XCTAssertEqual(renders, 1); XCTAssertEqual(fake.starts, 1)
        XCTAssertFalse(subject.isAvailable); XCTAssertFalse(subject.canCheck)
        XCTAssertTrue(subject.status.contains("fixture startup failure")); XCTAssertFalse(subject.status.contains("最新"))
        subject.checkForUpdates(); XCTAssertEqual(fake.checks, 0)
    }

    func testFactoryFailureIsAttemptedOnceAndCannotBeMistakenForAnAvailableUpdater() throws {
        var creations = 0
        let subject = AppUpdateCoordinator(configuration: .success(try UpdateConfiguration.read(info: releaseUpdateInfo(), allowsBackgroundIntegrations: true)), factory: { _ in
            creations += 1
            throw NSError(domain: "fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "factory unavailable"])
        })
        subject.start(); subject.start(); subject.checkForUpdates()
        XCTAssertEqual(creations, 1); XCTAssertFalse(subject.isAvailable); XCTAssertFalse(subject.canCheck)
        XCTAssertTrue(subject.status.contains("factory unavailable"))
    }

    func testCancelledOrFailedInstallDiscardsDeferredContinuation() throws {
        for event in [AppUpdateEvent.cancelled, .failed("签名验证失败")] {
            let fake = FakeUpdateDriver(), subject = try coordinator(fake)
            var blocked = true, installs = 0
            subject.isRestartBlocked = { blocked }; subject.start()
            XCTAssertEqual(fake.postponeRestart?("1.3", { installs += 1 }), true)
            fake.onEvent?(event)
            blocked = false; subject.refreshAvailability(); subject.retryPendingRestart()
            XCTAssertFalse(subject.hasPendingRestart); XCTAssertFalse(subject.canRetryPendingRestart)
            XCTAssertEqual(installs, 0)
        }
    }

    func testRealAdapterRejectsFixtureAuthorizationForUnconfiguredTestHostBeforeCreatingSparkle() throws {
        let configuration = try UpdateConfiguration.read(info: releaseUpdateInfo(), allowsBackgroundIntegrations: true)
        XCTAssertThrowsError(try SparkleUpdateDriver(configuration: configuration))
    }

    func testUnconfiguredSettingsNeverCreateDriverAndDoNotDescribeACompletedCheck() throws {
        var creations = 0
        let subject = AppUpdateCoordinator(configuration: .failure(UpdateConfiguration.Unavailable.developmentBuild), factory: { _ in
            creations += 1; return FakeUpdateDriver()
        })
        subject.start()
        let settings = UpdateSettingsController(coordinator: subject)
        settings.refreshView()
        let root = try XCTUnwrap(settings.window?.contentView)
        func buttons(_ root: NSView) -> [NSButton] { (root as? NSButton).map { [$0] } ?? root.subviews.flatMap(buttons) }
        XCTAssertTrue(buttons(root).allSatisfy { !$0.isEnabled })
        XCTAssertEqual(creations, 0); XCTAssertTrue(subject.status.contains("开发版本"))
        XCTAssertFalse(settings.window?.isVisible ?? true)
    }

    func testMutationDeferReenablesDeferredInstallWithoutAnotherRefreshOrBackgroundCleanup() throws {
        let fake = FakeUpdateDriver(), subject = try coordinator(fake), activity = ApplicationActivity()
        activity.connect(subject); subject.start()
        let settings = UpdateSettingsController(coordinator: subject)
        subject.onChange = { settings.refreshView() }
        let root = try XCTUnwrap(settings.window?.contentView)
        func buttons(_ root: NSView) -> [NSButton] { (root as? NSButton).map { [$0] } ?? root.subviews.flatMap(buttons) }
        let retry = try XCTUnwrap(buttons(root).first { $0.accessibilityIdentifier() == "update.retryRestart" })
        var installs = 0
        func finishExport() {
            activity.mutation = true
            defer { activity.mutation = false }
            XCTAssertEqual(fake.postponeRestart?("1.3", { installs += 1 }), true)
            // Like exportBackup, the completion message renders while the
            // mutation is still busy; there is no subsequent query or GC pass.
            subject.refreshAvailability()
            XCTAssertFalse(retry.isEnabled)
            XCTAssertEqual(subject.menuActionTitle, "继续安装更新…")
            XCTAssertFalse(subject.canPerformMenuAction)
        }
        finishExport()
        XCTAssertTrue(retry.isEnabled); XCTAssertTrue(subject.canPerformMenuAction)
        XCTAssertEqual(installs, 0, "Completing work only exposes the user's continue action")
        XCTAssertFalse(settings.window?.isVisible ?? true)
        subject.retryPendingRestart(); subject.retryPendingRestart()
        XCTAssertEqual(installs, 1); XCTAssertEqual(subject.menuActionTitle, "检查更新…")
    }

    func testDeclinedTerminationRestoresControlsAndSuspendedPendingInstallStaysPassive() throws {
        let fake = FakeUpdateDriver(), subject = try coordinator(fake), activity = ApplicationActivity()
        activity.connect(subject); subject.start()
        let settings = UpdateSettingsController(coordinator: subject)
        subject.onChange = { settings.refreshView() }
        let root = try XCTUnwrap(settings.window?.contentView)
        func buttons(_ root: NSView) -> [NSButton] { (root as? NSButton).map { [$0] } ?? root.subviews.flatMap(buttons) }
        let check = try XCTUnwrap(buttons(root).first { $0.accessibilityIdentifier() == "update.check" })
        activity.terminationDecision = true
        XCTAssertFalse(check.isEnabled)
        activity.terminationDecision = false
        XCTAssertTrue(check.isEnabled, "Continuing a draft must not leave a disabled settings snapshot")
        var installs = 0
        activity.suspended = true; subject.refreshAvailability()
        XCTAssertEqual(fake.postponeRestart?("1.3", { installs += 1 }), true)
        XCTAssertEqual(subject.menuActionTitle, "继续安装更新…"); XCTAssertFalse(subject.canPerformMenuAction)
        subject.retryPendingRestart(); XCTAssertEqual(installs, 0)
        XCTAssertFalse(settings.window?.isVisible ?? true)
        activity.suspended = false; subject.refreshAvailability()
        XCTAssertTrue(subject.canPerformMenuAction); XCTAssertEqual(installs, 0)
        activity.terminationDecision = true
        XCTAssertFalse(subject.canPerformMenuAction)
        activity.terminationDecision = false
        XCTAssertTrue(subject.canPerformMenuAction)
        XCTAssertTrue(subject.isAvailable); XCTAssertEqual(fake.starts, 1)
    }

    func testUnshownSettingsRenderDisabledModeAndReachableControlsWithLongFailure() throws {
        let fake = FakeUpdateDriver(), subject = try coordinator(fake)
        subject.start()
        let settings = UpdateSettingsController(coordinator: subject)
        subject.onChange = { settings.refreshView(); subject.refreshAvailability() }
        defer { subject.stop() }
        let window = try XCTUnwrap(settings.window), root = try XCTUnwrap(window.contentView)
        func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
            (root as? T).map { [$0] } ?? root.subviews.flatMap { views(type, in: $0) }
        }
        let buttons = views(NSButton.self, in: root)
        let check = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier() == "update.check" })
        let checks = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier() == "update.automaticChecks" })
        let downloads = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier() == "update.automaticDownloads" })
        XCTAssertTrue(check.isEnabled); XCTAssertEqual(checks.state, .off); XCTAssertEqual(downloads.state, .off)
        XCTAssertFalse(downloads.isEnabled)
        subject.setAutomaticallyChecksForUpdates(true)
        XCTAssertEqual(checks.state, .on); XCTAssertTrue(downloads.isEnabled)
        fake.onEvent?(.failed(String(repeating: "很长的签名或网络诊断。", count: 150)))
        window.setContentSize(NSSize(width: 580, height: 380)); root.layoutSubtreeIfNeeded()
        for button in buttons where !button.isHidden {
            let frame = button.convert(button.bounds, to: root)
            XCTAssertTrue(root.bounds.insetBy(dx: -1, dy: -1).contains(frame), "\(button.title): \(frame)")
        }
        let status = try XCTUnwrap(views(NSTextField.self, in: root).first { $0.accessibilityIdentifier() == "update.status" })
        XCTAssertNotNil(status.enclosingScrollView); XCTAssertTrue(status.stringValue.contains("很长的签名"))
        XCTAssertFalse(window.isVisible)
        subject.stop(); XCTAssertFalse(check.isEnabled); XCTAssertFalse(checks.isEnabled); XCTAssertFalse(downloads.isEnabled)
    }
}
