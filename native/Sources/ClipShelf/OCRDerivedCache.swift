import ClipShelfLocalization
import ClipShelfCore
import Darwin
import Foundation
import UniformTypeIdentifiers

/// Disposable local derived data, never included in Core sync or backup payloads.
actor OCRDerivedCache {
    static let shared = OCRDerivedCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClipShelf/OCR-v1", isDirectory: true))
    static let maximumEntryBytes = 12 * 1_024 * 1_024
    struct Entry: Codable {
        let version: Int
        let recordID: UUID
        let sourceRevision: Int
        let imageDigest: String
        let requestedLanguages: [String]
        let createdAt: Date
        let result: LocalIntelligenceService.OCRResult
    }
    private let directory: URL
    private let maximumAge: TimeInterval
    init(directory: URL, maximumAge: TimeInterval = 30 * 24 * 60 * 60) {
        self.directory = directory
        self.maximumAge = maximumAge
    }

    nonisolated static func imageData(in record: ClipboardRecord) -> Data? {
        record.parts.lazy.flatMap(\.representations).first { UTType($0.typeIdentifier)?.conforms(to: .image) == true }?.data
    }
    func result(for record: ClipboardRecord, imageData: Data,
                recognitionLanguages: [String] = LocalIntelligenceService.defaultRecognitionLanguages) throws -> LocalIntelligenceService.OCRResult? {
        try Task.checkCancellation()
        let url = location(record.id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            guard let entry = try readEntry(url) else { return nil }
            let digest = LocalIntelligenceService.imageDigest(imageData)
            guard entry.version == 1, entry.recordID == record.id, entry.sourceRevision == record.revision,
                  entry.imageDigest == digest, entry.result.sourceImageDigest == digest,
                  entry.requestedLanguages == recognitionLanguages,
                  entry.createdAt <= Date().addingTimeInterval(60), Date().timeIntervalSince(entry.createdAt) <= maximumAge,
                  Self.valid(entry.result), Self.imageData(in: record).map(LocalIntelligenceService.imageDigest) == digest else { return nil }
            try Task.checkCancellation()
            return entry.result
        } catch is CancellationError { throw CancellationError() }
        catch { return nil } // A malformed/evicted derived file is a cache miss, never a lost original.
    }
    func store(_ result: LocalIntelligenceService.OCRResult, for record: ClipboardRecord, imageData: Data,
               recognitionLanguages: [String] = LocalIntelligenceService.defaultRecognitionLanguages,
               sourceStore: HistoryStore? = nil) throws {
        try Task.checkCancellation()
        try Self.validateSource(record, in: sourceStore)
        let digest = LocalIntelligenceService.imageDigest(imageData)
        guard record.revision > 0, result.sourceImageDigest == digest, Self.valid(result),
              Self.imageData(in: record).map(LocalIntelligenceService.imageDigest) == digest else { throw CacheError.invalidResult }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw CacheError.invalidResult }
        // A late background result must not replace a newer source revision.
        if let existing = try? readEntry(location(record.id)), existing.sourceRevision > record.revision { return }
        let entry = Entry(version: 1, recordID: record.id, sourceRevision: record.revision, imageDigest: digest,
                          requestedLanguages: recognitionLanguages, createdAt: Date(), result: result)
        let data = try JSONEncoder().encode(entry)
        guard data.count <= Self.maximumEntryBytes else { throw CacheError.invalidResult }
        try Task.checkCancellation()
        // There is no suspension from this metadata check through file publication.
        // A purge queued by a concurrent deletion runs after this actor turn; a
        // deletion already visible here cannot be resurrected by a late OCR result.
        try Self.validateSource(record, in: sourceStore)
        try data.write(to: location(record.id), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: location(record.id).path)
    }
    /// Live callers inject a store; nil is reserved for synthetic/demo snapshots.
    nonisolated static func validateSource(_ record: ClipboardRecord, in sourceStore: HistoryStore?) throws {
        guard let sourceStore else { return }
        guard let metadata = try sourceStore.itemMetadata(id: record.id), metadata.revision == record.revision else {
            throw CacheError.sourceChanged
        }
    }

    /// A commit may finish while a newer revision is already being recognized.
    /// Its cleanup must not remove that newer result (or the same revision).
    func remove(recordID: UUID, beforeRevision: Int? = nil) throws {
        let file = location(recordID)
        if let beforeRevision, let entry = try? readEntry(file),
           entry.recordID == recordID, entry.sourceRevision >= beforeRevision { return }
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    func clear() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
    /// Called after a history reload, including MCP and remote deletions. This
    /// inspects only cache JSON and Core metadata; it never resolves image blobs.
    func purgeStaleEntries(using store: HistoryStore) throws {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let rootValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw CacheError.invalidResult }
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey], options: [.skipsHiddenFiles])
        let now = Date()
        for file in files {
            try Task.checkCancellation()
            guard file.pathExtension == "json", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  file.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            // Unlink a cache-named symlink itself, without opening its destination.
            if values.isSymbolicLink == true { try FileManager.default.removeItem(at: file); continue }
            guard values.isRegularFile == true, values.isDirectory != true else { continue }
            let entry = try? readEntry(file)
            let metadata = try store.itemMetadata(id: id)
            let keep: Bool
            if let entry, let metadata {
                keep = entry.version == 1 && entry.recordID == id && entry.sourceRevision == metadata.revision
                    && entry.createdAt <= now.addingTimeInterval(60) && now.timeIntervalSince(entry.createdAt) <= maximumAge
                    && entry.imageDigest.count == 64 && entry.imageDigest.allSatisfy(\.isHexDigit)
                    && entry.imageDigest == entry.result.sourceImageDigest && Self.valid(entry.result)
            } else { keep = false }
            if !keep { try FileManager.default.removeItem(at: file) }
        }
    }
    private func location(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    private func readEntry(_ url: URL) throws -> Entry? {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= Self.maximumEntryBytes else { return nil }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { Darwin.close(descriptor); return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumEntryBytes + 1) ?? Data()
        guard data.count <= Self.maximumEntryBytes else { return nil }
        return try JSONDecoder().decode(Entry.self, from: data)
    }
    private static func valid(_ result: LocalIntelligenceService.OCRResult) -> Bool {
        guard result.engineIdentifier == LocalIntelligenceService.ocrEngineIdentifier,
              result.engineRevision == LocalIntelligenceService.ocrEngineRevision,
              result.engineVersion == LocalIntelligenceService.ocrEngineVersion,
              result.orientedPixelSize.width > 0, result.orientedPixelSize.height > 0,
              result.orientedPixelSize.width <= 4096, result.orientedPixelSize.height <= 4096,
              result.regions.count <= 10_000, result.text.utf8.count <= 1_048_576 else { return false }
        return result.regions.allSatisfy { region in
            region.confidence.isFinite && (0...1).contains(region.confidence) && valid(region.boundingBox)
                && region.spans.count <= 20_000 && region.spans.allSatisfy {
                    $0.utf16Location >= 0 && $0.utf16Length > 0
                        && $0.utf16Location <= region.text.utf16.count
                        && $0.utf16Length <= region.text.utf16.count - $0.utf16Location && valid($0.boundingBox)
                }
        }
    }
    private static func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.minX >= -0.001 && rect.minY >= -0.001 && rect.width > 0 && rect.height > 0
            && rect.maxX <= 1.001 && rect.maxY <= 1.001
    }
    enum CacheError: LocalizedError {
        case invalidResult, sourceChanged
        var errorDescription: String? {
            switch self {
            case .invalidResult: return L10n.text("识别结果与原图不匹配，未保存派生缓存。")
            case .sourceChanged: return L10n.text("原图已改变或删除，请重新打开图片。")
            }
        }
    }
}
