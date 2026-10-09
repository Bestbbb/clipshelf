import ClipShelfCore
import CryptoKit
import Darwin
import Foundation
import ShareInboxShared
import UniformTypeIdentifiers

/// Only the containing app imports into HistoryStore. The sandboxed extension
/// knows destination metadata, not the database location or credentials.
actor ShareInboxService {
    struct Failure: Sendable { let operationID: UUID; let message: String }
    struct ImportReport: Sendable { let imported: Int; let alreadyImported: Int; let failures: [Failure] }
    struct LegacyMigrationFailure: Sendable {
        let operationID: UUID?
        let recordID: UUID?
        let message: String
    }
    struct LegacyMigrationReport: Sendable {
        var migratedRecords = 0
        var alreadyManagedRecords = 0
        var deletedRecords = 0
        var skippedNonFileRecords = 0
        var failures: [LegacyMigrationFailure] = []

        func requireComplete() throws {
            if !failures.isEmpty { throw LegacyMigrationIncomplete(failures: failures, migratedRecords: migratedRecords) }
        }
        var snapshotNotice: String {
            migratedRecords == 0 ? "" : "已将 \(migratedRecords) 条旧分享文件保存为迁移时快照，未核对最初分享摘要。"
        }
    }
    struct LegacyMigrationIncomplete: LocalizedError, Sendable {
        let failures: [LegacyMigrationFailure]
        let migratedRecords: Int
        var errorDescription: String? {
            let progress = migratedRecords == 0 ? "" : "其中 \(migratedRecords) 条已保存为迁移时快照，未核对最初分享摘要。\n"
            return "有 \(failures.count) 项旧分享文件无法迁移，本次备份或恢复已停止。\n" + progress + failures.prefix(5).map { failure in
                let prefix = failure.recordID.map { "条目 \($0.uuidString.prefix(8))：" } ?? "导入收据："
                return prefix + failure.message
            }.joined(separator: "\n")
        }
    }
    private enum LegacyMigrationError: LocalizedError {
        case invalidReceipt, incompleteReceipt, unprovenFile, unreadableFile, changedFile
        var errorDescription: String? {
            switch self {
            case .invalidReceipt: return "旧导入收据无效，无法证明文件归属。"
            case .incompleteReceipt: return "该项导入曾中断且尚未确认；请先检查系统分享收件箱。"
            case .unprovenFile: return "当前文件引用不再匹配原导入记录的受控目录，未接管外部文件。"
            case .unreadableFile: return "旧文件缺失、不可读，或路径包含链接；原记录保留。"
            case .changedFile: return "旧文件在读取期间改变，未保存不一致快照；请重试。"
            }
        }
    }
    private struct Receipt: Codable {
        let digest: String
        let recordIDs: [UUID]
        var attempted: Set<Int>
        var completed: Set<Int>
    }
    private enum ImportError: Error, LocalizedError {
        case receiptMismatch, uncertainCommit, unsupportedType
        var errorDescription: String? {
            switch self {
            case .receiptMismatch: return "分享请求与已有导入凭据不一致，未再次导入。"
            case .uncertainCommit: return "上次导入被中断且无法确认结果，已保留内容；请明确重试后恢复。"
            case .unsupportedType: return "分享包含暂不支持的数据类型，原内容保留在收件箱。"
            }
        }
    }
    private let store: HistoryStore
    private let directory: ShareInboxDirectory
    private let privateDirectory: URL
    private var importsAllowed = true
    private var lastPublishedCatalog: ShareInboxCatalog?

    static func configured(store: HistoryStore, privateDirectory: URL, bundle: Bundle = .main) throws -> ShareInboxService {
        try ShareInboxService(store: store, privateDirectory: privateDirectory, inbox: ShareInboxDirectory.configured(bundle: bundle))
    }
    /// Explicit synthetic inbox injection for tests. Production uses configured().
    init(store: HistoryStore, privateDirectory: URL, inbox: ShareInboxDirectory) throws {
        self.store = store
        directory = inbox
        self.privateDirectory = privateDirectory.appendingPathComponent("ShareImports", isDirectory: true)
        try FileManager.default.createDirectory(at: self.privateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try ShareInboxDirectory.requireRegular(self.privateDirectory, directory: true)
    }

    func publishDestinations(allowImports: Bool = true) throws {
        let catalog = try currentCatalog(allowImports: allowImports)
        if lastPublishedCatalog?.contextBinding != catalog.contextBinding || lastPublishedCatalog?.destinations != catalog.destinations {
            try directory.writeCatalog(catalog)
            lastPublishedCatalog = catalog
        }
        importsAllowed = allowImports
    }

    func importPending(retryUncertain: Bool = false) throws -> ImportReport {
        guard importsAllowed else { return ImportReport(imported: 0, alreadyImported: 0, failures: []) }
        // Cross-process serialization also protects crash-recovery receipts if a
        // developer deliberately starts two copies of the containing app.
        let lockURL = privateDirectory.appendingPathComponent("import.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ShareInboxError.invalidData }
        defer { _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw ShareInboxError.invalidData }
        var imported = 0, existing = 0, failures: [Failure] = []
        for id in try directory.pendingIDs().prefix(100) {
            do {
                let (envelope, digest) = try directory.read(id)
                let receiptURL = privateDirectory.appendingPathComponent(id.uuidString + ".json")
                var receipt: Receipt
                if FileManager.default.fileExists(atPath: receiptURL.path) {
                    receipt = try JSONDecoder().decode(Receipt.self, from: ShareInboxDirectory.boundedData(receiptURL, limit: 65_536))
                    guard receipt.digest == digest, receipt.recordIDs.count == envelope.items.count,
                          Set(receipt.recordIDs).count == receipt.recordIDs.count,
                          receipt.attempted.allSatisfy({ envelope.items.indices.contains($0) }),
                          receipt.completed.allSatisfy({ envelope.items.indices.contains($0) }) else { throw ImportError.receiptMismatch }
                } else {
                    // Never trust operation or record IDs supplied by another process.
                    receipt = Receipt(digest: digest, recordIDs: envelope.items.map { _ in UUID() }, attempted: [], completed: [])
                    try save(receipt, to: receiptURL)
                }
                // A completed receipt prevents resurrection even after a user deletes the imported record.
                if receipt.completed.count == envelope.items.count {
                    existing += envelope.items.count
                    try directory.remove(id)
                    continue
                }
                let expectedSync = try store.syncConfiguration()
                let expectedSharing = try store.sharingConfiguration()
                let catalog = try currentCatalog()
                guard envelope.contextBinding == catalog.contextBinding,
                      catalog.destinations.contains(where: { $0.boardID == envelope.destination.boardID && $0.isShared == envelope.destination.isShared }) else {
                    throw ShareInboxError.unavailableDestination
                }
                for (index, item) in envelope.items.enumerated() {
                    if receipt.completed.contains(index) { existing += 1; continue }
                    let recordID = receipt.recordIDs[index]
                    if receipt.attempted.contains(index) {
                        if try store.itemMetadata(id: recordID) != nil {
                            receipt.completed.insert(index)
                            try save(receipt, to: receiptURL)
                            existing += 1
                            continue
                        }
                        guard retryUncertain else { throw ImportError.uncertainCommit }
                    }
                    let prepared = try makeRecord(item, envelope: envelope, recordID: recordID)
                    receipt.attempted.insert(index)
                    try save(receipt, to: receiptURL)
                    do {
                        // Core transaction resolves namespace and rechecks shared access.
                        _ = try store.create(prepared.record, ownedFiles: prepared.ownedFiles, expectedSyncConfiguration: expectedSync, expectedSharingConfiguration: expectedSharing)
                    } catch {
                        receipt.attempted.remove(index) // This synchronous transaction is known to have failed.
                        try save(receipt, to: receiptURL)
                        throw error
                    }
                    receipt.completed.insert(index)
                    try save(receipt, to: receiptURL)
                    imported += 1
                }
                try directory.remove(id)
            } catch {
                failures.append(Failure(operationID: id, message: (error as? LocalizedError)?.errorDescription ?? "导入未完成，内容仍保留在收件箱。"))
            }
        }
        return ImportReport(imported: imported, alreadyImported: existing, failures: failures)
    }

    /// Explicit backup/restore preparation. No App Group is needed, and only the private
    /// receipt ledger is enumerated; neither the file tree nor clipboard history is scanned.
    nonisolated static func migrateLegacyFiles(store: HistoryStore, privateDirectory: URL) throws -> LegacyMigrationReport {
        let root = privateDirectory.appendingPathComponent("ShareImports", isDirectory: true)
        let parentFD = Darwin.open(privateDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else {
            if errno == ENOENT { return LegacyMigrationReport() }
            throw LegacyMigrationError.unreadableFile
        }
        defer { Darwin.close(parentFD) }
        let rootFD = openat(parentFD, "ShareImports", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else {
            if errno == ENOENT { return LegacyMigrationReport() }
            throw LegacyMigrationError.unreadableFile
        }
        defer { Darwin.close(rootFD) }
        let lockFD = openat(rootFD, "import.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw LegacyMigrationError.unreadableFile }
        defer { _ = flock(lockFD, LOCK_UN); Darwin.close(lockFD) }
        var lockInfo = stat()
        guard fstat(lockFD, &lockInfo) == 0, (lockInfo.st_mode & S_IFMT) == S_IFREG,
              lockInfo.st_nlink == 1, flock(lockFD, LOCK_EX) == 0 else { throw LegacyMigrationError.unreadableFile }
        let expectedSync = try store.syncConfiguration()
        let expectedSharing = try store.sharingConfiguration()
        var report = LegacyMigrationReport()
        var seen = Set<UUID>()
        for name in try receiptNames(rootFD: rootFD) {
            let operationID = UUID(uuidString: String(name.dropLast(5)))
            do {
                guard operationID != nil else { throw LegacyMigrationError.invalidReceipt }
                let receipt = try JSONDecoder().decode(Receipt.self, from: readRegularFile(parentFD: rootFD, name: name, limit: 65_536))
                let indices = Set(receipt.recordIDs.indices)
                guard (1...ShareInboxDirectory.maximumItems).contains(receipt.recordIDs.count),
                      Set(receipt.recordIDs).count == receipt.recordIDs.count,
                      receipt.digest.count == 64, receipt.digest.allSatisfy({ $0.isHexDigit }),
                      receipt.attempted.isSubset(of: indices), receipt.completed.isSubset(of: receipt.attempted) else {
                    throw LegacyMigrationError.invalidReceipt
                }
                for index in receipt.attempted.subtracting(receipt.completed).sorted() {
                    report.failures.append(LegacyMigrationFailure(operationID: operationID, recordID: receipt.recordIDs[index], message: LegacyMigrationError.incompleteReceipt.localizedDescription))
                }
                for index in receipt.completed.sorted() {
                    let recordID = receipt.recordIDs[index]
                    do {
                        guard seen.insert(recordID).inserted else { throw LegacyMigrationError.invalidReceipt }
                        guard let record = try store.item(id: recordID) else { report.deletedRecords += 1; continue }
                        let bindings = try store.ownedFileBindings(recordID: recordID)
                        let slots = Set(bindings.map { "\($0.partIndex):\($0.representationIndex)" })
                        var imports: [OwnedFileImport] = []
                        var fileCount = 0, totalBytes = 0
                        for (partIndex, part) in record.parts.enumerated() {
                            for (representationIndex, representation) in part.representations.enumerated() {
                                guard representation.typeIdentifier == "public.file-url" || UTType(representation.typeIdentifier)?.conforms(to: .fileURL) == true else { continue }
                                fileCount += 1
                                if slots.contains("\(partIndex):\(representationIndex)") { continue }
                                guard representation.typeIdentifier == "public.file-url" else { throw LegacyMigrationError.unprovenFile }
                                let name = try legacyFilename(representation.data, recordID: recordID, root: root)
                                let data = try readLegacyFile(rootFD: rootFD, recordID: recordID, filename: name,
                                                              limit: ShareInboxDirectory.maximumBytes - totalBytes)
                                totalBytes += data.count
                                imports.append(OwnedFileImport(partIndex: partIndex, representationIndex: representationIndex, filename: name, data: data))
                            }
                        }
                        if fileCount == 0 { report.skippedNonFileRecords += 1; continue }
                        if imports.isEmpty { report.alreadyManagedRecords += 1; continue }
                        // The current bytes are a migration-time snapshot, not a claim that
                        // the original share payload's digest can still be verified.
                        _ = try store.registerOwnedFiles(recordID: recordID, expectedRevision: record.revision,
                            ownedFiles: imports, expectedSyncConfiguration: expectedSync, expectedSharingConfiguration: expectedSharing)
                        report.migratedRecords += 1
                    } catch {
                        report.failures.append(LegacyMigrationFailure(operationID: operationID, recordID: recordID,
                            message: (error as? LocalizedError)?.errorDescription ?? "旧文件迁移失败，原记录和文件保留。"))
                    }
                }
            } catch {
                report.failures.append(LegacyMigrationFailure(operationID: operationID, recordID: nil,
                    message: (error as? LocalizedError)?.errorDescription ?? "旧导入收据不可读取或无效。"))
            }
        }
        return report
    }

    nonisolated private static func receiptNames(rootFD: Int32) throws -> [String] {
        let duplicate = dup(rootFD)
        guard duplicate >= 0 else { throw LegacyMigrationError.unreadableFile }
        guard let stream = fdopendir(duplicate) else { Darwin.close(duplicate); throw LegacyMigrationError.unreadableFile }
        defer { closedir(stream) }
        var result: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name.hasSuffix(".json") { result.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw LegacyMigrationError.unreadableFile }
        return result.sorted()
    }

    nonisolated private static func legacyFilename(_ data: Data, recordID: UUID, root: URL) throws -> String {
        guard let string = String(data: data, encoding: .utf8),
              let url = URL(string: string), url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil else { throw LegacyMigrationError.unprovenFile }
        let expected = root.appendingPathComponent("Files", isDirectory: true).appendingPathComponent(recordID.uuidString, isDirectory: true)
        let components = url.pathComponents
        guard components.count == expected.pathComponents.count + 1,
              Array(components.dropLast()) == expected.pathComponents,
              let name = components.last, !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw LegacyMigrationError.unprovenFile
        }
        return name
    }

    nonisolated private static func readLegacyFile(rootFD: Int32, recordID: UUID, filename: String, limit: Int) throws -> Data {
        let files = openat(rootFD, "Files", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard files >= 0 else { throw LegacyMigrationError.unreadableFile }
        defer { Darwin.close(files) }
        let record = openat(files, recordID.uuidString, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard record >= 0 else { throw LegacyMigrationError.unreadableFile }
        defer { Darwin.close(record) }
        return try readRegularFile(parentFD: record, name: filename, limit: limit)
    }

    nonisolated private static func readRegularFile(parentFD: Int32, name: String, limit: Int) throws -> Data {
        guard limit >= 0 else { throw ShareInboxError.tooLarge }
        let descriptor = openat(parentFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw LegacyMigrationError.unreadableFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG, before.st_nlink == 1,
              before.st_size >= 0, before.st_size <= limit else { throw LegacyMigrationError.unreadableFile }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        var after = stat()
        guard fstat(descriptor, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, after.st_nlink == 1, data.count == Int(before.st_size),
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw LegacyMigrationError.changedFile
        }
        return data
    }

    private func currentCatalog(allowImports: Bool = true) throws -> ShareInboxCatalog {
        let sync = try store.syncConfiguration()
        let sharing = try store.sharingConfiguration()
        // A changed account cannot silently redirect a queued private or shared save.
        let binding = ShareInboxDirectory.digest(try JSONEncoder().encode([sync.accountID, sharing.accountID]))
        guard allowImports else { return ShareInboxCatalog(contextBinding: binding, destinations: []) }
        let shared = try sharing.accountID.map { try store.sharedBoards(accountID: $0) } ?? []
        let writableShared = Set(shared.filter { $0.access.canWrite }.map(\.id))
        var destinations = [ShareInboxDestination(boardID: nil, name: "剪贴板历史")]
        for board in try store.pinboards() {
            let namespace = try store.pinboardNamespace(id: board.id)
            if namespace?.hasPrefix("shared:") == true {
                if writableShared.contains(board.id) {
                    destinations.append(.init(boardID: board.id, name: board.name, color: board.color, isShared: true))
                }
            } else if namespace == nil || namespace == sync.accountID {
                destinations.append(.init(boardID: board.id, name: board.name, color: board.color))
            }
        }
        return ShareInboxCatalog(contextBinding: binding, destinations: destinations)
    }

    private func makeRecord(_ item: ShareInboxItem, envelope: ShareInboxEnvelope, recordID: UUID) throws -> (record: ClipboardRecord, ownedFiles: [OwnedFileImport]) {
        var representations: [ClipboardRepresentation] = []
        var ownedFiles: [OwnedFileImport] = []
        var text = "", rtf: Data?, html: Data?
        for (representationIndex, representation) in item.representations.enumerated() {
            let data = try directory.data(for: representation, operationID: envelope.id)
            let identifier = representation.typeIdentifier
            if identifier == "io.github.bestbbb.clipshelf.shared-file" {
                let inputName = representation.originalFilename ?? "Shared file"
                let name = URL(fileURLWithPath: inputName).lastPathComponent
                guard name != ".", name != "..", !name.isEmpty, !name.contains("\0") else { throw ShareInboxError.invalidData }
                // data(for:) has already verified the staged byte count and SHA-256.
                // Core publishes the managed file and registry binding atomically with creation.
                representations.append(.init(typeIdentifier: "public.file-url", data: Data()))
                ownedFiles.append(OwnedFileImport(partIndex: 0, representationIndex: representationIndex, filename: name, data: data))
                text = name
            } else {
                guard let type = UTType(identifier), type.conforms(to: .text) || type.conforms(to: .image) || type.conforms(to: .url),
                      identifier != "public.file-url" else { throw ImportError.unsupportedType }
                representations.append(.init(typeIdentifier: identifier, data: data))
                if identifier == "public.utf8-plain-text" || identifier == "public.url" { text = String(data: data, encoding: .utf8) ?? "" }
                if identifier == "public.rtf" { rtf = data }
                if identifier == "public.html" { html = data }
            }
        }
        let record = ClipboardRecord(id: recordID, text: text, sourceApp: "系统分享", sourceBundleID: nil,
            copiedAt: envelope.createdAt, rtf: rtf, html: html, parts: [.init(representations: representations)],
            pinboardID: envelope.destination.boardID, isInHistory: !envelope.destination.isShared)
        return (record, ownedFiles)
    }

    private func save(_ receipt: Receipt, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try ShareInboxDirectory.requireRegular(url) }
        try JSONEncoder().encode(receipt).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let file = try FileHandle(forWritingTo: url)
        try file.synchronize(); try file.close()
    }
}
