import ClipShelfLocalization
import ClipShelfCore
import CryptoKit
import Darwin
import Foundation
import Security

public enum ShareInboxError: Error, LocalizedError {
    case unconfigured, unauthorizedGroup, unavailableGroup, invalidData, tooLarge, confidential, cancelled, unavailableDestination, duplicateOperation
    public var errorDescription: String? {
        switch self {
        case .unconfigured: return L10n.text("分享扩展尚未配置 App Group。请使用配置了同组签名的 ClipShelf。")
        case .unauthorizedGroup: return L10n.text("当前签名没有所需 App Group 权限，未访问任何替代目录。")
        case .unavailableGroup: return L10n.text("无法访问共享收件箱，请检查主应用和扩展的签名与 App Group。")
        case .invalidData: return L10n.text("分享内容损坏或包含不支持的数据。")
        case .tooLarge: return L10n.text("一次最多分享 20 项、总计 64 MB；请减少内容后重试。")
        case .confidential: return L10n.text("分享内容带有机密或临时标记，未保存。")
        case .cancelled: return L10n.text("分享已取消，未保存。")
        case .unavailableDestination: return L10n.text("目标板或账号已改变，本次操作未完成。")
        case .duplicateOperation: return L10n.text("这个分享请求已存在，请勿重复提交。")
        }
    }
}

public struct ShareInboxDestination: Codable, Equatable, Sendable, Identifiable {
    public var id: String { boardID?.uuidString ?? "history" }
    public let boardID: UUID?
    public let name: String
    public let color: String
    public let isShared: Bool
    public init(boardID: UUID?, name: String, color: String = "#4F7CFF", isShared: Bool = false) {
        self.boardID = boardID; self.name = name; self.color = color; self.isShared = isShared
    }
}
public struct ShareInboxCatalog: Codable, Sendable {
    public let version: Int
    public let contextBinding: String
    public let updatedAt: Date
    public let destinations: [ShareInboxDestination]
    public init(contextBinding: String, destinations: [ShareInboxDestination], updatedAt: Date = Date()) {
        version = 1; self.contextBinding = contextBinding; self.destinations = destinations; self.updatedAt = updatedAt
    }
}
public struct ShareInboxRepresentation: Codable, Sendable {
    public let typeIdentifier: String
    public let filename: String
    public let byteCount: Int
    public let sha256: String
    public let originalFilename: String?
}
public struct ShareInboxItem: Codable, Sendable {
    public var representations: [ShareInboxRepresentation]
    public init(representations: [ShareInboxRepresentation] = []) { self.representations = representations }
}
public struct ShareInboxEnvelope: Codable, Sendable {
    public let version: Int
    public let id: UUID
    public let createdAt: Date
    public let contextBinding: String
    public let destination: ShareInboxDestination
    public let items: [ShareInboxItem]
}

/// Publishes a fully written, synchronized temporary file in the destination directory.
/// The injected writer is internal to synthetic tests; production always writes the complete data.
public struct ShareInboxFileWriter: Sendable {
    private let write: @Sendable (FileHandle, Data) throws -> Void
    public static let live = ShareInboxFileWriter { handle, data in try handle.write(contentsOf: data) }
    init(write: @escaping @Sendable (FileHandle, Data) throws -> Void) { self.write = write }

    public func publish(_ data: Data, to destination: URL, replacing: Bool,
                        beforePublication: () throws -> Void) throws {
        let parent = destination.deletingLastPathComponent()
        try ShareInboxDirectory.requireRegular(parent, directory: true)
        let directory = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Self.ioError() }
        defer { Darwin.close(directory) }
        let temporary = ".share-write-" + UUID().uuidString
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Self.ioError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var identity = stat()
        guard fstat(descriptor, &identity) == 0 else { throw Self.ioError() }
        defer { Self.removeIfMatching(name: temporary, in: directory, identity: identity) }
        var published = false
        do {
            try write(handle, data)
            try handle.synchronize()
            try beforePublication()
            if replacing {
                var previous = stat()
                if fstatat(directory, destination.lastPathComponent, &previous, AT_SYMLINK_NOFOLLOW) == 0 {
                    guard previous.st_mode & S_IFMT == S_IFREG, previous.st_nlink == 1 else { throw ShareInboxError.invalidData }
                } else if errno != ENOENT { throw Self.ioError() }
                guard renameat(directory, temporary, directory, destination.lastPathComponent) == 0 else { throw Self.ioError() }
            } else {
                guard linkat(directory, temporary, directory, destination.lastPathComponent, 0) == 0 else { throw Self.ioError() }
            }
            published = true
            Self.removeIfMatching(name: temporary, in: directory, identity: identity)
            guard fsync(directory) == 0 else { throw Self.ioError() }
        } catch {
            // Never remove the previous destination of an atomic replacement. New payloads,
            // however, belong exclusively to this append until its metadata is committed.
            if published, !replacing { Self.removeIfMatching(name: destination.lastPathComponent, in: directory, identity: identity) }
            throw StorageWriteFailure.classify(error) ?? error
        }
    }

    private static func removeIfMatching(name: String, in directory: Int32, identity: stat) {
        var current = stat()
        guard fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_mode & S_IFMT == S_IFREG,
              current.st_dev == identity.st_dev, current.st_ino == identity.st_ino else { return }
        _ = unlinkat(directory, name, 0)
    }
    private static func ioError() -> Error {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        return StorageWriteFailure.classify(error) ?? error
    }
}

/// Shared storage contains only destination metadata and explicit incoming shares.
/// It never opens the history database or stores integration credentials.
public final class ShareInboxDirectory: @unchecked Sendable {
    public static let maximumBytes = 64 * 1_024 * 1_024
    public static let maximumItems = 20
    public static let confidentialTypes: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
        "org.nspasteboard.ConfidentialType", "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword", "com.1password.1password"]
    public let root: URL
    public let spaceCoordinator: StorageSpaceCoordinator
    fileprivate let fileWriter: ShareInboxFileWriter
    public var inbox: URL { root.appendingPathComponent("Inbox", isDirectory: true) }
    public var staging: URL { root.appendingPathComponent("Staging", isDirectory: true) }

    public static func configured(bundle: Bundle = .main) throws -> ShareInboxDirectory {
        guard let identifier = bundle.object(forInfoDictionaryKey: "ClipShelfAppGroupIdentifier") as? String,
              !identifier.isEmpty, !identifier.contains("$("), !identifier.contains("YOUR_") else { throw ShareInboxError.unconfigured }
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) as? [String],
              groups.contains(identifier) else { throw ShareInboxError.unauthorizedGroup }
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else { throw ShareInboxError.unavailableGroup }
        return try ShareInboxDirectory(root: url.appendingPathComponent("ClipShelfShare", isDirectory: true))
    }

    /// Explicit URL injection is for synthetic tests or a caller that already validated its group entitlement.
    public init(root: URL, spaceCoordinator: StorageSpaceCoordinator? = nil,
                fileWriter: ShareInboxFileWriter = .live) throws {
        guard root.isFileURL else { throw ShareInboxError.invalidData }
        self.root = root.standardizedFileURL
        self.spaceCoordinator = try spaceCoordinator ?? StorageSpaceCoordinator(
            directory: root.appendingPathComponent(".storage-reservations", isDirectory: true))
        self.fileWriter = fileWriter
        for directory in [self.root, inbox, staging] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Self.requireRegular(directory, directory: true)
        }
    }

    public func writeCatalog(_ catalog: ShareInboxCatalog) throws {
        guard catalog.version == 1, !catalog.contextBinding.isEmpty, catalog.contextBinding.utf8.count <= 128,
              catalog.destinations.count <= 1_000,
              Set(catalog.destinations.map(\.id)).count == catalog.destinations.count,
              catalog.destinations.allSatisfy({ !$0.name.isEmpty && $0.name.utf8.count <= 1_024 && $0.color.utf8.count <= 64 }) else { throw ShareInboxError.invalidData }
        let data = try JSONEncoder().encode(catalog)
        guard data.count <= 1_048_576 else { throw ShareInboxError.tooLarge }
        let destination = root.appendingPathComponent("destinations.json")
        let lease = try spaceCoordinator.reserve([.init(destination: destination, bytes: Int64(data.count))])
        defer { try? lease.release() }
        try lease.revalidate()
        try fileWriter.publish(data, to: destination, replacing: true) { try lease.validateDestinations() }
    }

    public func readCatalog() throws -> ShareInboxCatalog {
        let url = root.appendingPathComponent("destinations.json")
        let data = try Self.boundedData(url, limit: 1_048_576)
        let catalog = try JSONDecoder().decode(ShareInboxCatalog.self, from: data)
        guard catalog.version == 1, catalog.destinations.count <= 1_000, !catalog.contextBinding.isEmpty else { throw ShareInboxError.invalidData }
        return catalog
    }

    public func makeDraft(itemCount: Int) throws -> ShareInboxDraft {
        guard (1...Self.maximumItems).contains(itemCount) else { throw ShareInboxError.tooLarge }
        return try ShareInboxDraft(directory: self, itemCount: itemCount)
    }

    public func pendingIDs() throws -> [UUID] {
        try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            .compactMap { url in
                guard let id = UUID(uuidString: url.lastPathComponent), (try? Self.requireRegular(url, directory: true)) != nil else { return nil }
                return id
            }.sorted { $0.uuidString < $1.uuidString }
    }

    public func read(_ id: UUID) throws -> (ShareInboxEnvelope, String) {
        let directory = inbox.appendingPathComponent(id.uuidString, isDirectory: true)
        try Self.requireRegular(directory, directory: true)
        let data = try Self.boundedData(directory.appendingPathComponent("manifest.json"), limit: 1_048_576)
        let envelope = try JSONDecoder().decode(ShareInboxEnvelope.self, from: data)
        guard envelope.version == 1, envelope.id == id, envelope.createdAt.timeIntervalSinceReferenceDate.isFinite,
              (1...Self.maximumItems).contains(envelope.items.count), envelope.contextBinding.utf8.count <= 128 else { throw ShareInboxError.invalidData }
        var total = 0, filenames = Set<String>()
        for item in envelope.items {
            guard (1...8).contains(item.representations.count), Set(item.representations.map(\.typeIdentifier)).count == item.representations.count else { throw ShareInboxError.invalidData }
            for representation in item.representations {
                try Self.validate(representation)
                guard filenames.insert(representation.filename).inserted else { throw ShareInboxError.invalidData }
                total += representation.byteCount
                guard total <= Self.maximumBytes else { throw ShareInboxError.tooLarge }
            }
        }
        return (envelope, Self.digest(data))
    }

    public func data(for representation: ShareInboxRepresentation, operationID: UUID) throws -> Data {
        try Self.validate(representation)
        let directory = inbox.appendingPathComponent(operationID.uuidString, isDirectory: true)
        try Self.requireRegular(directory, directory: true)
        let data = try Self.boundedData(directory.appendingPathComponent(representation.filename), limit: representation.byteCount)
        guard data.count == representation.byteCount, Self.digest(data) == representation.sha256 else { throw ShareInboxError.invalidData }
        return data
    }

    public func remove(_ id: UUID) throws {
        let url = inbox.appendingPathComponent(id.uuidString, isDirectory: true)
        try Self.requireRegular(url, directory: true)
        try FileManager.default.removeItem(at: url)
    }

    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func validate(_ value: ShareInboxRepresentation) throws {
        guard UUID(uuidString: String(value.filename.dropLast(5))) != nil, value.filename.hasSuffix(".data"),
              !value.filename.contains("/"), value.byteCount >= 0, value.byteCount <= maximumBytes,
              !value.typeIdentifier.isEmpty, value.typeIdentifier.utf8.count <= 256,
              value.sha256.count == 64, value.sha256.allSatisfy({ $0.isHexDigit }),
              (value.originalFilename?.utf8.count ?? 0) <= 256 else { throw ShareInboxError.invalidData }
        guard !confidentialTypes.contains(value.typeIdentifier) else { throw ShareInboxError.confidential }
    }
    public static func requireRegular(_ url: URL, directory: Bool = false) throws {
        let value = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
        guard value.isSymbolicLink != true, directory ? value.isDirectory == true : value.isRegularFile == true else { throw ShareInboxError.invalidData }
    }
    public static func boundedData(_ url: URL, limit: Int) throws -> Data {
        try requireRegular(url)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ShareInboxError.invalidData }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { Darwin.close(descriptor); throw ShareInboxError.invalidData }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ShareInboxError.tooLarge }
        return data
    }
}

public final class ShareInboxDraft: @unchecked Sendable {
    public let id = UUID()
    private let directory: ShareInboxDirectory
    private let lock = NSLock()
    private var items: [ShareInboxItem]
    private var total = 0
    private var payloadBudgetUsed: Int64 = 0
    private var reservedPayloadBytes: Int64 = 0
    private var reservedManifestBytes: Int64 = 0
    private var reservation: StorageSpaceLease?
    private var finished = false
    private var path: URL { directory.staging.appendingPathComponent(id.uuidString, isDirectory: true) }

    /// Publication can be explicitly retried with the same prepared draft after these
    /// transient storage failures. Invalid content or a changed destination needs a new share.
    public static func canRetryPublication(after error: Error) -> Bool {
        switch StorageWriteFailure.classify(error) {
        case .insufficientSpace, .diskFull, .capacityUnavailable, .coordinationUnavailable: return true
        default: return false
        }
    }

    fileprivate init(directory: ShareInboxDirectory, itemCount: Int) throws {
        self.directory = directory
        items = Array(repeating: ShareInboxItem(), count: itemCount)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    deinit { cancel() }

    public func append(data: Data, typeIdentifier: String, itemIndex: Int, originalFilename: String? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { throw ShareInboxError.cancelled }
        guard !ShareInboxDirectory.confidentialTypes.contains(typeIdentifier) else { throw ShareInboxError.confidential }
        guard items.indices.contains(itemIndex), items[itemIndex].representations.count < 8,
              !items[itemIndex].representations.contains(where: { $0.typeIdentifier == typeIdentifier }),
              !typeIdentifier.isEmpty, typeIdentifier.utf8.count <= 256 else { throw ShareInboxError.invalidData }
        guard data.count <= ShareInboxDirectory.maximumBytes - total else { throw ShareInboxError.tooLarge }
        let filename = UUID().uuidString + ".data"
        let payloadURL = path.appendingPathComponent(filename)
        let byteBudget = max(1, Int64(data.count))
        try reserve(payloadBytes: payloadBudgetUsed + byteBudget, manifestBytes: reservedManifestBytes)
        try directory.fileWriter.publish(data, to: payloadURL, replacing: false) {
            try reservation?.validateDestinations()
        }
        items[itemIndex].representations.append(ShareInboxRepresentation(typeIdentifier: typeIdentifier, filename: filename,
            byteCount: data.count, sha256: ShareInboxDirectory.digest(data), originalFilename: originalFilename.map { name in
                var safe = String(name.prefix(128))
                while safe.utf8.count > 256 { safe.removeLast() }
                return safe
            }))
        total += data.count
        payloadBudgetUsed += byteBudget
    }

    /// The caller must invoke this only after the user chooses a destination and presses Save.
    @discardableResult public func publish(destination: ShareInboxDestination, catalog: ShareInboxCatalog) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { throw ShareInboxError.cancelled }
        guard catalog.destinations.contains(destination), items.allSatisfy({ !$0.representations.isEmpty }) else { throw ShareInboxError.unavailableDestination }
        let current = try directory.readCatalog()
        guard current.contextBinding == catalog.contextBinding, current.destinations.contains(destination) else { throw ShareInboxError.unavailableDestination }
        let envelope = ShareInboxEnvelope(version: 1, id: id, createdAt: Date(), contextBinding: catalog.contextBinding, destination: destination, items: items)
        let data = try JSONEncoder().encode(envelope)
        guard data.count <= 1_048_576 else { throw ShareInboxError.tooLarge }
        let manifest = path.appendingPathComponent("manifest.json")
        // A previous publish may have written its manifest before the final directory move
        // failed. Keep room for that manifest and one replacement temporary file on retry.
        try reserve(payloadBytes: payloadBudgetUsed, manifestBytes: Int64(data.count) * 2)
        try directory.fileWriter.publish(data, to: manifest, replacing: true) {
            try reservation?.validateDestinations()
        }
        let destinationURL = directory.inbox.appendingPathComponent(id.uuidString, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else { throw ShareInboxError.duplicateOperation }
        try ShareInboxDirectory.requireRegular(directory.inbox, directory: true)
        try reservation?.validateDestinations()
        do { try FileManager.default.moveItem(at: path, to: destinationURL) }
        catch { throw StorageWriteFailure.classify(error) ?? error }
        finished = true
        releaseReservation()
        return id
    }
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        try? FileManager.default.removeItem(at: path)
        releaseReservation()
    }

    private func reserve(payloadBytes: Int64, manifestBytes: Int64) throws {
        let payload = max(reservedPayloadBytes, payloadBytes)
        let manifest = max(reservedManifestBytes, manifestBytes)
        let additional = payload - reservedPayloadBytes + manifest - reservedManifestBytes
        guard additional > 0 else { return }
        let requirement = StorageSpaceRequirement(destination: path, bytes: additional)
        if let reservation {
            do { try reservation.addRequirements([requirement]) }
            catch {
                // An expansion may already be published when registry synchronization fails.
                // Retire the uncertain aggregate; a retry reserves the complete cumulative
                // payload again. Already written files and their metadata remain intact.
                releaseReservation()
                throw error
            }
        }
        else {
            let lease = try directory.spaceCoordinator.reserve([requirement])
            do { try lease.revalidate() } catch { try? lease.release(); throw error }
            reservation = lease
        }
        // A failed file write can be retried within this still-held allowance. It must not
        // add the same bytes again or discard protection for earlier staged payloads.
        reservedPayloadBytes = payload
        reservedManifestBytes = manifest
    }
    private func releaseReservation() {
        let lease = reservation
        reservation = nil
        reservedPayloadBytes = 0
        reservedManifestBytes = 0
        try? lease?.release()
    }
}
