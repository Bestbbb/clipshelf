import CSQLite
import Darwin
import Foundation
import XCTest
@testable import ClipShelfCore

private final class InjectedStorageCapacity: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: StorageVolumeCapacity] = [
        "volume-a": .init(volumeID: "a", availableBytes: 100),
        "volume-b": .init(volumeID: "b", availableBytes: 100),
    ]
    private var calls = 0
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func set(_ key: String, volume: String, available: Int64?) {
        lock.lock(); defer { lock.unlock() }
        values[key] = .init(volumeID: volume, availableBytes: available)
    }
    func read(_ url: URL) throws -> StorageVolumeCapacity {
        lock.lock(); defer { lock.unlock() }; calls += 1
        let key = url.pathComponents.contains("volume-b") ? "volume-b" : "volume-a"
        return values[key]!
    }
}

private final class StorageBudgetRaceResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [StorageSpaceLease] = []
    private var failures: [StorageWriteFailure] = []
    func accept(_ result: Result<StorageSpaceLease, Error>) {
        lock.lock(); defer { lock.unlock() }
        switch result {
        case .success(let lease): values.append(lease)
        case .failure(let error): failures.append(StorageWriteFailure.classify(error) ?? .coordinationUnavailable)
        }
    }
    var snapshot: ([StorageSpaceLease], [StorageWriteFailure]) {
        lock.lock(); defer { lock.unlock() }; return (values, failures)
    }
}

final class StorageSpaceCoordinatorTests: XCTestCase {
    private var root: URL!
    private var capacity: InjectedStorageCapacity!
    override func setUpWithError() throws {
        if let helperRoot = ProcessInfo.processInfo.environment["CLIPSHELF_SPACE_HELPER_ROOT"] {
            root = URL(fileURLWithPath: helperRoot, isDirectory: true)
            capacity = InjectedStorageCapacity()
            return
        }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-space-\(UUID().uuidString)")
        for url in [root!, root.appendingPathComponent("volume-a"), root.appendingPathComponent("volume-b")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        capacity = InjectedStorageCapacity()
    }
    override func tearDownWithError() throws {
        if ProcessInfo.processInfo.environment["CLIPSHELF_SPACE_HELPER_ROOT"] == nil {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private var registry: URL { root.appendingPathComponent("budgets", isDirectory: true) }
    private func coordinator() throws -> StorageSpaceCoordinator {
        let provider = capacity!
        return try StorageSpaceCoordinator(directory: registry, capacityProvider: { try provider.read($0) })
    }
    private func requirement(_ bytes: Int64, volume: String = "volume-a", name: String = "output") -> StorageSpaceRequirement {
        .init(destination: root.appendingPathComponent(volume).appendingPathComponent(name), bytes: bytes)
    }
    private func records() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: registry, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "index.json" }
    }

    private func startHelper(stage: String, registry: URL) throws -> Process {
        let runner = URL(fileURLWithPath: CommandLine.arguments[0])
        let bundle = Bundle(for: StorageSpaceCoordinatorTests.self).bundleURL
        guard runner.lastPathComponent == "xctest", bundle.pathExtension == "xctest" else {
            throw XCTSkip("The subprocess fixture requires the macOS xctest runner and its test bundle")
        }
        let ready = root.appendingPathComponent("helper-ready")
        try? FileManager.default.removeItem(at: ready)
        let log = root.appendingPathComponent("helper.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let child = Process()
        child.executableURL = runner
        child.arguments = ["-XCTest", "ClipShelfCoreTests.StorageSpaceCoordinatorTests/testSubprocessCrashCheckpoint", bundle.path]
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("XCTest") && !$0.key.hasPrefix("CLIPSHELF_SPACE_HELPER_") }
        environment["CLIPSHELF_SPACE_HELPER_ROOT"] = root.path
        environment["CLIPSHELF_SPACE_HELPER_REGISTRY"] = registry.path
        environment["CLIPSHELF_SPACE_HELPER_STAGE"] = stage
        child.environment = environment
        child.standardOutput = output; child.standardError = output
        try child.run()
        let deadline = Date().addingTimeInterval(10)
        while child.isRunning && !FileManager.default.fileExists(atPath: ready.path) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard child.isRunning, FileManager.default.fileExists(atPath: ready.path) else {
            stopHelper(child)
            let text = String(decoding: (try? Data(contentsOf: log))?.prefix(2_000) ?? Data(), as: UTF8.self)
            XCTFail("The explicitly selected subprocess helper did not reach \(stage): \(text)")
            throw StorageWriteFailure.coordinationUnavailable
        }
        return child
    }

    private func stopHelper(_ child: Process) {
        if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
        let deadline = Date().addingTimeInterval(5)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertFalse(child.isRunning, "The fixture child must exit before the next registry operation")
    }

    /// Selected by the parent using -XCTest; an ordinary suite run returns immediately.
    func testSubprocessCrashCheckpoint() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let registryPath = environment["CLIPSHELF_SPACE_HELPER_REGISTRY"],
              let stage = environment["CLIPSHELF_SPACE_HELPER_STAGE"],
              environment["CLIPSHELF_SPACE_HELPER_ROOT"] != nil else { return }
        let ready = root.appendingPathComponent("helper-ready")
        let stopAtCheckpoint: @Sendable () -> Void = {
            do { try Data("ready".utf8).write(to: ready, options: .atomic) }
            catch { return }
            // Also bound the child lifetime if the parent itself fails or exits unexpectedly.
            Thread.sleep(forTimeInterval: 30)
        }
        let coordinator = try StorageSpaceCoordinator(directory: URL(fileURLWithPath: registryPath),
            capacityProvider: { _ in .init(volumeID: "a", availableBytes: 100) }, checkpoint: {
                if $0.rawValue == stage { stopAtCheckpoint() }
            })
        let lease = try coordinator.reserve([requirement(60)])
        if stage == StorageSpaceCheckpoint.replacementPublished.rawValue { try lease.addRequirements([requirement(20)]) }
        if stage == "reserved" { stopAtCheckpoint() }
        try lease.release()
        XCTFail("The parent should kill the child at its selected checkpoint")
    }

    func testInitializationAndZeroBudgetDoNotCreateFilesOrQueryCapacity() throws {
        let provider = capacity!
        let path = root.appendingPathComponent("not-created/registry")
        let coordinator = try StorageSpaceCoordinator(directory: path, capacityProvider: { try provider.read($0) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.deletingLastPathComponent().path))
        let lease = try coordinator.reserve([requirement(0)])
        try lease.revalidate(); try lease.validateDestinations(); try lease.release()
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.deletingLastPathComponent().path))
        XCTAssertThrowsError(try lease.revalidate()) { XCTAssertEqual($0 as? StorageWriteFailure, .releasedLease) }
    }

    func testSameVolumeRequirementsAndSeparateCoordinatorInstancesShareOneBudget() throws {
        let a = try coordinator(), b = try coordinator()
        XCTAssertThrowsError(try a.reserve([requirement(60), requirement(50, name: "other")])) {
            XCTAssertEqual($0 as? StorageWriteFailure, .insufficientSpace(requiredBytes: 110, availableBytes: 100))
        }
        let first = try a.reserve([requirement(60)])
        XCTAssertThrowsError(try b.reserve([requirement(50)])) {
            XCTAssertEqual($0 as? StorageWriteFailure, .insufficientSpace(requiredBytes: 110, availableBytes: 100))
        }
        let second = try b.reserve([requirement(40)])
        try first.revalidate(); try second.revalidate()
        try first.release(); try first.release(); try second.release()
        XCTAssertTrue(try records().isEmpty)
        let all = try a.reserve([requirement(100)]); try all.release()
    }

    func testInjectedDistinctVolumesAreCheckedIndependentlyAndPublishDoesNotRechargeWrittenBytes() throws {
        let coordinator = try coordinator()
        let lease = try coordinator.reserve([requirement(80), requirement(90, volume: "volume-b")])
        capacity.set("volume-b", volume: "b", available: 10)
        XCTAssertThrowsError(try lease.revalidate()) {
            XCTAssertEqual($0 as? StorageWriteFailure, .insufficientSpace(requiredBytes: 90, availableBytes: 10))
        }
        try lease.validateDestinations()
        capacity.set("volume-b", volume: "b", available: nil)
        try lease.validateDestinations()
        XCTAssertThrowsError(try lease.revalidate()) { XCTAssertEqual($0 as? StorageWriteFailure, .capacityUnavailable) }
        try lease.release()
    }

    func testInvalidUnknownAndOverflowingRequirementsFailConservatively() throws {
        let coordinator = try coordinator()
        XCTAssertThrowsError(try coordinator.reserve([requirement(-1)])) { XCTAssertEqual($0 as? StorageWriteFailure, .invalidRequirement) }
        XCTAssertThrowsError(try coordinator.reserve([.init(destination: URL(string: "https://example.com")!, bytes: 1)])) {
            XCTAssertEqual($0 as? StorageWriteFailure, .invalidRequirement)
        }
        XCTAssertThrowsError(try coordinator.reserve([requirement(Int64.max), requirement(1)])) {
            XCTAssertEqual($0 as? StorageWriteFailure, .invalidRequirement)
        }
        for available: Int64? in [nil, -1] {
            capacity.set("volume-a", volume: "a", available: available)
            XCTAssertThrowsError(try coordinator.reserve([requirement(1)])) { XCTAssertEqual($0 as? StorageWriteFailure, .capacityUnavailable) }
        }
        capacity.set("volume-a", volume: "", available: 100)
        XCTAssertThrowsError(try coordinator.reserve([requirement(1)])) { XCTAssertEqual($0 as? StorageWriteFailure, .capacityUnavailable) }
        let throwing = try StorageSpaceCoordinator(directory: root.appendingPathComponent("throwing"), capacityProvider: { _ in
            throw NSError(domain: "UnavailableVolume", code: 1)
        })
        XCTAssertThrowsError(try throwing.reserve([requirement(1)])) { XCTAssertEqual($0 as? StorageWriteFailure, .capacityUnavailable) }
    }

    func testNewDirectoriesAreAllowedButReplacementAnchorsAndVolumeChangesAreRejected() throws {
        let coordinator = try coordinator()
        let lease = try coordinator.reserve([requirement(20, name: "new/output")])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("volume-a/new"), withIntermediateDirectories: false)
        try Data([1]).write(to: root.appendingPathComponent("volume-a/new/output"))
        try lease.validateDestinations()
        capacity.set("volume-a", volume: "changed-volume", available: 100)
        XCTAssertThrowsError(try lease.validateDestinations()) { XCTAssertEqual($0 as? StorageWriteFailure, .destinationChanged) }
        capacity.set("volume-a", volume: "a", available: 100)
        let old = root.appendingPathComponent("volume-a")
        try FileManager.default.moveItem(at: old, to: root.appendingPathComponent("old-a"))
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
        XCTAssertThrowsError(try lease.revalidate()) { XCTAssertEqual($0 as? StorageWriteFailure, .destinationChanged) }
        try lease.release()
    }

    func testNewPathSymlinkDoesNotAuthorizeAnExternalDestination() throws {
        let coordinator = try coordinator()
        let lease = try coordinator.reserve([requirement(20, name: "new/output")])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("volume-a/new"),
            withDestinationURL: root.appendingPathComponent("volume-b"))
        XCTAssertThrowsError(try lease.validateDestinations()) { XCTAssertEqual($0 as? StorageWriteFailure, .destinationChanged) }
        try lease.release()
    }

    func testRegistryReplacementIsRejectedAcrossFreshInstancesAndFailedReleaseDropsItsLiveLock() throws {
        let coordinator = try coordinator(), lease = try coordinator.reserve([requirement(60)])
        let recordName = try XCTUnwrap(records().first).lastPathComponent
        let old = root.appendingPathComponent("old-budgets")
        try FileManager.default.moveItem(at: registry, to: old)
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try lease.validateDestinations()) { XCTAssertEqual($0 as? StorageWriteFailure, .coordinationUnavailable) }
        XCTAssertThrowsError(try self.coordinator().reserve([requirement(50)])) { XCTAssertEqual($0 as? StorageWriteFailure, .coordinationUnavailable) }
        XCTAssertThrowsError(try lease.release()) { XCTAssertEqual($0 as? StorageWriteFailure, .coordinationUnavailable) }
        let descriptor = Darwin.open(old.appendingPathComponent(recordName).path, O_RDONLY | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        if descriptor >= 0 {
            defer { Darwin.close(descriptor) }
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0, "Failed registry cleanup must not retain an active budget")
        }
        XCTAssertThrowsError(try lease.revalidate()) { XCTAssertEqual($0 as? StorageWriteFailure, .releasedLease) }
    }

    func testUnknownCorruptAndCopiedRecordsArePreservedAndBlockNewClaims() throws {
        let coordinator = try coordinator(), lease = try coordinator.reserve([requirement(30)])
        let unknown = registry.appendingPathComponent("unknown.bin")
        try Data("unknown".utf8).write(to: unknown)
        XCTAssertThrowsError(try coordinator.reserve([requirement(1)])) { XCTAssertEqual($0 as? StorageWriteFailure, .coordinationUnavailable) }
        XCTAssertEqual(try Data(contentsOf: unknown), Data("unknown".utf8))
        try FileManager.default.removeItem(at: unknown)
        let copy = registry.appendingPathComponent(UUID().uuidString + ".json")
        try FileManager.default.copyItem(at: XCTUnwrap(records().first), to: copy)
        XCTAssertThrowsError(try coordinator.reserve([requirement(1)])) { XCTAssertEqual($0 as? StorageWriteFailure, .coordinationUnavailable) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        try FileManager.default.removeItem(at: copy)
        let corrupt = registry.appendingPathComponent(UUID().uuidString + ".json")
        try Data("{}".utf8).write(to: corrupt)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: corrupt.path)
        XCTAssertThrowsError(try coordinator.reserve([requirement(1)])) { XCTAssertEqual($0 as? StorageWriteFailure, .coordinationUnavailable) }
        XCTAssertEqual(try Data(contentsOf: corrupt), Data("{}".utf8))
        try FileManager.default.removeItem(at: corrupt)
        try lease.release()
    }

    func testMissingActiveClaimIsNotMistakenForAnEmptyRegistry() throws {
        let coordinator = try coordinator(), lease = try coordinator.reserve([requirement(60)])
        let record = try XCTUnwrap(records().first)
        try FileManager.default.removeItem(at: record)
        XCTAssertThrowsError(try self.coordinator().reserve([requirement(50)])) {
            XCTAssertEqual($0 as? StorageWriteFailure, .coordinationUnavailable)
        }
        XCTAssertThrowsError(try lease.release()) { XCTAssertEqual($0 as? StorageWriteFailure, .coordinationUnavailable) }
    }

    func testDurableRetirementResumesBeforeAndAfterClaimUnlink() throws {
        for alreadyUnlinked in [false, true] {
            let coordinator = try coordinator()
            var lease: StorageSpaceLease? = try coordinator.reserve([requirement(90)])
            let record = try XCTUnwrap(records().first)
            lease = nil; XCTAssertNil(lease)
            let indexURL = registry.appendingPathComponent("index.json")
            var index = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any])
            var entries = try XCTUnwrap(index["entries"] as? [[String: Any]])
            XCTAssertEqual(entries.count, 1)
            entries[0]["retired"] = true; index["entries"] = entries
            // Synthetic durable crash checkpoint: retirement was committed, and the process
            // died either before removing its file or before removing the final index entry.
            try JSONSerialization.data(withJSONObject: index).write(to: indexURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
            if alreadyUnlinked { try FileManager.default.removeItem(at: record) }
            let recovered = try self.coordinator().reserve([requirement(100)])
            XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
            XCTAssertEqual(try records().count, 1)
            try recovered.release()
        }
    }

    func testRegistryAndClaimsArePrivateAndUnsafeRegistrySymlinkIsRejected() throws {
        let coordinator = try coordinator(), lease = try coordinator.reserve([requirement(1)])
        for url in [registry, registry.appendingPathComponent("index.json"), root.appendingPathComponent("budgets.lock")] + (try records()) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
            XCTAssertEqual(mode & 0o077, 0)
        }
        try lease.release()
        let link = root.appendingPathComponent("linked-budget")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: registry)
        let unsafe = try StorageSpaceCoordinator(directory: link, capacityProvider: { _ in .init(volumeID: "a", availableBytes: 100) })
        XCTAssertThrowsError(try unsafe.reserve([requirement(1)])) { XCTAssertEqual($0 as? StorageWriteFailure, .coordinationUnavailable) }
        XCTAssertTrue(try records().isEmpty)
    }

    func testDeinitializationReleasesWithoutRegistryLockAndNextReservationReapsOnlyVerifiedDeadClaim() throws {
        let coordinator = try coordinator()
        var lease: StorageSpaceLease? = try coordinator.reserve([requirement(90)])
        weak var weakLease = lease
        let lockPath = root.appendingPathComponent("budgets.lock")
        let descriptor = Darwin.open(lockPath.path, O_RDWR | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        lease = nil
        XCTAssertNil(weakLease)
        XCTAssertEqual(try records().count, 1)
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        let next = try coordinator.reserve([requirement(100)])
        XCTAssertEqual(try records().count, 1)
        try next.release()
    }

    func testTwoConcurrentCoordinatorInstancesCannotBothSpendTheSameCapacity() throws {
        let coordinators = try [coordinator(), coordinator()]
        let results = StorageBudgetRaceResults(), group = DispatchGroup(), start = DispatchSemaphore(value: 0)
        let request = requirement(70)
        for coordinator in coordinators {
            group.enter()
            DispatchQueue.global().async {
                start.wait()
                results.accept(Result { try coordinator.reserve([request]) })
                group.leave()
            }
        }
        start.signal(); start.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        let (leases, failures) = results.snapshot
        XCTAssertEqual(leases.count, 1)
        XCTAssertEqual(failures, [.insufficientSpace(requiredBytes: 140, availableBytes: 100)])
        for lease in leases { try lease.release() }
    }

    func testIndependentProcessClaimBlocksReservationUntilKernelReleasesLockAfterCrash() throws {
        let child = try startHelper(stage: "reserved", registry: registry)
        defer { stopHelper(child) }
        let record = try XCTUnwrap(records().first)
        XCTAssertThrowsError(try self.coordinator().reserve([requirement(50)])) {
            XCTAssertEqual($0 as? StorageWriteFailure, .insufficientSpace(requiredBytes: 110, availableBytes: 100))
        }
        stopHelper(child)
        let recovered = try self.coordinator().reserve([requirement(100)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
        try recovered.release()
    }

    func testKilledProductionCreateWindowsRecoverWithoutDeletingUnverifiedStagingFiles() throws {
        for stage in [StorageSpaceCheckpoint.claimCreated, .indexStagingCreated] {
            let path = root.appendingPathComponent("crash-" + stage.rawValue)
            let child = try startHelper(stage: stage.rawValue, registry: path)
            defer { stopHelper(child) }
            let artifacts = try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent != "index.json" }
            XCTAssertEqual(artifacts.count, stage == .claimCreated ? 1 : 2)
            let originalBytes = try artifacts.map { try Data(contentsOf: $0) }
            stopHelper(child)
            let recovered = try StorageSpaceCoordinator(directory: path, capacityProvider: { _ in .init(volumeID: "a", availableBytes: 100) })
            let lease = try recovered.reserve([requirement(100)])
            try lease.validateDestinations(); try lease.release()
            for (artifact, bytes) in zip(artifacts, originalBytes) { XCTAssertEqual(try Data(contentsOf: artifact), bytes) }
            // A familiar staging prefix alone is never recovery authority.
            let unknown = path.appendingPathComponent(".index-" + UUID().uuidString)
            try Data("not registered".utf8).write(to: unknown)
            XCTAssertThrowsError(try recovered.reserve([requirement(1)])) {
                XCTAssertEqual($0 as? StorageWriteFailure, .coordinationUnavailable)
            }
            XCTAssertEqual(try Data(contentsOf: unknown), Data("not registered".utf8))
        }
    }

    func testReplacementPublicationCrashRecoversBothVerifiedClaims() throws {
        let child = try startHelper(stage: StorageSpaceCheckpoint.replacementPublished.rawValue, registry: registry)
        defer { stopHelper(child) }
        let previous = try records()
        XCTAssertEqual(previous.count, 2, "Both files exist at publication; only the replacement retains a live claim")
        stopHelper(child)
        let recovered = try coordinator().reserve([requirement(100)])
        for old in previous { XCTAssertFalse(FileManager.default.fileExists(atPath: old.path)) }
        XCTAssertEqual(try records().count, 1)
        try recovered.release()
    }

    func testGrowingOneLeaseExcludesItsOldBudgetAndKeepsDescriptorAndRegistryCountsBounded() throws {
        capacity.set("volume-a", volume: "a", available: 10_000)
        let coordinator = try coordinator(), lease = try coordinator.reserve([requirement(1)])
        let other = try self.coordinator().reserve([requirement(100)])
        let baseline = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        for _ in 0..<128 {
            try lease.addRequirements([requirement(1)])
            XCTAssertEqual(try records().count, 2)
            XCTAssertLessThanOrEqual(try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count, baseline + 8)
        }
        capacity.set("volume-a", volume: "a", available: 230)
        try lease.addRequirements([requirement(1)]) // 130 + the other process's 100, not 129 + 130 + 100.
        XCTAssertThrowsError(try lease.addRequirements([requirement(1)])) {
            XCTAssertEqual($0 as? StorageWriteFailure, .insufficientSpace(requiredBytes: 231, availableBytes: 230))
        }
        try lease.revalidate()
        XCTAssertThrowsError(try self.coordinator().reserve([requirement(1)])) {
            XCTAssertEqual($0 as? StorageWriteFailure, .insufficientSpace(requiredBytes: 231, availableBytes: 230))
        }
        try other.release(); try lease.release()
        XCTAssertTrue(try records().isEmpty)
        let next = try self.coordinator().reserve([requirement(230)]); try next.release()
    }

    func testAddingToAnEmptyLeaseAndInvalidIncreasesPreserveItsExistingProtection() throws {
        let coordinator = try coordinator(), lease = try coordinator.reserve([])
        try lease.addRequirements([requirement(60)])
        for bytes in [Int64(-1), Int64.max] {
            XCTAssertThrowsError(try lease.addRequirements([requirement(bytes)])) {
                XCTAssertEqual($0 as? StorageWriteFailure, .invalidRequirement)
            }
        }
        try lease.addRequirements([requirement(0)])
        XCTAssertThrowsError(try self.coordinator().reserve([requirement(41)])) {
            XCTAssertEqual($0 as? StorageWriteFailure, .insufficientSpace(requiredBytes: 101, availableBytes: 100))
        }
        try lease.validateDestinations(); try lease.release()
        XCTAssertThrowsError(try lease.addRequirements([requirement(1)])) {
            XCTAssertEqual($0 as? StorageWriteFailure, .releasedLease)
        }
    }

    func testIndexReadWriteAndAppendShareOneFourThousandEntryBound() throws {
        XCTAssertEqual(StorageSpaceCoordinator.maximumIndexEntries, 4_000)
        try StorageSpaceCoordinator.validateIndexEntryCount(4_000)
        try StorageSpaceCoordinator.validateIndexEntryCount(3_999, appending: true)
        for (count, appending) in [(4_000, true), (4_001, false), (-1, false)] {
            XCTAssertThrowsError(try StorageSpaceCoordinator.validateIndexEntryCount(count, appending: appending)) {
                XCTAssertEqual($0 as? StorageWriteFailure, .invalidRequirement)
            }
        }
    }

    func testActualWriteFailureClassificationDoesNotConfuseOtherErrorsWithDiskFull() {
        XCTAssertEqual(StorageWriteFailure.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))), .diskFull)
        XCTAssertEqual(StorageWriteFailure.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(EDQUOT))), .diskFull)
        XCTAssertEqual(StorageWriteFailure.classify(NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileWriteOutOfSpace.rawValue)), .diskFull)
        let nested = NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileWriteUnknown.rawValue,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        XCTAssertEqual(StorageWriteFailure.classify(nested), .diskFull)
        XCTAssertEqual(StorageWriteFailure.classify(HistoryStoreError.database(code: SQLITE_FULL, message: "full")), .diskFull)
        XCTAssertEqual(StorageWriteFailure.classify(HistoryStoreError.database(code: SQLITE_FULL | 0x100, message: "extended")), .diskFull)
        XCTAssertNil(StorageWriteFailure.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        XCTAssertNil(StorageWriteFailure.classify(HistoryStoreError.database(code: SQLITE_BUSY, message: "busy")))
        XCTAssertEqual(StorageWriteFailure.classify(StorageWriteFailure.destinationChanged), .destinationChanged)
    }
}
