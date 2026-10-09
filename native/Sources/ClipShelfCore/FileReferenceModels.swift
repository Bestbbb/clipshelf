import Darwin
import Foundation
import UniformTypeIdentifiers

public enum ClipboardFileAvailability: Equatable, Sendable {
    case available, missing, unreadable, invalidURL, unsafeProjection
}

public struct ClipboardFileReference: Equatable, Sendable {
    public let partIndex: Int
    public let representationIndex: Int
    public let rawURL: Data
    public let url: URL?
    public let status: ClipboardFileAvailability
    public let isOwned: Bool
    public init(partIndex: Int, representationIndex: Int, rawURL: Data, url: URL?, status: ClipboardFileAvailability, isOwned: Bool) {
        self.partIndex = partIndex; self.representationIndex = representationIndex; self.rawURL = rawURL
        self.url = url; self.status = status; self.isOwned = isOwned
    }
}

/// The store identity is intentionally not constructible outside Core.
public struct ClipboardFileRepairSnapshot: Equatable, Sendable {
    public let record: ClipboardRecord
    public let files: [ClipboardFileReference]
    public let syncConfiguration: SyncConfiguration
    public let sharingConfiguration: SyncConfiguration
    public let isReadOnly: Bool
    let storeIdentity: UUID
    public let ownedAssetLease: OwnedAssetLease?
    /// A display-only snapshot, useful for previews/tests. Store mutations reject this unbound identity.
    public init(record: ClipboardRecord, files: [ClipboardFileReference], syncConfiguration: SyncConfiguration,
                sharingConfiguration: SyncConfiguration, isReadOnly: Bool) {
        self.init(record: record, files: files, syncConfiguration: syncConfiguration,
                  sharingConfiguration: sharingConfiguration, isReadOnly: isReadOnly, storeIdentity: UUID())
    }
    init(record: ClipboardRecord, files: [ClipboardFileReference], syncConfiguration: SyncConfiguration,
         sharingConfiguration: SyncConfiguration, isReadOnly: Bool, storeIdentity: UUID, ownedAssetLease: OwnedAssetLease? = nil) {
        self.record = record; self.files = files; self.syncConfiguration = syncConfiguration
        self.sharingConfiguration = sharingConfiguration; self.isReadOnly = isReadOnly; self.storeIdentity = storeIdentity; self.ownedAssetLease = ownedAssetLease
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.record == rhs.record && lhs.files == rhs.files && lhs.syncConfiguration == rhs.syncConfiguration && lhs.sharingConfiguration == rhs.sharingConfiguration && lhs.isReadOnly == rhs.isReadOnly && lhs.storeIdentity == rhs.storeIdentity
    }

}

public enum OwnedFileProjectionRepairResult: Equatable, Sendable {
    case restored(URL)
    case alreadyPresent(URL)
}

public enum ClipboardFileRepairError: Error, LocalizedError {
    case invalidReference, ambiguousFileReferences, ownedFileRequiresProjectionRestore, unavailableReplacement, unchangedURL, unavailableOutput
    public var errorDescription: String? {
        switch self {
        case .invalidReference: return "文件引用或修复快照已失效，请重新选择条目。"
        case .ambiguousFileReferences: return "同一个剪贴板对象包含不同的文件引用，无法确定要替换的文件。"
        case .ownedFileRequiresProjectionRestore: return "此文件由 ClipShelf 托管，请从保留的原件恢复缺失副本。"
        case .unavailableReplacement: return "所选文件或文件夹不可访问，请重新选择。"
        case .unchangedURL: return "所选路径与原引用相同，无需修改历史记录。"
        case .unavailableOutput: return "文件不可用或打开副本异常，请在“文件与位置…”中检查。"
        }
    }
}

public enum ClipboardFileAccess {
    public static func isFileURLType(_ identifier: String) -> Bool {
        identifier == "public.file-url" || UTType(identifier)?.conforms(to: .fileURL) == true
    }

    /// File names may contain spaces. Never trim the representation before interpreting it.
    public static func url(from data: Data) -> URL? {
        guard let raw = String(data: data, encoding: .utf8),
              let decoded = raw.removingPercentEncoding, !decoded.contains("\0"),
              let url = URL(string: raw), url.isFileURL,
              url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/"), !url.path.contains("\0") else { return nil }
        return url
    }

    /// stat/access only: never opens a FIFO, device, socket, or the file contents.
    /// Ordinary user-selected references may follow symlinks; owned projections use stricter checks.
    public static func availability(of url: URL) -> ClipboardFileAvailability {
        guard let local = Self.url(from: Data(url.absoluteString.utf8)) else { return .invalidURL }
        var info = stat()
        if stat(local.path, &info) != 0 {
            return errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable
        }
        let type = info.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFDIR else { return .unreadable }
        return access(local.path, type == S_IFDIR ? R_OK | X_OK : R_OK) == 0 ? .available : .unreadable
    }
}
