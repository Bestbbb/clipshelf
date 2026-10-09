import Darwin
import Foundation

public struct StorageSpaceRequirement: Sendable {
    public let destination: URL
    public let bytes: Int64
    public init(destination: URL, bytes: Int64) { self.destination = destination; self.bytes = bytes }
}

public struct StorageVolumeCapacity: Sendable {
    public let volumeID: String
    public let availableBytes: Int64?
    public init(volumeID: String, availableBytes: Int64?) { self.volumeID = volumeID; self.availableBytes = availableBytes }
}

/// Receives the validated existing directory that currently contains the destination.
public typealias StorageCapacityProvider = @Sendable (URL) throws -> StorageVolumeCapacity

private struct StorageSpaceClaim: Codable, Equatable {
    let volumeID: String
    let bytes: Int64
}

private struct StorageSpaceRecord: Codable, Equatable {
    let version: Int
    let id: UUID
    let identity: StorageSpaceNode
    let claims: [StorageSpaceClaim]
    var filename: String { id.uuidString + ".json" }
}

private struct StorageSpaceRegistry: Codable, Equatable {
    let version: Int
    let lockIdentity: StorageSpaceNode
    let directoryIdentity: StorageSpaceNode
}

private struct StorageSpaceIndexEntry: Codable {
    let record: StorageSpaceRecord
    var retired: Bool
}

private struct StorageSpaceIndex: Codable {
    let version: Int
    let registryIdentity: StorageSpaceNode
    var entries: [StorageSpaceIndexEntry]
}

private struct StorageSpaceTarget {
    let destination: StorageSpaceDestination
    let volumeID: String
    let bytes: Int64
}

private struct StorageSpacePendingState: Codable {
    let version: Int
    let registryIdentity: StorageSpaceNode
    var sequence: Int64
    var pending: Set<String>
    var preserved: Set<String>
}

enum StorageSpaceCheckpoint: String, Sendable { case claimCreated, indexStagingCreated, replacementPublished }

/// Coordinates participating processes' pending write budgets. It does not allocate or physically
/// reserve disk blocks, and it does not impose a total library quota. All participants must use the
/// same directory. The short registry lock must never call back into a HistoryStore or wait for SQLite.
public final class StorageSpaceCoordinator: @unchecked Sendable {
    public let directory: URL
    private let capacityProvider: StorageCapacityProvider
    private let lock = NSLock()
    private var knownParent: (URL, StorageSpaceNode)?
    private var knownRegistry: StorageSpaceRegistry?
    private var journal: (descriptor: Int32, state: StorageSpacePendingState)?
    private let checkpoint: (@Sendable (StorageSpaceCheckpoint) -> Void)?
    static let maximumIndexEntries = 4_000
    private static let journalOffset: Int64 = 4_096
    private static let journalSlotBytes = 1_048_576

    /// Initialization is read/write-free so an existing full-disk library can still open for
    /// reading or cleanup. The directory's parent must exist when the first reservation is made.
    public convenience init(directory: URL, capacityProvider: @escaping StorageCapacityProvider = { @Sendable destination in
        try StorageSpaceCoordinator.systemCapacity(for: destination)
    }) throws {
        try self.init(directory: directory, capacityProvider: capacityProvider, checkpoint: nil)
    }

    /// Internal fault/kill checkpoint injection; production callers cannot suspend registry work.
    init(directory: URL, capacityProvider: @escaping StorageCapacityProvider,
         checkpoint: (@Sendable (StorageSpaceCheckpoint) -> Void)?) throws {
        guard StorageSpaceFiles.validURL(directory), directory.path != "/",
              !directory.lastPathComponent.isEmpty, directory.lastPathComponent.utf8.count <= 200 else {
            throw StorageWriteFailure.invalidRequirement
        }
        self.directory = directory.standardizedFileURL
        self.capacityProvider = capacityProvider
        self.checkpoint = checkpoint
    }

    public static func systemCapacity(for destination: URL) throws -> StorageVolumeCapacity {
        guard StorageSpaceFiles.validURL(destination) else { throw StorageWriteFailure.invalidRequirement }
        let descriptor = Darwin.open(destination.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw StorageWriteFailure.capacityUnavailable }
        defer { Darwin.close(descriptor) }
        var information = statfs()
        guard Darwin.fstatfs(descriptor, &information) == 0,
              let blocks = Int64(exactly: information.f_bavail), blocks >= 0,
              let blockSize = Int64(exactly: information.f_bsize), blockSize > 0 else {
            throw StorageWriteFailure.capacityUnavailable
        }
        let (available, overflow) = blocks.multipliedReportingOverflow(by: blockSize)
        guard !overflow else { throw StorageWriteFailure.capacityUnavailable }
        let id = "filesystem:\(information.f_fsid.val.0):\(information.f_fsid.val.1):\(information.f_type)"
        return StorageVolumeCapacity(volumeID: id, availableBytes: available)
    }

    public func reserve(_ requirements: [StorageSpaceRequirement]) throws -> StorageSpaceLease {
        guard requirements.count <= 256, requirements.allSatisfy({ $0.bytes >= 0 && StorageSpaceFiles.validURL($0.destination) }) else {
            throw StorageWriteFailure.invalidRequirement
        }
        let positive = requirements.filter { $0.bytes > 0 }
        if positive.isEmpty { return StorageSpaceLease(coordinator: self, record: nil, targets: [], descriptor: -1) }
        let destinations = try positive.map { (try StorageSpaceDestination($0.destination), $0.bytes) }
        return try withRegistry { registry in
            var targets: [StorageSpaceTarget] = []
            var requested: [String: Int64] = [:], available: [String: Int64] = [:]
            for (destination, bytes) in destinations {
                let capacity = try readCapacity(destination, requireKnownCapacity: true)
                targets.append(StorageSpaceTarget(destination: destination, volumeID: capacity.volumeID, bytes: bytes))
                try Self.add(bytes, volume: capacity.volumeID, to: &requested)
                available[capacity.volumeID] = min(available[capacity.volumeID] ?? Int64.max, capacity.availableBytes!)
            }
            let active = try liveClaims(in: registry)
            try Self.requireCapacity(requested: requested, active: active, available: available)
            var index = try readIndex(in: registry)
            try Self.validateIndexEntryCount(index.entries.count, appending: true)
            let id = UUID(), name = id.uuidString + ".json"
            try beginPending(name)
            let descriptor = openat(registry, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else {
                let error = StorageSpaceFiles.posixFailure()
                try? finishPending(name); throw error
            }
            checkpoint?(.claimCreated)
            var transferred = false
            var indexed = false
            defer {
                if !transferred {
                    if !indexed, let identity = try? StorageSpaceFiles.privateNode(descriptor, directory: false),
                       StorageSpaceFiles.matches(identity, name: name, directory: registry),
                       unlinkat(registry, name, 0) == 0, fsync(registry) == 0 { try? finishPending(name) }
                    Darwin.close(descriptor)
                }
            }
            try StorageSpaceFiles.lock(descriptor)
            let identity = try StorageSpaceFiles.privateNode(descriptor, directory: false)
            let record = StorageSpaceRecord(version: 1, id: id, identity: identity,
                claims: requested.keys.sorted().map { StorageSpaceClaim(volumeID: $0, bytes: requested[$0]!) })
            try StorageSpaceFiles.write(record, descriptor: descriptor)
            guard fsync(registry) == 0 else { throw StorageSpaceFiles.posixFailure() }
            index.entries.append(StorageSpaceIndexEntry(record: record, retired: false))
            try writeIndex(index, in: registry, published: { indexed = true })
            try finishPending(name)
            transferred = true
            return StorageSpaceLease(coordinator: self, record: record, targets: targets, descriptor: descriptor)
        }
    }

    fileprivate func validate(_ record: StorageSpaceRecord, targets: [StorageSpaceTarget], descriptor: Int32,
                              requireCapacity: Bool) throws {
        try withRegistry { registry in
            let index = try readIndex(in: registry)
            guard let entry = index.entries.first(where: { $0.record.id == record.id }), !entry.retired, entry.record == record else {
                throw StorageWriteFailure.coordinationUnavailable
            }
            guard try StorageSpaceFiles.privateNode(descriptor, directory: false) == record.identity,
                  StorageSpaceFiles.matches(record.identity, name: record.filename, directory: registry),
                  try StorageSpaceFiles.read(StorageSpaceRecord.self, descriptor: descriptor) == record else {
                throw StorageWriteFailure.coordinationUnavailable
            }
            var available: [String: Int64] = [:]
            for target in targets {
                let capacity = try readCapacity(target.destination, requireKnownCapacity: requireCapacity)
                guard capacity.volumeID == target.volumeID else { throw StorageWriteFailure.destinationChanged }
                if let bytes = capacity.availableBytes {
                    available[capacity.volumeID] = min(available[capacity.volumeID] ?? Int64.max, bytes)
                }
            }
            if requireCapacity {
                let active = try liveClaims(in: registry, excluding: record.id)
                let requested = Dictionary(uniqueKeysWithValues: record.claims.map { ($0.volumeID, $0.bytes) })
                try Self.requireCapacity(requested: requested, active: active, available: available)
            }
        }
    }

    fileprivate func addRequirements(_ requirements: [StorageSpaceRequirement], to record: StorageSpaceRecord,
                                    targets originalTargets: [StorageSpaceTarget], descriptor originalDescriptor: Int32,
                                    published: (StorageSpaceRecord, [StorageSpaceTarget], Int32) -> Void) throws {
        guard requirements.count <= 256, requirements.allSatisfy({ $0.bytes >= 0 && StorageSpaceFiles.validURL($0.destination) }) else {
            throw StorageWriteFailure.invalidRequirement
        }
        let positive = requirements.filter { $0.bytes > 0 }
        if positive.isEmpty { return }
        let additions = try positive.map { (try StorageSpaceDestination($0.destination), $0.bytes) }
        try withRegistry { registry in
            var index = try readIndex(in: registry)
            guard let old = index.entries.first(where: { $0.record.id == record.id }), !old.retired, old.record == record,
                  try StorageSpaceFiles.privateNode(originalDescriptor, directory: false) == record.identity,
                  StorageSpaceFiles.matches(record.identity, name: record.filename, directory: registry),
                  try StorageSpaceFiles.read(StorageSpaceRecord.self, descriptor: originalDescriptor) == record else {
                throw StorageWriteFailure.coordinationUnavailable
            }
            var targets = originalTargets
            var requested = Dictionary(uniqueKeysWithValues: record.claims.map { ($0.volumeID, $0.bytes) })
            var available: [String: Int64] = [:]
            for target in originalTargets {
                let capacity = try readCapacity(target.destination, requireKnownCapacity: true)
                guard capacity.volumeID == target.volumeID else { throw StorageWriteFailure.destinationChanged }
                available[capacity.volumeID] = min(available[capacity.volumeID] ?? Int64.max, capacity.availableBytes!)
            }
            for (destination, bytes) in additions {
                let capacity = try readCapacity(destination, requireKnownCapacity: true)
                try Self.add(bytes, volume: capacity.volumeID, to: &requested)
                available[capacity.volumeID] = min(available[capacity.volumeID] ?? Int64.max, capacity.availableBytes!)
                if !targets.contains(where: { $0.destination == destination && $0.volumeID == capacity.volumeID }) {
                    targets.append(StorageSpaceTarget(destination: destination, volumeID: capacity.volumeID, bytes: bytes))
                }
            }
            guard requested.count <= 256 else { throw StorageWriteFailure.invalidRequirement }
            let active = try liveClaims(in: registry, excluding: record.id)
            try Self.requireCapacity(requested: requested, active: active, available: available)
            index = try readIndex(in: registry)
            try Self.validateIndexEntryCount(index.entries.count, appending: true)
            let id = UUID(), name = id.uuidString + ".json"
            try beginPending(name)
            let descriptor = openat(registry, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else {
                let error = StorageSpaceFiles.posixFailure(); try? finishPending(name); throw error
            }
            var transferred = false
            defer {
                if !transferred {
                    if let identity = try? StorageSpaceFiles.privateNode(descriptor, directory: false),
                       StorageSpaceFiles.matches(identity, name: name, directory: registry),
                       unlinkat(registry, name, 0) == 0, fsync(registry) == 0 { try? finishPending(name) }
                    Darwin.close(descriptor)
                }
            }
            checkpoint?(.claimCreated)
            try StorageSpaceFiles.lock(descriptor)
            let identity = try StorageSpaceFiles.privateNode(descriptor, directory: false)
            let replacement = StorageSpaceRecord(version: 1, id: id, identity: identity,
                claims: requested.keys.sorted().map { StorageSpaceClaim(volumeID: $0, bytes: requested[$0]!) })
            try StorageSpaceFiles.write(replacement, descriptor: descriptor)
            guard fsync(registry) == 0 else { throw StorageSpaceFiles.posixFailure() }
            for offset in index.entries.indices where index.entries[offset].record.id == record.id { index.entries[offset].retired = true }
            index.entries.append(StorageSpaceIndexEntry(record: replacement, retired: false))
            try writeIndex(index, in: registry, published: {
                // Rename makes the new claim authoritative. Swap ownership before releasing
                // the registry lock, even if a following durability/cleanup operation fails.
                published(replacement, targets, descriptor)
                transferred = true
                Darwin.close(originalDescriptor)
                checkpoint?(.replacementPublished)
            })
            try finishPending(name)
            _ = try liveClaims(in: registry)
        }
    }

    fileprivate func remove(_ record: StorageSpaceRecord) throws {
        try withRegistry { registry in
            let index = try readIndex(in: registry)
            guard let entry = index.entries.first(where: { $0.record.id == record.id }) else {
                guard !(try StorageSpaceFiles.exists(record.filename, directory: registry)) else { throw StorageWriteFailure.coordinationUnavailable }
                return
            }
            guard entry.record == record else { throw StorageWriteFailure.coordinationUnavailable }
            _ = try liveClaims(in: registry)
        }
    }

    private func readCapacity(_ destination: StorageSpaceDestination, requireKnownCapacity: Bool) throws -> StorageVolumeCapacity {
        let path = try destination.currentDirectory()
        let capacity: StorageVolumeCapacity
        do { capacity = try capacityProvider(path) }
        catch { throw StorageWriteFailure.capacityUnavailable }
        guard !capacity.volumeID.isEmpty, capacity.volumeID.utf8.count <= 256, !capacity.volumeID.utf8.contains(0),
              capacity.availableBytes.map({ $0 >= 0 }) ?? !requireKnownCapacity else { throw StorageWriteFailure.capacityUnavailable }
        guard try destination.currentDirectory() == path else { throw StorageWriteFailure.destinationChanged }
        return capacity
    }

    private static func add(_ bytes: Int64, volume: String, to values: inout [String: Int64]) throws {
        let (total, overflow) = (values[volume] ?? 0).addingReportingOverflow(bytes)
        guard bytes >= 0, !overflow else { throw StorageWriteFailure.invalidRequirement }
        values[volume] = total
    }

    private static func requireCapacity(requested: [String: Int64], active: [String: Int64], available: [String: Int64]) throws {
        for volume in requested.keys.sorted() {
            let (required, overflow) = requested[volume]!.addingReportingOverflow(active[volume] ?? 0)
            guard !overflow else { throw StorageWriteFailure.invalidRequirement }
            guard let free = available[volume] else { throw StorageWriteFailure.capacityUnavailable }
            guard required <= free else { throw StorageWriteFailure.insufficientSpace(requiredBytes: required, availableBytes: free) }
        }
    }

    private func liveClaims(in registry: Int32, excluding excluded: UUID? = nil) throws -> [String: Int64] {
        var result: [String: Int64] = [:]
        var index = try readIndex(in: registry)
        let expectedNames = Set(index.entries.map { $0.record.filename }).union(["index.json"]).union(journal?.state.preserved ?? [])
        guard Set(try StorageSpaceFiles.names(registry)).isSubset(of: expectedNames) else { throw StorageWriteFailure.coordinationUnavailable }
        var retiring = Set<UUID>()
        for entry in index.entries {
            let record = entry.record, name = record.filename, id = record.id
            if !(try StorageSpaceFiles.exists(name, directory: registry)) {
                guard entry.retired else { throw StorageWriteFailure.coordinationUnavailable }
                retiring.insert(id); continue
            }
            let descriptor = openat(registry, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw StorageWriteFailure.coordinationUnavailable }
            defer { Darwin.close(descriptor) }
            let identity = try StorageSpaceFiles.privateNode(descriptor, directory: false)
            let stored = try StorageSpaceFiles.read(StorageSpaceRecord.self, descriptor: descriptor)
            guard stored == record, record.identity == identity,
                  StorageSpaceFiles.matches(identity, name: name, directory: registry) else { throw StorageWriteFailure.coordinationUnavailable }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                // A valid descriptor with no live lock holder is proof of termination, not age.
                retiring.insert(id)
            } else {
                guard !entry.retired, errno == EWOULDBLOCK || errno == EAGAIN else { throw StorageWriteFailure.coordinationUnavailable }
                if id != excluded { for claim in record.claims { try Self.add(claim.bytes, volume: claim.volumeID, to: &result) } }
            }
        }
        if !retiring.isEmpty {
            // Durable retirement distinguishes a missing already-removed file from an
            // active claim whose lock file was lost. Cleanup can resume after either crash gap.
            for offset in index.entries.indices where retiring.contains(index.entries[offset].record.id) { index.entries[offset].retired = true }
            try writeIndex(index, in: registry)
            for entry in index.entries where retiring.contains(entry.record.id) {
                let record = entry.record
                guard try StorageSpaceFiles.exists(record.filename, directory: registry) else { continue }
                let descriptor = openat(registry, record.filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard descriptor >= 0 else { throw StorageWriteFailure.coordinationUnavailable }
                defer { Darwin.close(descriptor) }
                guard try StorageSpaceFiles.privateNode(descriptor, directory: false) == record.identity,
                      try StorageSpaceFiles.read(StorageSpaceRecord.self, descriptor: descriptor) == record,
                      flock(descriptor, LOCK_EX | LOCK_NB) == 0,
                      StorageSpaceFiles.matches(record.identity, name: record.filename, directory: registry),
                      unlinkat(registry, record.filename, 0) == 0 else { throw StorageWriteFailure.coordinationUnavailable }
            }
            guard fsync(registry) == 0 else { throw StorageSpaceFiles.posixFailure() }
            index.entries.removeAll { retiring.contains($0.record.id) }
            try writeIndex(index, in: registry)
        }
        return result
    }

    private func readIndex(in registry: Int32) throws -> StorageSpaceIndex {
        let descriptor = openat(registry, "index.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw StorageWriteFailure.coordinationUnavailable }
        defer { Darwin.close(descriptor) }
        let identity = try StorageSpaceFiles.privateNode(descriptor, directory: false)
        let index = try StorageSpaceFiles.read(StorageSpaceIndex.self, descriptor: descriptor)
        guard index.version == 1, index.registryIdentity == StorageSpaceNode(try StorageSpaceFiles.info(registry)),
              index.entries.count <= Self.maximumIndexEntries, Set(index.entries.map { $0.record.id }).count == index.entries.count,
              StorageSpaceFiles.matches(identity, name: "index.json", directory: registry) else { throw StorageWriteFailure.coordinationUnavailable }
        for entry in index.entries {
            let record = entry.record
            guard record.version == 1, !record.claims.isEmpty, record.claims.count <= 256,
                  Set(record.claims.map(\.volumeID)).count == record.claims.count,
                  record.claims.allSatisfy({ !$0.volumeID.isEmpty && $0.volumeID.utf8.count <= 256 && !$0.volumeID.utf8.contains(0) && $0.bytes > 0 }) else {
                throw StorageWriteFailure.coordinationUnavailable
            }
        }
        return index
    }

    private func writeIndex(_ index: StorageSpaceIndex, in registry: Int32, published: () -> Void = {}) throws {
        try Self.validateIndexEntryCount(index.entries.count)
        let name = ".index-" + UUID().uuidString
        try beginPending(name)
        let descriptor = openat(registry, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            let error = StorageSpaceFiles.posixFailure()
            try? finishPending(name); throw error
        }
        defer { Darwin.close(descriptor) }
        checkpoint?(.indexStagingCreated)
        let identity = try StorageSpaceFiles.privateNode(descriptor, directory: false)
        defer {
            if StorageSpaceFiles.matches(identity, name: name, directory: registry),
               unlinkat(registry, name, 0) == 0, fsync(registry) == 0 { try? finishPending(name) }
        }
        try StorageSpaceFiles.write(index, descriptor: descriptor)
        guard StorageSpaceFiles.matches(identity, name: name, directory: registry), renameat(registry, name, registry, "index.json") == 0 else {
            throw StorageSpaceFiles.posixFailure()
        }
        published()
        guard fsync(registry) == 0 else { throw StorageSpaceFiles.posixFailure() }
        try finishPending(name)
    }

    static func validateIndexEntryCount(_ count: Int, appending: Bool = false) throws {
        guard count >= 0, count <= maximumIndexEntries - (appending ? 1 : 0) else { throw StorageWriteFailure.invalidRequirement }
    }

    private static func validPendingName(_ name: String) -> Bool {
        if name.hasPrefix(".index-") { return UUID(uuidString: String(name.dropFirst(7)))?.uuidString == String(name.dropFirst(7)) }
        return name.hasSuffix(".json") && UUID(uuidString: String(name.dropLast(5)))?.uuidString == String(name.dropLast(5))
    }

    private func loadJournal(descriptor: Int32, identity: StorageSpaceNode) throws -> StorageSpacePendingState {
        let states = try [0, 1].compactMap { slot in
            try StorageSpaceFiles.readFrame(StorageSpacePendingState.self, descriptor: descriptor,
                offset: Self.journalOffset + Int64(slot * Self.journalSlotBytes), maximumBytes: Self.journalSlotBytes - 40)
        }.filter {
            $0.version == 1 && $0.registryIdentity == identity && $0.sequence >= 0 && $0.pending.count <= 2 &&
                $0.preserved.count <= Self.maximumIndexEntries && $0.pending.isDisjoint(with: $0.preserved) &&
                $0.pending.union($0.preserved).allSatisfy(Self.validPendingName)
        }
        guard let state = states.max(by: { $0.sequence < $1.sequence }) else { throw StorageWriteFailure.coordinationUnavailable }
        return state
    }

    private func saveJournal(_ state: StorageSpacePendingState) throws {
        guard let previous = journal, previous.state.sequence < Int64.max, state.pending.count <= 2,
              state.preserved.count <= Self.maximumIndexEntries else { throw StorageWriteFailure.coordinationUnavailable }
        var next = state; next.sequence = previous.state.sequence + 1
        try StorageSpaceFiles.writeFrame(next, descriptor: previous.descriptor,
            offset: Self.journalOffset + Int64(next.sequence % 2) * Int64(Self.journalSlotBytes), maximumBytes: Self.journalSlotBytes - 40)
        journal = (previous.descriptor, next)
    }

    private func beginPending(_ name: String) throws {
        guard var state = journal?.state, Self.validPendingName(name), !state.pending.contains(name),
              !state.preserved.contains(name) else { throw StorageWriteFailure.coordinationUnavailable }
        state.pending.insert(name); try saveJournal(state)
    }

    private func finishPending(_ name: String) throws {
        guard var state = journal?.state else { throw StorageWriteFailure.coordinationUnavailable }
        guard state.pending.remove(name) != nil else { return }
        try saveJournal(state)
    }

    private func recoverPending(in registry: Int32) throws {
        guard var state = journal?.state, !state.pending.isEmpty else { return }
        let index = try readIndex(in: registry)
        for name in state.pending {
            guard try StorageSpaceFiles.exists(name, directory: registry) else { continue }
            if let entry = index.entries.first(where: { $0.record.filename == name }) {
                guard StorageSpaceFiles.matches(entry.record.identity, name: name, directory: registry) else {
                    throw StorageWriteFailure.coordinationUnavailable
                }
            } else {
                // A crash can happen immediately after create, before an inode proof was saved.
                // Preserve that recorded staging path rather than deleting unverified bytes.
                // Only a durable pending intent grants this exception; arbitrary names do not.
                state.preserved.insert(name)
            }
        }
        // A prior process may have failed after rename/unlink but before its directory fsync.
        // Never retire that intent durably until the directory's current state is durable too.
        guard fsync(registry) == 0 else { throw StorageSpaceFiles.posixFailure() }
        state.pending.removeAll(); try saveJournal(state)
    }

    private func withRegistry<T>(_ operation: (Int32) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let parentURL: URL
        do { parentURL = try StorageSpaceFiles.canonicalDirectory(directory.deletingLastPathComponent()) }
        catch { throw StorageWriteFailure.coordinationUnavailable }
        let parent = try StorageSpaceFiles.openDirectory(parentURL)
        defer { Darwin.close(parent) }
        let parentIdentity = StorageSpaceNode(try StorageSpaceFiles.info(parent))
        if let knownParent, knownParent.0 != parentURL || knownParent.1 != parentIdentity { throw StorageWriteFailure.coordinationUnavailable }
        let name = directory.lastPathComponent, lockName = name + ".lock"
        var created = false
        var descriptor = openat(parent, lockName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if descriptor >= 0 { created = true }
        else {
            guard errno == EEXIST else { throw StorageSpaceFiles.posixFailure() }
            descriptor = openat(parent, lockName, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw StorageWriteFailure.coordinationUnavailable }
        defer { Darwin.close(descriptor) }
        let lockIdentity = try StorageSpaceFiles.privateNode(descriptor, directory: false)
        try StorageSpaceFiles.lock(descriptor)
        guard StorageSpaceFiles.matches(lockIdentity, name: lockName, directory: parent) else { throw StorageWriteFailure.coordinationUnavailable }
        var createdDirectory: StorageSpaceNode?
        var createdIndex: StorageSpaceNode?
        var initialized = false
        defer {
            if created && !initialized {
                if let identity = createdDirectory, StorageSpaceFiles.matches(identity, name: name, directory: parent) {
                    let root = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    if root >= 0 {
                        if let createdIndex, StorageSpaceFiles.matches(createdIndex, name: "index.json", directory: root) { _ = unlinkat(root, "index.json", 0) }
                        Darwin.close(root)
                    }
                    _ = unlinkat(parent, name, AT_REMOVEDIR)
                }
                if StorageSpaceFiles.matches(lockIdentity, name: lockName, directory: parent) { _ = unlinkat(parent, lockName, 0) }
            }
        }
        let header: StorageSpaceRegistry
        if created {
            guard knownRegistry == nil, !(try StorageSpaceFiles.exists(name, directory: parent)) else {
                throw StorageWriteFailure.coordinationUnavailable
            }
            guard mkdirat(parent, name, 0o700) == 0 else { throw StorageSpaceFiles.posixFailure() }
            let root = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard root >= 0 else { throw StorageWriteFailure.coordinationUnavailable }
            defer { Darwin.close(root) }
            let identity = try StorageSpaceFiles.privateNode(root, directory: true); createdDirectory = identity
            let initial = openat(root, "index.json", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard initial >= 0 else { throw StorageSpaceFiles.posixFailure() }
            defer { Darwin.close(initial) }
            createdIndex = try StorageSpaceFiles.privateNode(initial, directory: false)
            try StorageSpaceFiles.write(StorageSpaceIndex(version: 1, registryIdentity: identity, entries: []), descriptor: initial)
            guard fsync(root) == 0 else { throw StorageSpaceFiles.posixFailure() }
            header = StorageSpaceRegistry(version: 2, lockIdentity: lockIdentity, directoryIdentity: identity)
            try StorageSpaceFiles.writeFrame(header, descriptor: descriptor, offset: 0, maximumBytes: Int(Self.journalOffset) - 40)
            try StorageSpaceFiles.writeFrame(StorageSpacePendingState(version: 1, registryIdentity: identity, sequence: 0, pending: [], preserved: []),
                descriptor: descriptor, offset: Self.journalOffset, maximumBytes: Self.journalSlotBytes - 40)
            guard fsync(parent) == 0 else { throw StorageSpaceFiles.posixFailure() }
        } else {
            guard let stored = try StorageSpaceFiles.readFrame(StorageSpaceRegistry.self, descriptor: descriptor, offset: 0,
                maximumBytes: Int(Self.journalOffset) - 40) else { throw StorageWriteFailure.coordinationUnavailable }
            header = stored
        }
        guard header.version == 2, header.lockIdentity == lockIdentity,
              knownRegistry == nil || knownRegistry == header,
              StorageSpaceFiles.matches(header.directoryIdentity, name: name, directory: parent) else {
            throw StorageWriteFailure.coordinationUnavailable
        }
        let root = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw StorageWriteFailure.coordinationUnavailable }
        defer { Darwin.close(root) }
        guard try StorageSpaceFiles.privateNode(root, directory: true) == header.directoryIdentity else { throw StorageWriteFailure.coordinationUnavailable }
        initialized = true; knownParent = (parentURL, parentIdentity); knownRegistry = header
        journal = (descriptor, try loadJournal(descriptor: descriptor, identity: header.directoryIdentity))
        defer { journal = nil }
        try recoverPending(in: root)
        let result = try operation(root)
        guard StorageSpaceFiles.matches(lockIdentity, name: lockName, directory: parent),
              StorageSpaceFiles.matches(header.directoryIdentity, name: name, directory: parent) else {
            throw StorageWriteFailure.coordinationUnavailable
        }
        return result
    }
}

/// A live cross-process budget claim, not physically allocated disk space. Retain it until writes
/// and rollback have finished. Deinitialization releases only its kernel lock and never waits for
/// a registry/SQLite lock; the next reservation safely removes the valid inactive record.
public final class StorageSpaceLease: @unchecked Sendable {
    private let coordinator: StorageSpaceCoordinator
    private var record: StorageSpaceRecord?
    private var targets: [StorageSpaceTarget]
    private let lock = NSLock()
    private var descriptor: Int32
    private var active = true

    fileprivate init(coordinator: StorageSpaceCoordinator, record: StorageSpaceRecord?, targets: [StorageSpaceTarget], descriptor: Int32) {
        self.coordinator = coordinator; self.record = record; self.targets = targets; self.descriptor = descriptor
    }

    /// Before writing: verifies identities and the original full budget again. Do not call after
    /// consuming part of the budget; use validateDestinations before publishing an already written file.
    public func revalidate() throws { try validate(requireCapacity: true) }

    /// After writing: checks identity and the live claim without charging the full byte budget again.
    public func validateDestinations() throws { try validate(requireCapacity: false) }

    /// Adds pending work to the same transaction claim without accumulating live descriptors.
    /// Capacity checks exclude this lease's old claim and include its full increased budget.
    /// A failure always retains protection for the old demand; after publication it can retain
    /// the larger claim, so callers should still release the lease after rollback.
    public func addRequirements(_ requirements: [StorageSpaceRequirement]) throws {
        lock.lock(); defer { lock.unlock() }
        guard active else { throw StorageWriteFailure.releasedLease }
        if let record {
            try coordinator.addRequirements(requirements, to: record, targets: targets, descriptor: descriptor) { replacement, targets, descriptor in
                self.record = replacement; self.targets = targets; self.descriptor = descriptor
            }
        } else {
            let replacement = try coordinator.reserve(requirements)
            self.record = replacement.record; self.targets = replacement.targets; self.descriptor = replacement.descriptor
            replacement.descriptor = -1; replacement.active = false
        }
    }

    private func validate(requireCapacity: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard active else { throw StorageWriteFailure.releasedLease }
        if let record { try coordinator.validate(record, targets: targets, descriptor: descriptor, requireCapacity: requireCapacity) }
    }

    public func release() throws {
        lock.lock()
        guard active else { lock.unlock(); return }
        active = false; let retired = descriptor; descriptor = -1
        lock.unlock()
        // Release the live lock even if removing the registry entry later fails.
        if retired >= 0 { Darwin.close(retired) }
        if let record { try coordinator.remove(record) }
    }

    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
}
