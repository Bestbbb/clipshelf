import Darwin
import Foundation

/// Filesystem-only observation. It never creates directories, resolves clipboard URLs or holds a database lock.
public enum StorageUsageScanner {
    public static func scan(scope: StorageUsageScope, cancellation: HistoryReadCancellation? = nil,
                            limits: StorageUsageLimits = .init()) throws -> StorageUsageReport {
        try scan(scope: scope, cancellation: cancellation, limits: limits, hooks: .init())
    }
    static func scan(scope: StorageUsageScope, cancellation: HistoryReadCancellation? = nil,
                     limits: StorageUsageLimits = .init(), hooks: StorageUsageScanHooks) throws -> StorageUsageReport {
        try StorageUsageWalk(scope: scope, cancellation: cancellation, limits: limits, hooks: hooks).run()
    }
}

/// Only isolated tests can pause a walk or replace an entry at descriptor boundaries.
struct StorageUsageScanHooks: @unchecked Sendable {
    var didOpenDirectory: ((URL) -> Void)?
    var willOpenEntry: ((URL) -> Void)?
}

private struct UsageIdentity: Hashable {
    let device: Int64
    let inode: UInt64
}
private struct UsageNode: Equatable {
    let identity: UsageIdentity
    let mode: mode_t
    let size: Int64
    let blocks: Int64
    let links: UInt16
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
    init(_ value: stat) {
        identity = UsageIdentity(device: Int64(value.st_dev), inode: UInt64(value.st_ino))
        mode = value.st_mode; size = Int64(value.st_size); blocks = Int64(value.st_blocks)
        links = UInt16(value.st_nlink)
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
    }
    var kind: mode_t { mode & S_IFMT }
    var volume: String { String(identity.device) }
}
private struct UsageKey: Hashable {
    let category: String
    let scope: String
    let volume: String
}
private struct UsageOpenError: Error {
    let reason: StorageUsageIssueReason
    let code: Int32?
}

private final class StorageUsageWalk {
    let scope: StorageUsageScope
    let cancellation: HistoryReadCancellation?
    let limits: StorageUsageLimits
    let hooks: StorageUsageScanHooks
    let startedAt = Date()
    let startedUptime = ProcessInfo.processInfo.systemUptime
    var issues: [StorageUsageIssue] = []
    var issueCount = 0
    var measurements: [UsageKey: StorageUsageMeasurement] = [:]
    var roots: [StorageUsageRootResult] = []
    var seen: [UsageIdentity: UsageNode] = [:]
    var examined = 0
    var stopped = false
    var totals = StorageUsageTotals()
    var validRoots: [StorageUsageRoot] = []

    init(scope: StorageUsageScope, cancellation: HistoryReadCancellation?, limits: StorageUsageLimits, hooks: StorageUsageScanHooks) {
        self.scope = scope; self.cancellation = cancellation; self.limits = limits; self.hooks = hooks
    }

    func run() throws -> StorageUsageReport {
        try checkCancellation()
        let ordered = scope.roots.sorted {
            if $0.id != $1.id { return $0.id < $1.id }
            if $0.url?.path != $1.url?.path { return ($0.url?.path ?? "") < ($1.url?.path ?? "") }
            if $0.scopeKind.rawValue != $1.scopeKind.rawValue { return $0.scopeKind.rawValue < $1.scopeKind.rawValue }
            return $0.category.rawValue < $1.category.rawValue
        }
        var ids = Set<String>(), paths = Set<String>()
        for root in ordered {
            if !ids.insert(root.id).inserted || root.url.map({ !paths.insert($0.path).inserted }) == true {
                issue(root, "", .overlappingScope)
                roots.append(.init(root: root, status: .unavailable, volumeID: nil))
            } else { validRoots.append(root) }
        }
        for root in validRoots {
            try checkCancellation()
            guard let url = root.url else {
                issue(root, "", .unavailableRoot)
                roots.append(.init(root: root, status: .unavailable, volumeID: nil)); continue
            }
            guard url.isFileURL, !url.path.utf8.contains(0), url.path.hasPrefix("/"),
                  !scope.databaseName.isEmpty, !scope.databaseName.contains("/"), !scope.databaseName.utf8.contains(0) else {
                issue(root, "", .invalidRoot)
                roots.append(.init(root: root, status: .unavailable, volumeID: nil)); continue
            }
            let before = issueCount
            guard try budget(root, "") else {
                roots.append(.init(root: root, status: .partial, volumeID: nil)); continue
            }
            do {
                let descriptor = try openRoot(url)
                defer { Darwin.close(descriptor) }
                let initial = try node(descriptor)
                try visitDirectory(descriptor, root: root, components: [], expected: initial, depth: 0)
                // A renamed root remains readable through its descriptor. Verify that its
                // original absolute spelling still refers to that directory at completion.
                do {
                    let reopened = try openRoot(url); defer { Darwin.close(reopened) }
                    if try node(reopened).identity != initial.identity { issue(root, "", .changedDuringScan) }
                } catch { issue(root, "", .changedDuringScan, code: (error as? UsageOpenError)?.code) }
                roots.append(.init(root: root, status: issueCount == before ? .measured : .partial, volumeID: initial.volume))
            } catch is CancellationError { throw CancellationError() }
            catch let error as UsageOpenError {
                if error.code == ENOENT && root.optional {
                    roots.append(.init(root: root, status: .notPresent, volumeID: nil))
                } else {
                    issue(root, "", error.reason, code: error.code)
                    roots.append(.init(root: root, status: .unavailable, volumeID: nil))
                }
            }
        }
        try checkCancellation()
        let values = measurements.values.sorted {
            if $0.scopeKind.rawValue != $1.scopeKind.rawValue { return $0.scopeKind.rawValue < $1.scopeKind.rawValue }
            if $0.category.rawValue != $1.category.rawValue { return $0.category.rawValue < $1.category.rawValue }
            return $0.volumeID < $1.volumeID
        }
        return StorageUsageReport(scope: scope, startedAt: startedAt, finishedAt: Date(), roots: roots,
            measurements: values, issues: issues, omittedIssueCount: issueCount - issues.count, examinedEntryCount: examined)
    }

    func checkCancellation() throws {
        try Task.checkCancellation()
        try cancellation?.checkCancellation()
    }
    func budget(_ root: StorageUsageRoot, _ path: String) throws -> Bool {
        try checkCancellation()
        if stopped { return false }
        if ProcessInfo.processInfo.systemUptime - startedUptime >= limits.maximumDuration {
            issue(root, path, .timeLimit); stopped = true; return false
        }
        if examined >= limits.maximumEntries {
            issue(root, path, .entryLimit); stopped = true; return false
        }
        examined += 1
        return true
    }
    func issue(_ root: StorageUsageRoot, _ path: String, _ reason: StorageUsageIssueReason, code: Int32? = nil) {
        issueCount += 1
        if issues.count < limits.maximumIssues {
            issues.append(.init(rootID: root.id, relativePath: path, reason: reason, errorCode: code))
        }
    }
    func node(_ fd: Int32) throws -> UsageNode {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw UsageOpenError(reason: .unreadable, code: errno) }
        return UsageNode(info)
    }
    func node(parent: Int32, name: String) throws -> UsageNode {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw UsageOpenError(reason: errno == ENOENT ? .changedDuringScan : .unreadable, code: errno)
        }
        return UsageNode(info)
    }
    func openRoot(_ url: URL) throws -> Int32 {
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw UsageOpenError(reason: .unreadable, code: errno) }
        do {
            for component in url.pathComponents where component != "/" {
                try checkCancellation()
                guard component != ".", component != "..", !component.isEmpty else {
                    throw UsageOpenError(reason: .invalidRoot, code: nil)
                }
                let expected = try node(parent: current, name: component)
                guard expected.kind != S_IFLNK else { throw UsageOpenError(reason: .symbolicLink, code: ELOOP) }
                guard expected.kind == S_IFDIR else { throw UsageOpenError(reason: .invalidRoot, code: ENOTDIR) }
                let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw UsageOpenError(reason: .unreadable, code: errno) }
                do {
                    guard try node(next).identity == expected.identity,
                          try node(parent: current, name: component).identity == expected.identity else {
                        throw UsageOpenError(reason: .changedDuringScan, code: nil)
                    }
                } catch { Darwin.close(next); throw error }
                Darwin.close(current); current = next
            }
            return current
        } catch { Darwin.close(current); throw error }
    }

    func visitDirectory(_ descriptor: Int32, root: StorageUsageRoot, components: [String], expected: UsageNode, depth: Int) throws {
        try checkCancellation()
        let path = components.joined(separator: "/")
        let category = classify(root: root, components: components, kind: S_IFDIR)
        if let previous = seen[expected.identity] {
            if previous != expected { issue(root, path, .changedDuringScan) }
            return
        }
        seen[expected.identity] = expected
        record(expected, root: root, path: path, category: category)
        let url = components.reduce(root.url!) { $0.appendingPathComponent($1) }
        hooks.didOpenDirectory?(url)
        try checkCancellation()
        guard depth <= limits.maximumDepth else { issue(root, path, .depthLimit); return }
        let names = try directoryNames(descriptor, root: root, path: path)
        for name in names {
            let childComponents = components + [name], childPath = childComponents.joined(separator: "/")
            let childURL = url.appendingPathComponent(name)
            // An explicitly supplied child scope owns its entire subtree, including metadata.
            if validRoots.contains(where: { $0.url?.path == childURL.path && $0.url?.path != root.url?.path }) { continue }
            guard try budget(root, childPath) else { break }
            var observed: UsageNode?
            var observedCategory = StorageUsageCategory.unknown
            do {
                let initial = try node(parent: descriptor, name: name)
                let category = classify(root: root, components: childComponents, kind: initial.kind)
                observed = initial; observedCategory = category
                if category == .unknown { issue(root, childPath, .unknownLayout) }
                if initial.kind == S_IFLNK {
                    issue(root, childPath, .symbolicLink); skipped(initial, root: root, category: category); continue
                }
                guard initial.kind == S_IFDIR || initial.kind == S_IFREG else {
                    issue(root, childPath, .unsupportedFileType); skipped(initial, root: root, category: category); continue
                }
                hooks.willOpenEntry?(childURL)
                try checkCancellation()
                let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (initial.kind == S_IFDIR ? O_DIRECTORY : 0)
                let child = openat(descriptor, name, flags)
                guard child >= 0 else {
                    let code = errno
                    throw UsageOpenError(reason: code == ELOOP || code == ENOTDIR || code == ENOENT ? .changedDuringScan : .unreadable, code: code)
                }
                defer { Darwin.close(child) }
                let opened = try node(child)
                guard opened == initial else { throw UsageOpenError(reason: .changedDuringScan, code: nil) }
                if initial.kind == S_IFDIR {
                    try visitDirectory(child, root: root, components: childComponents, expected: opened, depth: depth + 1)
                    guard try node(parent: descriptor, name: name).identity == initial.identity else {
                        throw UsageOpenError(reason: .changedDuringScan, code: nil)
                    }
                } else {
                    let final = try node(child), named = try node(parent: descriptor, name: name)
                    guard final == initial, named == initial else { throw UsageOpenError(reason: .changedDuringScan, code: nil) }
                    if let previous = seen[initial.identity] {
                        if previous != initial { issue(root, childPath, .changedDuringScan) }
                        var value = measurement(category, root: root, volume: initial.volume)
                        value.deduplicatedFileCount += 1; save(value)
                    } else {
                        seen[initial.identity] = initial
                        record(initial, root: root, path: childPath, category: category)
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch let error as UsageOpenError {
                issue(root, childPath, error.reason, code: error.code)
                if let observed { skipped(observed, root: root, category: observedCategory) }
            }
        }
        if try node(descriptor) != expected { issue(root, path, .changedDuringScan) }
    }

    func directoryNames(_ fd: Int32, root: StorageUsageRoot, path: String) throws -> [String] {
        let copied = dup(fd)
        guard copied >= 0 else { throw UsageOpenError(reason: .unreadable, code: errno) }
        guard let stream = fdopendir(copied) else { Darwin.close(copied); throw UsageOpenError(reason: .unreadable, code: errno) }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            try checkCancellation()
            if ProcessInfo.processInfo.systemUptime - startedUptime >= limits.maximumDuration {
                issue(root, path, .timeLimit); stopped = true; break
            }
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw UsageOpenError(reason: .unreadable, code: errno) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingUTF8: $0) }
            }
            guard let name else {
                issue(root, path, .unsupportedFileType)
                if try !budget(root, path) { break }
                continue
            }
            if name == "." || name == ".." { continue }
            // Limit the enumeration buffer before visiting descendants. The retained prefix is
            // sorted; a truncated walk is explicitly partial, not an exact deterministic total.
            if names.count >= max(0, limits.maximumEntries - examined) {
                issue(root, path, .entryLimit); break
            }
            names.append(name)
        }
        return names.sorted()
    }

    func classify(root: StorageUsageRoot, components: [String], kind: mode_t) -> StorageUsageCategory {
        guard root.id == "profile", root.url == scope.profileDirectory else { return root.category }
        guard let first = components.first else { return .directoryMetadata }
        if first == ".storage-reservations" { return .storageCredentials }
        if first == ".storage-reservations.lock", components.count == 1, kind == S_IFREG { return .storageCredentials }
        if first == "Backups" { return .backups }
        if first == "ShareImports" { return .shareImports }
        if [scope.databaseName, scope.databaseName + "-wal", scope.databaseName + "-shm", scope.databaseName + "-journal"].contains(first), components.count == 1 {
            return kind == S_IFREG ? .database : .unknown
        }
        let attachmentName = (scope.databaseName as NSString).deletingPathExtension + ".attachments"
        guard first == attachmentName else { return .unknown }
        if components.count == 1 { return kind == S_IFDIR ? .directoryMetadata : .unknown }
        if components[1] != "owned" {
            let name = components[1]
            let stem = String(name.dropLast(5))
            return components.count == 2 && kind == S_IFREG && name.hasSuffix(".blob")
                && stem.count == 64 && stem.allSatisfy({ "0123456789abcdef".contains($0) }) ? .representations : .unknown
        }
        if components.count == 2 { return kind == S_IFDIR ? .directoryMetadata : .unknown }
        if components[2] == ".leases" { return .ownedCredentials }
        if components[2] == ".reclamation" { return .ownedQuarantine }
        guard UUID(uuidString: components[2])?.uuidString == components[2] else { return .unknown }
        if components.count == 3 { return kind == S_IFDIR ? .directoryMetadata : .unknown }
        if components[3] == "payload", components.count == 4, kind == S_IFREG { return .ownedOriginals }
        if components[3] == "files" {
            return (components.count == 4 && kind == S_IFDIR) || (components.count == 5 && kind == S_IFREG) ? .ownedOpenCopies : .unknown
        }
        return .unknown
    }

    func measurement(_ category: StorageUsageCategory, root: StorageUsageRoot, volume: String) -> StorageUsageMeasurement {
        let key = UsageKey(category: category.rawValue, scope: root.scopeKind.rawValue, volume: volume)
        return measurements[key] ?? StorageUsageMeasurement(category: category, scopeKind: root.scopeKind, volumeID: volume,
            logicalBytes: 0, allocatedBytes: 0, fileCount: 0, directoryCount: 0, deduplicatedFileCount: 0, skippedEntryCount: 0)
    }
    func save(_ value: StorageUsageMeasurement) {
        measurements[UsageKey(category: value.category.rawValue, scope: value.scopeKind.rawValue, volume: value.volumeID)] = value
    }
    func skipped(_ node: UsageNode, root: StorageUsageRoot, category: StorageUsageCategory) {
        var value = measurement(category, root: root, volume: node.volume)
        value.skippedEntryCount += 1; save(value)
    }
    func record(_ node: UsageNode, root: StorageUsageRoot, path: String, category: StorageUsageCategory) {
        guard let bytes = totals.append(fileSize: node.size, allocatedBlocks: node.blocks, isRegularFile: node.kind == S_IFREG) else {
            issue(root, path, .invalidMetadata); skipped(node, root: root, category: category); return
        }
        var value = measurement(category, root: root, volume: node.volume)
        value.logicalBytes += bytes.logical; value.allocatedBytes += bytes.allocated
        if node.kind == S_IFREG { value.fileCount += 1 } else { value.directoryCount += 1 }
        save(value)
    }
}
