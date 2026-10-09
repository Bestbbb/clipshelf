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
                    let record = try makeRecord(item, envelope: envelope, recordID: recordID)
                    receipt.attempted.insert(index)
                    try save(receipt, to: receiptURL)
                    do {
                        // Core transaction resolves namespace and rechecks shared access.
                        _ = try store.create(record, expectedSyncConfiguration: expectedSync, expectedSharingConfiguration: expectedSharing)
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

    private func makeRecord(_ item: ShareInboxItem, envelope: ShareInboxEnvelope, recordID: UUID) throws -> ClipboardRecord {
        var representations: [ClipboardRepresentation] = []
        var text = "", rtf: Data?, html: Data?
        for representation in item.representations {
            let data = try directory.data(for: representation, operationID: envelope.id)
            let identifier = representation.typeIdentifier
            if identifier == "io.github.bestbbb.clipshelf.shared-file" {
                let root = privateDirectory.appendingPathComponent("Files", isDirectory: true).appendingPathComponent(recordID.uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try ShareInboxDirectory.requireRegular(root, directory: true)
                let inputName = representation.originalFilename ?? "Shared file"
                let name = URL(fileURLWithPath: inputName).lastPathComponent
                guard name != ".", name != "..", !name.isEmpty, !name.contains("\0") else { throw ShareInboxError.invalidData }
                let file = root.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path) {
                    guard ShareInboxDirectory.digest(try ShareInboxDirectory.boundedData(file, limit: ShareInboxDirectory.maximumBytes)) == representation.sha256 else { throw ShareInboxError.invalidData }
                } else { try data.write(to: file, options: .withoutOverwriting) }
                representations.append(.init(typeIdentifier: "public.file-url", data: Data(file.absoluteString.utf8)))
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
        return ClipboardRecord(id: recordID, text: text, sourceApp: "系统分享", sourceBundleID: nil,
            copiedAt: envelope.createdAt, rtf: rtf, html: html, parts: [.init(representations: representations)],
            pinboardID: envelope.destination.boardID, isInHistory: !envelope.destination.isShared)
    }

    private func save(_ receipt: Receipt, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try ShareInboxDirectory.requireRegular(url) }
        try JSONEncoder().encode(receipt).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let file = try FileHandle(forWritingTo: url)
        try file.synchronize(); try file.close()
    }
}
