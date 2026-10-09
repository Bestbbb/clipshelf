import ClipShelfLocalization
import CryptoKit
import Darwin
import Foundation

struct OwnedFileReclamationNode: Codable, Equatable, Sendable {
    let device: Int64
    let inode: UInt64
    let mode: UInt32
    let linkCount: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let allocatedBytes: Int64

    init(_ value: stat) {
        device = Int64(value.st_dev); inode = UInt64(value.st_ino)
        mode = UInt32(value.st_mode); linkCount = UInt64(value.st_nlink); size = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        allocatedBytes = max(0, value.st_blocks) > Int64.max / 512 ? Int64.max : max(0, value.st_blocks) * 512
    }
    func sameDirectoryIdentity(_ other: Self) -> Bool {
        // Removing our own children changes directory mtime, link count and size. Recovery
        // still requires the exact directory inode/device/type/permissions from the plan.
        device == other.device && inode == other.inode && mode == other.mode
    }
}
struct OwnedFileReclamationFingerprint: Codable, Equatable, Sendable {
    let assetDirectory: OwnedFileReclamationNode
    let filesDirectory: OwnedFileReclamationNode
    let payload: OwnedFileReclamationNode
    let projection: OwnedFileReclamationNode
}
struct OwnedFileReclamationCandidate: Codable, Equatable, Sendable {
    let assetID: UUID
    let filename: String
    let byteCount: Int
    let sha256: String
    let logicalBytes: Int64
    let allocatedBytes: Int64
    let fingerprint: OwnedFileReclamationFingerprint
    var asset: OwnedFileAsset { .init(id: assetID, filename: filename, byteCount: byteCount, sha256: sha256) }
}
struct QuarantinedOwnedFile: Codable, Equatable, Sendable {
    let candidate: OwnedFileReclamationCandidate
    let operationID: UUID
}
struct OwnedFileReclamationDeletionResult: Sendable {
    let removedFileCount: Int
    let removedLogicalBytes: Int64
    let removedAllocatedBytes: Int64
    let complete: Bool
    let failure: String?
    init(removedFileCount: Int, removedLogicalBytes: Int64, removedAllocatedBytes: Int64, complete: Bool, failure: String? = nil) {
        self.removedFileCount = removedFileCount; self.removedLogicalBytes = removedLogicalBytes
        self.removedAllocatedBytes = removedAllocatedBytes; self.complete = complete; self.failure = failure
    }
}
struct OwnedFileStorageMeasurement: Sendable {
    let logicalBytes: Int64
    let allocatedBytes: Int64
    let unregisteredDirectoryIDs: Set<UUID>
    let unknownEntryCount: Int
    let skippedEntryCount: Int
    var isComplete: Bool { skippedEntryCount == 0 }
}

enum OwnedFileReclamationError: Error, LocalizedError {
    case changed, unsafeLayout, io(Int32)
    var errorDescription: String? {
        switch self {
        case .changed: return L10n.text("文件或隔离目录已改变，未继续回收。请重新检查存储状态。")
        case .unsafeLayout: return L10n.text("文件包含外部修改、异常目录或不安全引用，已保留。")
        case .io(let code): return L10n.text("文件回收未完成：") + NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription
        }
    }
}

extension OwnedFileStorage {
    /// Bounded metadata-only traversal, including changed, unregistered and quarantined
    /// content. It never follows links or grants ownership to a discovered directory.
    /// Allocated blocks are a filesystem estimate; APFS clone sharing is not measurable here.
    func ownedStorageMeasurement(registeredAssetIDs: Set<UUID>) throws -> OwnedFileStorageMeasurement {
        let root = try Self.openDirectory(directory, create: false)
        defer { Darwin.close(root) }
        var logical: Int64 = 0, allocated: Int64 = 0, visited = 0, unknown = 0, skipped = 0
        var unregistered = Set<UUID>(), filesSeen = Set<String>()
        enum Role { case root, asset, files, quarantine, operation, unknown }
        func visit(_ fd: Int32, role: Role, depth: Int) throws {
            guard depth <= 16 else { throw HistoryStoreError.valueTooLarge }
            let before = try reclamationNode(fd: fd)
            let names = try reclamationNames(fd: fd, maximumEntries: 100_000 - visited)
            for name in names.sorted() {
                try Task.checkCancellation()
                visited += 1
                guard visited <= 100_000 else { throw HistoryStoreError.valueTooLarge }
                let info: stat
                do {
                    guard let found = try reclamationStat(parent: fd, name: name) else { skipped += 1; continue }
                    info = found
                } catch { skipped += 1; continue }
                let node = OwnedFileReclamationNode(info), kind = node.mode & UInt32(S_IFMT)
                if role == .root, name == ".leases", kind == UInt32(S_IFDIR) { continue }
                if kind == UInt32(S_IFLNK) { unknown += 1; skipped += 1; continue }
                var childRole = Role.unknown
                switch role {
                case .root:
                    if name == ".reclamation", kind == UInt32(S_IFDIR) { childRole = .quarantine }
                    else if let id = UUID(uuidString: name), id.uuidString == name, kind == UInt32(S_IFDIR) {
                        childRole = .asset
                        if !registeredAssetIDs.contains(id) { unregistered.insert(id); unknown += 1 }
                    } else { unknown += 1 }
                case .quarantine:
                    if UUID(uuidString: name)?.uuidString == name, kind == UInt32(S_IFDIR) { childRole = .operation }
                    else { unknown += 1 }
                case .operation:
                    if UUID(uuidString: name)?.uuidString == name, kind == UInt32(S_IFDIR) { childRole = .asset }
                    else { unknown += 1 }
                case .asset:
                    if name == "files", kind == UInt32(S_IFDIR) { childRole = .files }
                    else if name != "payload" || kind != UInt32(S_IFREG) { unknown += 1 }
                case .files:
                    if kind != UInt32(S_IFREG) || names.count != 1 { unknown += 1 }
                case .unknown: break
                }
                if kind == UInt32(S_IFREG) {
                    if node.linkCount != 1 { unknown += 1 }
                    guard filesSeen.insert("\(node.device):\(node.inode)").inserted else { continue }
                    guard node.size >= 0 else { skipped += 1; continue }
                    let (newLogical, logicalOverflow) = logical.addingReportingOverflow(node.size)
                    let (newAllocated, allocatedOverflow) = allocated.addingReportingOverflow(node.allocatedBytes)
                    guard !logicalOverflow, !allocatedOverflow else { throw HistoryStoreError.valueTooLarge }
                    logical = newLogical; allocated = newAllocated
                } else if kind == UInt32(S_IFDIR) {
                    let child: Int32
                    do { child = try reclamationOpenDirectory(parent: fd, name: name) }
                    catch { skipped += 1; continue }
                    defer { Darwin.close(child) }
                    guard node.sameDirectoryIdentity(try reclamationNode(fd: child)) else { skipped += 1; continue }
                    do { try visit(child, role: childRole, depth: depth + 1) }
                    catch is CancellationError { throw CancellationError() }
                    catch HistoryStoreError.valueTooLarge { throw HistoryStoreError.valueTooLarge }
                    catch { skipped += 1 }
                } else { unknown += 1; skipped += 1 }
            }
            if try reclamationNode(fd: fd) != before { skipped += 1 }
        }
        try visit(root, role: .root, depth: 0)
        return .init(logicalBytes: logical, allocatedBytes: allocated, unregisteredDirectoryIDs: unregistered,
                     unknownEntryCount: unknown, skippedEntryCount: skipped)
    }

    /// This only inspects the explicitly registered asset. Unknown UUID directories are
    /// not candidates. Both copies must still match the immutable registry digest.
    func prepareReclamation(_ asset: OwnedFileAsset) throws -> OwnedFileReclamationCandidate? {
        try Self.validateFilename(asset.filename)
        let root = try Self.openDirectory(directory, create: false)
        defer { Darwin.close(root) }
        do {
            return try reclamationSnapshot(asset, parent: root, name: asset.id.uuidString)
        } catch OwnedFileReclamationError.changed { return nil }
        catch OwnedFileReclamationError.unsafeLayout { return nil }
        catch HistoryStoreError.valueTooLarge { return nil }
    }

    func preparedQuarantine(candidate: OwnedFileReclamationCandidate, operationID: UUID) -> QuarantinedOwnedFile {
        QuarantinedOwnedFile(candidate: candidate, operationID: operationID)
    }

    /// Core must durably journal this deterministic token before calling rename. It must
    /// revalidate DB reachability/leases while holding its writer lock around this call.
    func quarantine(_ candidate: OwnedFileReclamationCandidate, operationID: UUID) throws -> QuarantinedOwnedFile {
        try validateReclamationCandidate(candidate)
        let token = preparedQuarantine(candidate: candidate, operationID: operationID)
        let root = try Self.openDirectory(directory, create: false)
        defer { Darwin.close(root) }
        let operation = try reclamationOperationDirectory(root: root, operationID: operationID, create: true)
        defer { Darwin.close(operation) }
        let name = candidate.assetID.uuidString
        if try reclamationStat(parent: operation, name: name) != nil {
            guard try reclamationStat(parent: root, name: name) == nil,
                  try reclamationSnapshot(candidate.asset, parent: operation, name: name) == candidate else { throw OwnedFileReclamationError.changed }
            return token
        }
        guard try reclamationSnapshot(candidate.asset, parent: root, name: name) == candidate else { throw OwnedFileReclamationError.changed }
        guard renameatx_np(root, name, operation, name, UInt32(RENAME_EXCL)) == 0 else { throw OwnedFileReclamationError.io(errno) }
        // A path replaced between validation and rename is never accepted for deletion.
        // Its unexpected contents remain isolated for recovery, never recursively removed.
        guard try reclamationSnapshot(candidate.asset, parent: operation, name: name) == candidate else { throw OwnedFileReclamationError.changed }
        guard fsync(root) == 0, fsync(operation) == 0 else { throw OwnedFileReclamationError.io(errno) }
        return token
    }

    /// Only Core may choose restoration for a journal not committed for deletion. Restore
    /// preserves external modifications inside the original directory inode. After a journal
    /// commits, recovery must continue deletion, never call this method on a partial tree.
    func restore(_ token: QuarantinedOwnedFile) throws {
        let candidate = token.candidate, name = candidate.assetID.uuidString
        try validateReclamationCandidate(candidate)
        let root = try Self.openDirectory(directory, create: false)
        defer { Darwin.close(root) }
        let operation = try reclamationOperationDirectoryIfPresent(root: root, operationID: token.operationID)
        defer { if let operation { Darwin.close(operation) } }
        guard let operation, try reclamationStat(parent: operation, name: name) != nil else {
            guard let info = try reclamationStat(parent: root, name: name),
                  candidate.fingerprint.assetDirectory.sameDirectoryIdentity(OwnedFileReclamationNode(info)) else { throw OwnedFileReclamationError.changed }
            return
        }
        guard try reclamationStat(parent: root, name: name) == nil,
              let info = try reclamationStat(parent: operation, name: name),
              candidate.fingerprint.assetDirectory.sameDirectoryIdentity(OwnedFileReclamationNode(info)) else { throw OwnedFileReclamationError.changed }
        guard renameatx_np(operation, name, root, name, UInt32(RENAME_EXCL)) == 0 else { throw OwnedFileReclamationError.io(errno) }
        guard let restored = try reclamationStat(parent: root, name: name),
              candidate.fingerprint.assetDirectory.sameDirectoryIdentity(OwnedFileReclamationNode(restored)) else { throw OwnedFileReclamationError.changed }
        guard fsync(root) == 0, fsync(operation) == 0 else { throw OwnedFileReclamationError.io(errno) }
        removeEmptyReclamationOperation(root: root, operationID: token.operationID, expectedFD: operation)
    }

    /// No recursive deletion. Recovery accepts missing expected children from an earlier
    /// partial unlink, but rejects extra files, replacement inodes, links and changed bytes.
    /// The injected hook is internal and used only by synthetic interruption tests.
    func removeQuarantined(_ token: QuarantinedOwnedFile,
                           beforeUnlink: ((String) throws -> Void)? = nil) throws -> OwnedFileReclamationDeletionResult {
        let candidate = token.candidate, name = candidate.assetID.uuidString
        try validateReclamationCandidate(candidate)
        let root = try Self.openDirectory(directory, create: false)
        defer { Darwin.close(root) }
        guard let operation = try reclamationOperationDirectoryIfPresent(root: root, operationID: token.operationID) else {
            guard try reclamationStat(parent: root, name: name) == nil else { throw OwnedFileReclamationError.changed }
            return .init(removedFileCount: 0, removedLogicalBytes: 0, removedAllocatedBytes: 0, complete: true)
        }
        defer { Darwin.close(operation) }
        guard try reclamationStat(parent: root, name: name) == nil else { throw OwnedFileReclamationError.changed }
        guard let folderInfo = try reclamationStat(parent: operation, name: name) else {
            removeEmptyReclamationOperation(root: root, operationID: token.operationID, expectedFD: operation)
            return .init(removedFileCount: 0, removedLogicalBytes: 0, removedAllocatedBytes: 0, complete: true)
        }
        guard candidate.fingerprint.assetDirectory.sameDirectoryIdentity(OwnedFileReclamationNode(folderInfo)) else { throw OwnedFileReclamationError.changed }
        let folder = try reclamationOpenDirectory(parent: operation, name: name)
        defer { Darwin.close(folder) }
        guard candidate.fingerprint.assetDirectory.sameDirectoryIdentity(try reclamationNode(fd: folder)),
              try reclamationNames(fd: folder, maximumEntries: 2).isSubset(of: ["payload", "files"]) else { throw OwnedFileReclamationError.unsafeLayout }
        var files: Int32?
        if let info = try reclamationStat(parent: folder, name: "files") {
            guard candidate.fingerprint.filesDirectory.sameDirectoryIdentity(OwnedFileReclamationNode(info)) else { throw OwnedFileReclamationError.changed }
            files = try reclamationOpenDirectory(parent: folder, name: "files")
            guard candidate.fingerprint.filesDirectory.sameDirectoryIdentity(try reclamationNode(fd: files!)),
                  try reclamationNames(fd: files!, maximumEntries: 1).isSubset(of: [candidate.filename]) else { if let files { Darwin.close(files) }; throw OwnedFileReclamationError.unsafeLayout }
        }
        defer { if let files { Darwin.close(files) } }
        // Preflight every remaining file before deleting any of them.
        if try reclamationStat(parent: folder, name: "payload") != nil {
            guard try reclamationFile(parent: folder, name: "payload", asset: candidate.asset) == candidate.fingerprint.payload else { throw OwnedFileReclamationError.changed }
        }
        if let files, try reclamationStat(parent: files, name: candidate.filename) != nil {
            guard try reclamationFile(parent: files, name: candidate.filename, asset: candidate.asset) == candidate.fingerprint.projection else { throw OwnedFileReclamationError.changed }
        }
        var removed = 0, logical: Int64 = 0, allocated: Int64 = 0
        func result(_ complete: Bool, failure: String? = nil) -> OwnedFileReclamationDeletionResult {
            .init(removedFileCount: removed, removedLogicalBytes: logical, removedAllocatedBytes: allocated, complete: complete, failure: failure)
        }
        func requireAnchor(includeFiles: Bool = true) throws {
            let currentRoot = try Self.openDirectory(directory, create: false)
            defer { Darwin.close(currentRoot) }
            guard try reclamationNode(fd: root).sameDirectoryIdentity(reclamationNode(fd: currentRoot)),
                  let currentOperation = try reclamationOperationDirectoryIfPresent(root: currentRoot, operationID: token.operationID) else { throw OwnedFileReclamationError.changed }
            defer { Darwin.close(currentOperation) }
            guard try reclamationNode(fd: operation).sameDirectoryIdentity(reclamationNode(fd: currentOperation)),
                  let currentFolder = try reclamationStat(parent: currentOperation, name: candidate.assetID.uuidString),
                  candidate.fingerprint.assetDirectory.sameDirectoryIdentity(OwnedFileReclamationNode(currentFolder)) else { throw OwnedFileReclamationError.changed }
            if includeFiles, let files {
                guard let currentFiles = try reclamationStat(parent: folder, name: "files"),
                      try reclamationNode(fd: files).sameDirectoryIdentity(OwnedFileReclamationNode(currentFiles)) else { throw OwnedFileReclamationError.changed }
            }
        }
        func unlinkFile(parent: Int32, name: String, expected: OwnedFileReclamationNode) throws {
            guard try reclamationStat(parent: parent, name: name) != nil else { return }
            try beforeUnlink?(name)
            try requireAnchor()
            // Re-read and hash immediately before unlinking the expected entry.
            guard try reclamationFile(parent: parent, name: name, asset: candidate.asset) == expected,
                  try reclamationStat(parent: parent, name: name).map(OwnedFileReclamationNode.init) == expected else { throw OwnedFileReclamationError.changed }
            guard unlinkat(parent, name, 0) == 0 else { throw OwnedFileReclamationError.io(errno) }
            removed += 1; logical += expected.size; allocated += expected.allocatedBytes
            guard fsync(parent) == 0 else { throw OwnedFileReclamationError.io(errno) }
        }
        do {
            if let files { try unlinkFile(parent: files, name: candidate.filename, expected: candidate.fingerprint.projection) }
            try unlinkFile(parent: folder, name: "payload", expected: candidate.fingerprint.payload)
            if files != nil {
                try beforeUnlink?("files")
                try requireAnchor()
                guard let info = try reclamationStat(parent: folder, name: "files"),
                      candidate.fingerprint.filesDirectory.sameDirectoryIdentity(OwnedFileReclamationNode(info)) else { throw OwnedFileReclamationError.changed }
                guard unlinkat(folder, "files", AT_REMOVEDIR) == 0 else { throw OwnedFileReclamationError.io(errno) }
            }
            try beforeUnlink?(name)
            try requireAnchor(includeFiles: false)
            guard let info = try reclamationStat(parent: operation, name: name),
                  candidate.fingerprint.assetDirectory.sameDirectoryIdentity(OwnedFileReclamationNode(info)) else { throw OwnedFileReclamationError.changed }
            guard unlinkat(operation, name, AT_REMOVEDIR) == 0 else { throw OwnedFileReclamationError.io(errno) }
            guard fsync(operation) == 0 else { throw OwnedFileReclamationError.io(errno) }
            removeEmptyReclamationOperation(root: root, operationID: token.operationID, expectedFD: operation)
            return result(true)
        } catch { return result(false, failure: error.localizedDescription) }
    }

    private func validateReclamationCandidate(_ candidate: OwnedFileReclamationCandidate) throws {
        try Self.validateFilename(candidate.filename)
        let fingerprint = candidate.fingerprint
        let (allocated, overflow) = fingerprint.payload.allocatedBytes.addingReportingOverflow(fingerprint.projection.allocatedBytes)
        guard (0...Self.maximumBytes).contains(candidate.byteCount), candidate.sha256.utf8.count == 64,
              candidate.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              candidate.logicalBytes == Int64(candidate.byteCount) * 2, !overflow, allocated == candidate.allocatedBytes,
              fingerprint.payload.allocatedBytes >= 0, fingerprint.projection.allocatedBytes >= 0,
              fingerprint.payload.size == candidate.byteCount, fingerprint.projection.size == candidate.byteCount,
              fingerprint.payload.mode & UInt32(S_IFMT) == UInt32(S_IFREG), fingerprint.projection.mode & UInt32(S_IFMT) == UInt32(S_IFREG),
              fingerprint.payload.linkCount == 1, fingerprint.projection.linkCount == 1,
              fingerprint.assetDirectory.mode & UInt32(S_IFMT) == UInt32(S_IFDIR),
              fingerprint.filesDirectory.mode & UInt32(S_IFMT) == UInt32(S_IFDIR) else { throw OwnedFileReclamationError.unsafeLayout }
    }
    private func reclamationSnapshot(_ asset: OwnedFileAsset, parent: Int32, name: String) throws -> OwnedFileReclamationCandidate {
        try Self.validateFilename(asset.filename)
        guard (0...Self.maximumBytes).contains(asset.byteCount), asset.sha256.utf8.count == 64,
              asset.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw OwnedFileReclamationError.unsafeLayout }
        let folder = try reclamationOpenDirectory(parent: parent, name: name)
        defer { Darwin.close(folder) }
        let folderBefore = try reclamationNode(fd: folder)
        guard try reclamationNames(fd: folder, maximumEntries: 2) == ["payload", "files"] else { throw OwnedFileReclamationError.unsafeLayout }
        let files = try reclamationOpenDirectory(parent: folder, name: "files")
        defer { Darwin.close(files) }
        let filesBefore = try reclamationNode(fd: files)
        guard try reclamationNames(fd: files, maximumEntries: 1) == [asset.filename] else { throw OwnedFileReclamationError.unsafeLayout }
        let payload = try reclamationFile(parent: folder, name: "payload", asset: asset)
        let projection = try reclamationFile(parent: files, name: asset.filename, asset: asset)
        guard folderBefore == (try reclamationNode(fd: folder)), filesBefore == (try reclamationNode(fd: files)),
              try reclamationStat(parent: parent, name: name).map(OwnedFileReclamationNode.init) == folderBefore,
              try reclamationStat(parent: folder, name: "files").map(OwnedFileReclamationNode.init) == filesBefore else { throw OwnedFileReclamationError.changed }
        let (allocated, overflow) = payload.allocatedBytes.addingReportingOverflow(projection.allocatedBytes)
        guard !overflow else { throw OwnedFileReclamationError.unsafeLayout }
        return .init(assetID: asset.id, filename: asset.filename, byteCount: asset.byteCount, sha256: asset.sha256,
                     logicalBytes: payload.size + projection.size, allocatedBytes: allocated,
                     fingerprint: .init(assetDirectory: folderBefore, filesDirectory: filesBefore, payload: payload, projection: projection))
    }
    private func reclamationFile(parent: Int32, name: String, asset: OwnedFileAsset) throws -> OwnedFileReclamationNode {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw OwnedFileReclamationError.unsafeLayout }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let before = try reclamationNode(fd: fd)
        guard before.mode & UInt32(S_IFMT) == UInt32(S_IFREG), before.linkCount == 1, before.size == asset.byteCount else { throw OwnedFileReclamationError.unsafeLayout }
        var count = 0, digest = SHA256()
        while let data = try handle.read(upToCount: min(1_024 * 1_024, asset.byteCount - count + 1)), !data.isEmpty {
            try Task.checkCancellation()
            guard data.count <= asset.byteCount - count else { throw OwnedFileReclamationError.changed }
            count += data.count; digest.update(data: data)
        }
        guard count == asset.byteCount, digest.finalize().map({ String(format: "%02x", $0) }).joined() == asset.sha256,
              try reclamationNode(fd: fd) == before,
              try reclamationStat(parent: parent, name: name).map(OwnedFileReclamationNode.init) == before else { throw OwnedFileReclamationError.changed }
        return before
    }
    private func reclamationNode(fd: Int32) throws -> OwnedFileReclamationNode {
        var info = stat(); guard fstat(fd, &info) == 0 else { throw OwnedFileReclamationError.io(errno) }
        return OwnedFileReclamationNode(info)
    }
    private func reclamationStat(parent: Int32, name: String) throws -> stat? {
        var info = stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return info }
        if errno == ENOENT { return nil }
        throw OwnedFileReclamationError.io(errno)
    }
    private func reclamationOpenDirectory(parent: Int32, name: String) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw OwnedFileReclamationError.unsafeLayout }
        return fd
    }
    private func reclamationNames(fd: Int32, maximumEntries: Int = 100_000) throws -> Set<String> {
        // A fresh open file description avoids sharing/reusing a previous readdir offset.
        let iterator = try reclamationOpenDirectory(parent: fd, name: ".")
        guard let stream = fdopendir(iterator) else { Darwin.close(iterator); throw OwnedFileReclamationError.io(errno) }
        defer { closedir(stream) }
        var names = Set<String>()
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingUTF8: $0) }
            }
            guard let name else { throw OwnedFileReclamationError.unsafeLayout }
            if name != ".", name != ".." {
                names.insert(name)
                guard names.count <= maximumEntries else { throw HistoryStoreError.valueTooLarge }
            }
            errno = 0
        }
        guard errno == 0 else { throw OwnedFileReclamationError.io(errno) }
        return names
    }
    private func reclamationOperationDirectory(root: Int32, operationID: UUID, create: Bool) throws -> Int32 {
        if create, mkdirat(root, ".reclamation", 0o700) != 0, errno != EEXIST { throw OwnedFileReclamationError.io(errno) }
        let quarantine = try reclamationOpenDirectory(parent: root, name: ".reclamation")
        defer { Darwin.close(quarantine) }
        if create, mkdirat(quarantine, operationID.uuidString, 0o700) != 0, errno != EEXIST { throw OwnedFileReclamationError.io(errno) }
        let result = try reclamationOpenDirectory(parent: quarantine, name: operationID.uuidString)
        guard fsync(quarantine) == 0, fsync(root) == 0 else { Darwin.close(result); throw OwnedFileReclamationError.io(errno) }
        return result
    }
    private func reclamationOperationDirectoryIfPresent(root: Int32, operationID: UUID) throws -> Int32? {
        guard try reclamationStat(parent: root, name: ".reclamation") != nil else { return nil }
        let quarantine = try reclamationOpenDirectory(parent: root, name: ".reclamation")
        defer { Darwin.close(quarantine) }
        guard try reclamationStat(parent: quarantine, name: operationID.uuidString) != nil else { return nil }
        return try reclamationOpenDirectory(parent: quarantine, name: operationID.uuidString)
    }
    private func removeEmptyReclamationOperation(root: Int32, operationID: UUID, expectedFD: Int32) {
        guard let currentRoot = try? Self.openDirectory(directory, create: false) else { return }
        defer { Darwin.close(currentRoot) }
        guard let expectedRoot = try? reclamationNode(fd: root), let actualRoot = try? reclamationNode(fd: currentRoot),
              expectedRoot.sameDirectoryIdentity(actualRoot) else { return }
        guard let quarantine = try? reclamationOpenDirectory(parent: root, name: ".reclamation") else { return }
        defer { Darwin.close(quarantine) }
        guard let expected = try? reclamationNode(fd: expectedFD),
              let current = try? reclamationStat(parent: quarantine, name: operationID.uuidString),
              expected.sameDirectoryIdentity(OwnedFileReclamationNode(current)) else { return }
        _ = unlinkat(quarantine, operationID.uuidString, AT_REMOVEDIR)
        _ = fsync(quarantine)
    }
}
